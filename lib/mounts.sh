#!/bin/bash
#
# steamos-build-installer — lib/mounts.sh
# Mount and loop device primitives: attach/detach loops, unmount helpers,
# ext4 superblock monitoring, and system state snapshots.
# Sourced by the build backend and repatch — do not run it directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/mounts.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Depends on: common.sh (log, warn, emit_prefixed_lines)

# List loop devices backed by a file.
# Also matches a backing file that was already unlinked and is shown by
# losetup as "... (deleted)".
loops_for_file() {
  local target="${1:?loops_for_file: missing backing file}"

  losetup -J 2>/dev/null \
    | python3 -c '
import json, sys

target = sys.argv[1]

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

for dev in data.get("loopdevices", []):
    backing = dev.get("back-file") or ""
    clean = backing.removesuffix(" (deleted)")
    if clean == target:
        name = dev.get("name")
        if name:
            print(name)
' "$target"
}

# Print mounts whose source is a loop device or one of its partitions.
#
# Be careful not to match /dev/loop1 against /dev/loop10.
mounts_for_loop() {
  local loop="${1:?mounts_for_loop: missing loop device}"

  findmnt -rn -o TARGET,SOURCE 2>/dev/null \
    | awk -v l="$loop" '
      $2 == l || index($2, l "p") == 1 {
        print length($1) "\t" $1
      }
    ' \
    | sort -rn \
    | cut -f2-
}

# Wait until an ext4 superblock associated with a loop device is gone.
#
# If this remains after the mount disappeared, the filesystem still has a
# kernel reference. Do NOT call losetup -d and merely turn it into AUTOCLEAR.
wait_ext4_gone() {
  local loop="${1:?wait_ext4_gone: missing loop device}"
  local name="${loop##*/}"
  local sys="/sys/fs/ext4/$name"
  local i

  [[ -e "$sys" ]] && log "wait_ext4_gone: waiting for $loop ext4 superblock to release" || return 0

  # Flush pending writes before waiting
  sync 2>/dev/null || true
  blockdev --flushbufs "$loop" 2>/dev/null || true

  # Wait up to 30 seconds for the ext4 superblock to release.
  # The jbd2 journal thread can hold it for 10-20 seconds after unmount
  # while flushing dirty metadata.
  for ((i = 0; i < 300; i++)); do
    [[ ! -e "$sys" ]] && log "wait_ext4_gone: $loop ext4 superblock released after ${i}00ms" && return 0
    # Retry flushing every 5 seconds
    if ((i > 0 && i % 50 == 0)); then
      log "wait_ext4_gone: still waiting for $loop (${i}00ms elapsed, retrying flush)"
      blockdev --flushbufs "$loop" 2>/dev/null || true
    fi
    sleep 0.1
  done

  warn "ext4 superblock for $loop is still alive"

  if [[ -r "$sys/journal_task" ]]; then
    local journal_pid
    journal_pid="$(cat "$sys/journal_task" 2>/dev/null || true)"
    [[ -n "$journal_pid" ]] \
      && warn "  ext4 journal task: $journal_pid"

    # Deep diagnostics: interrogate the kernel about why the jbd2 thread
    # is still holding a reference to this ext4 superblock.
    if [[ -n "$journal_pid" && -d "/proc/$journal_pid" ]]; then
      warn "  jbd2 process state:"
      # wchan: kernel function the thread is sleeping in
      local _wchan
      _wchan="$(cat "/proc/$journal_pid/wchan" 2>/dev/null || echo "<gone>")"
      warn "    wchan: $_wchan"

      # status: voluntary/nonvoluntary ctxt switches, state
      local _status
      _status="$(sed -n '1p;/^State:/p;/^voluntary/p' "/proc/$journal_pid/status" 2>/dev/null)"
      emit_prefixed_lines warn "    " "$_status"

      # Kernel stack trace — shows the exact call chain
      if [[ -r "/proc/$journal_pid/stack" ]]; then
        local _stack
        _stack="$(cat "/proc/$journal_pid/stack" 2>/dev/null || true)"
        if [[ -n "$_stack" ]]; then
          warn "    kernel stack:"
          emit_prefixed_lines warn "      " "$_stack"
        fi
      fi

      # Open file descriptors — might reveal what the thread has open
      local _fd_count
      _fd_count="$(find "/proc/$journal_pid/fd" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)"
      warn "    open fds: $_fd_count"
    fi
  fi

  # Check if anything else has the loop device open
  local _loop_refs
  _loop_refs="$(fuser -v "$loop" 2>/dev/null || true)"
  if [[ -n "$_loop_refs" ]]; then
    warn "  Processes with $loop open:"
    emit_prefixed_lines warn "    " "$_loop_refs"
  fi

  # Check for any remaining mount references
  local _mount_refs
  _mount_refs="$(findmnt -rn -S "$loop" 2>/dev/null || true)"
  if [[ -n "$_mount_refs" ]]; then
    warn "  Remaining mount references for $loop:"
    emit_prefixed_lines warn "    " "$_mount_refs"
  fi

  # Ext4 sysfs state
  if [[ -d "$sys" ]]; then
    local _ext4_state
    _ext4_state="$(find "$sys" -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | head -20)"
    if [[ -n "$_ext4_state" ]]; then
      warn "  ext4 sysfs entries for $name:"
      emit_prefixed_lines warn "    " "$_ext4_state"
    fi
  fi

  return 1
}

# ── Cleanup tracking system ─────────────────────────────────────────────────────
# NEW GREENFIELD CODE — added as part of the mount/loop cleanup system redesign.
# This section provides resource tracking, workspace boundary enforcement,
# identity-verified teardown, and deterministic cleanup orchestration.
#
# Foundational primitives (carried forward from legacy code):
#   strict_unmount   — verified recursive unmount with diagnostics
#   strict_detach_loop — verified loop detach with AUTOCLEAR awareness
#
# Dependencies: log/warn/die/debug (common.sh)
#
# KNOWN GAP: The current system uses a flat registry — all resources go into
# the same arrays and teardown is all-or-nothing reverse order. There is no
# concept of abstract/transient/temporary environments (e.g., overlay workspaces
# with their own mount trees that should be torn down as a unit). Domain-specific
# teardown (overlay_cleanup, chroot setup) currently lives in the domain code
# because it needs ordering knowledge and escalation logic that the generic
# reverse-order teardown cannot provide. This should be addressed when we have
# a concrete use case for partial/environment-scoped cleanup.
# ────────────────────────────────────────────────────────────────────────────────

# _check_bind_propagation TARGET
#   Check propagation type of a mount if it is an actual bind mount
#   (has "bind" in its mount options).
#   Returns 0 (proceed) for non-bind mounts, slave, or private propagation.
#   Returns 1 (abort) for shared propagation, unknown propagation, or
#   if findmnt is available but cannot determine the propagation.
#   Returns 0 silently if findmnt is not installed (cannot check).
#   Sets variable _PROPAGATION_TYPE to the detected type (or "n/a").
_check_bind_propagation() {
  local target="${1:?_check_bind_propagation: missing target}"
  _PROPAGATION_TYPE="n/a"

  # Bail early if findmnt is not available (cannot check, must proceed)
  command -v findmnt >/dev/null 2>&1 || return 0

  # Check if mount is actually a bind mount (not just source-path matching)
  local _opts
  _opts="$(findmnt -no OPTIONS -T "$target" 2>/dev/null)" || _opts=""
  case "$_opts" in
    *bind*) ;;  # Actual bind mount — check propagation
    *)
      return 0 # Not a bind mount — proceed with unmount
      ;;
  esac

  # Get mount source for logging
  local _src
  _src="$(findmnt -no SOURCE -T "$target" 2>/dev/null)" || _src="<unknown>"

  # Query propagation type
  local _prop
  _prop="$(findmnt -no PROPAGATION -T "$target" 2>/dev/null)" || _prop="unknown"
  _PROPAGATION_TYPE="$_prop"

  cleanup_log "PROPAGATION $target: source=$_src type=$_prop"

  case "$_prop" in
    shared | shared:*)
      warn "_check_bind_propagation: refusing to unmount shared virtual-fs bind: $target (source=$_src propagation=$_prop)"
      cleanup_log "ABORT (shared propagation): $target (source=$_src propagation=$_prop)"
      return 1
      ;;
    slave | slave:* | private | private:*)
      return 0
      ;;
    *)
      warn "_check_bind_propagation: refusing to unmount virtual-fs bind with unknown propagation: $target (source=$_src propagation=$_prop)"
      cleanup_log "ABORT (unknown propagation): $target (source=$_src propagation=$_prop)"
      return 1
      ;;
  esac
}

# Unmount an exact mount hierarchy. Never lazy-unmount persistent storage.
strict_unmount() {
  local target="${1:?strict_unmount: missing target}"
  local label="${2:-mount}"

  mountpoint -q "$target" 2>/dev/null || return 0

  # Protection blacklist: refuse to unmount protected host resources.
  # Exception: paths inside the current workspace are explicitly allowed
  # (workspace paths under /dev/shm/steamos-build/ match /dev in the protected list).
  local _in_workspace=0
  if [[ -n "${CLEANUP_WORKSPACE_ROOT:-}" ]]; then
    local _ws_resolved
    _ws_resolved="$(realpath -m -- "$target" 2>/dev/null)" || _ws_resolved="$target"
    if [[ "$_ws_resolved" == "${CLEANUP_WORKSPACE_ROOT}" || "$_ws_resolved" == "${CLEANUP_WORKSPACE_ROOT%/}"/* ]]; then
      _in_workspace=1
    fi
  fi
  if [[ $_in_workspace -eq 0 ]] && protected_path "$target"; then
    warn "strict_unmount: refusing to unmount protected path: $target ($label)"
    return 1
  fi
  # Check if any descendant mount sources from a protected host tree
  if protected_mount_sources "$target"; then
    warn "strict_unmount: refusing to unmount — descendant mounts protected host resources: $target ($label)"
    return 1
  fi

  # Propagation guard: refuse to unmount shared virtual-fs binds
  if ! _check_bind_propagation "$target"; then
    warn "strict_unmount: aborting unmount — propagation guard: $target ($label type=${_PROPAGATION_TYPE:-unknown})"
    cleanup_log "UNMOUNT ABORTED ($label propagation=${_PROPAGATION_TYPE:-unknown}): $target"
    return 1
  fi

  # Check for shared virtual-fs descendant mounts that would be caught by umount -R
  local _desc_check
  _desc_check="$(findmnt -rno TARGET,FSTYPE,PROPAGATION -M "$target" 2>/dev/null)" || true
  if [[ -n "$_desc_check" ]]; then
    while IFS= read -r _line; do
      local _d_target _d_fstype _d_prop
      _d_target="$(echo "$_line" | awk '{print $1}')"
      _d_fstype="$(echo "$_line" | awk '{print $2}')"
      _d_prop="$(echo "$_line" | awk '{print $3}')"
      # Only refuse for virtual-fs descendants (devtmpfs, sysfs, proc),
      # not block device mounts (ext4, vfat, etc.) that happen to be shared.
      case "$_d_fstype" in
        devtmpfs | sysfs | proc) ;;
        *)
          continue  # Not a virtual-fs mount — skip
          ;;
      esac
      case "$_d_prop" in
        shared | shared:*)
          warn "strict_unmount: descendant shared propagation found: $_d_target (under $target)"
          cleanup_log "UNMOUNT ABORTED (descendant shared) $label: $target (descendant: $_d_target propagation=$_d_prop)"
          return 1
          ;;
      esac
    done <<<"$_desc_check"
  fi

  log "  Unmounting $label: $target (propagation=${_PROPAGATION_TYPE:-n/a})"
  cleanup_log "UNMOUNT $label: $target (propagation=${_PROPAGATION_TYPE:-n/a})"

  if ! umount -R "$target" 2>/dev/null; then
    warn "Could not cleanly unmount $label: $target"
    cleanup_log "UNMOUNT FAILED $label: $target"

    findmnt -R "$target" >&2 2>/dev/null || true
    fuser -vm "$target" >&2 2>/dev/null || true

    return 1
  fi

  if mountpoint -q "$target" 2>/dev/null; then
    warn "$label is still mounted after umount: $target"
    cleanup_log "UNMOUNT STILL_MOUNTED $label: $target"
    findmnt -R "$target" >&2 2>/dev/null || true
    return 1
  fi

  cleanup_log "UNMOUNT OK $label: $target"
  return 0
}

# Detach a loop device and verify it really disappeared.
strict_detach_loop() {
  local loop="${1:?strict_detach_loop: missing loop device}"

  losetup "$loop" >/dev/null 2>&1 || return 0

  sync
  blockdev --flushbufs "$loop" 2>/dev/null || true

  log "  Detaching loop device: $loop"
  cleanup_log "DETACH loop: $loop"

  if ! losetup -d "$loop" 2>/dev/null; then
    warn "losetup -d failed for $loop"
    cleanup_log "DETACH FAILED loop: $loop"
    losetup "$loop" >&2 2>/dev/null || true
    return 1
  fi

  run_dangerous_cmd udevadm settle --timeout=5 2>/dev/null || true

  local i
  for ((i = 0; i < 20; i++)); do
    if ! losetup "$loop" >/dev/null 2>&1; then
      cleanup_log "DETACH OK loop: $loop"
      return 0
    fi
    sleep 0.1
  done

  # Loop is still attached after losetup -d.  If AUTOCLEAR is set, the
  # kernel will auto-detach when the last reference (e.g. jbd2 journal
  # thread) releases — this is not a failure.
  local autoclear
  autoclear="$(losetup -l -O AUTOCLEAR "$loop" 2>/dev/null | tail -1 | tr -d ' ')"
  if [[ "$autoclear" == "1" ]]; then
    log "$loop still attached but AUTOCLEAR=1 — kernel will auto-detach"
    return 0
  fi

  warn "$loop is still attached after losetup -d"
  losetup -l -O NAME,AUTOCLEAR,RO,BACK-FILE "$loop" >&2 2>/dev/null || true
  return 1
}

CLEANUP_LOG=""
CLEANUP_MOUNT_STATE_CAPTURED=0

# cleanup_log MESSAGE
#   Write a timestamped message to the cleanup log file.
#   Silently returns if CLEANUP_LOG is unset or empty.
cleanup_log() {
  [[ -n "${CLEANUP_LOG:-}" ]] || return 0
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] %s\n' "$ts" "$*" >>"$CLEANUP_LOG" 2>/dev/null || true
}

# cleanup_log_namespace
#   Log current mount namespace ID and root filesystem propagation.
#   Used at cleanup entry points to record the execution context.
cleanup_log_namespace() {
  local _ns_id _ns_prop
  _ns_id="$(readlink /proc/self/ns/mnt 2>/dev/null)" || _ns_id="<unknown>"
  _ns_prop="$(findmnt -no PROPAGATION / 2>/dev/null)" || _ns_prop="<unknown>"
  cleanup_log "NAMESPACE $_ns_id PROPAGATION $_ns_prop"
}

# cleanup_log_mount_state
#   Capture a snapshot of the current mount topology to the cleanup log.
#   Runs before any teardown actions so the log records the "before" state.
#   Silently returns if CLEANUP_LOG is unset, empty, or findmnt is absent.
cleanup_log_mount_state() {
  [[ -n "${CLEANUP_LOG:-}" ]] || return 0
  ((CLEANUP_MOUNT_STATE_CAPTURED)) && return 0
  CLEANUP_MOUNT_STATE_CAPTURED=1
  local _findmnt
  _findmnt="$(command -v findmnt 2>/dev/null)" || return 0

  cleanup_log "=== mount state snapshot ==="

  local _mp

  # Steamos-build workspace mount (may not exist yet)
  cleanup_log "--- /dev/shm/steamos-build mount ---"
  # lint-ignore: merged-streams - Intentional: merging stdout+stderr into flat cleanup log for diagnostics
  "$_findmnt" -R -o TARGET,SOURCE,FSTYPE,OPTIONS,PROPAGATION \
    /dev/shm/steamos-build >>"$CLEANUP_LOG" 2>&1 || true

  # Standard virtual filesystem mounts
  cleanup_log "--- virtual filesystem mounts ---"
  for _mp in /dev /dev/pts /dev/shm /sys /proc; do
    # lint-ignore: merged-streams - Intentional: merging stdout+stderr into flat cleanup log for diagnostics
    "$_findmnt" -o TARGET,SOURCE,FSTYPE,OPTIONS,PROPAGATION \
      "$_mp" >>"$CLEANUP_LOG" 2>&1 || true
  done

  # Full mount table with propagation types
  cleanup_log "--- full mount table (propagation) ---"
  # lint-ignore: merged-streams - Intentional: merging stdout+stderr into flat cleanup log for diagnostics
  "$_findmnt" -o TARGET,SOURCE,FSTYPE,OPTIONS,PROPAGATION \
    >>"$CLEANUP_LOG" 2>&1 || true

  # Propagation summary (compact, one line per mount)
  cleanup_log "--- propagation summary ---"
  # lint-ignore: merged-streams - Intentional: merging stdout+stderr into flat cleanup log for diagnostics
  "$_findmnt" -o TARGET,PROPAGATION -r >>"$CLEANUP_LOG" 2>&1 || true
}

CLEANUP_RUNNING=0
CLEANUP_INCOMPLETE=0
CLEANUP_ATTEMPTED=0

declare -a CLEANUP_MOUNTS=()
declare -a CLEANUP_MOUNT_IDS=()
declare -a CLEANUP_MOUNT_LABELS=()
declare -a CLEANUP_MOUNT_NORMALIZED=() # pre-normalized canonical paths
# shellcheck disable=SC2034  # used by cleanup_track_mount, _cleanup_prune_outside_workspace_mounts, etc.
declare -a CLEANUP_MOUNT_IDENTITIES=() # composite identity: id:source:fstype:options
declare -a CLEANUP_LOOPS=()
declare -a CLEANUP_LOOP_BACKINGS=()
declare -a CLEANUP_LOOP_LABELS=()
declare -a CLEANUP_TEMPDIRS=()

# Configurable workspace boundary
CLEANUP_WORKSPACE_ROOT=""

# cleanup_track_mount MOUNTPOINT [LABEL]
#   Register a mount for cleanup. Call immediately after successful mount.
#   Mounts are unmounted in reverse registration order.
#   LABEL is currently unused in output but reserved for structured logging.
cleanup_track_mount() {
  local mountpoint="${1:?cleanup_track_mount: missing mountpoint}"
  local label="${2:-}"

  # Workspace is required
  if [[ -z "$CLEANUP_WORKSPACE_ROOT" ]]; then
    die "cleanup_track_mount: CLEANUP_WORKSPACE_ROOT not set — call cleanup_set_workspace first"
  fi

  # Lifecycle guard
  if ((CLEANUP_RUNNING)); then
    warn "cleanup_track_mount: cannot register during cleanup"
    return 1
  fi

  # Validate path is inside workspace
  if ! _cleanup_validate_workspace "$mountpoint"; then
    return 1
  fi

  # Store canonical path
  local canonical
  canonical="$(realpath "$mountpoint" 2>/dev/null)" || canonical="$mountpoint"

  # Get mount identity — reject if multiple mounts at this path (stacked)
  local mount_ids
  mount_ids="$(findmnt -rno ID -M "$canonical" --kernel 2>/dev/null)" || mount_ids=""

  local mount_count
  mount_count="$(echo "$mount_ids" | grep -c . 2>/dev/null)" || mount_count=0

  if ((mount_count == 0)); then
    warn "cleanup_track_mount: could not resolve mount ID for $canonical"
    return 1
  fi

  if ((mount_count > 1)); then
    warn "cleanup_track_mount: multiple mounts at $canonical ($mount_count) — stacked mounts not supported"
    return 1
  fi

  local mount_id
  mount_id="$(echo "$mount_ids" | head -1)"

  # Always append — no deduplication (handles stacked mounts)
  CLEANUP_MOUNTS+=("$canonical")
  CLEANUP_MOUNT_LABELS+=("${label:-$canonical}")
  CLEANUP_MOUNT_IDS+=("$mount_id")
  CLEANUP_MOUNT_NORMALIZED+=("$canonical")

  # Capture composite identity for stronger verification at cleanup time
  local mount_identity
  mount_identity="$(_cleanup_capture_mount_identity "$canonical")" || mount_identity="$mount_id"
  CLEANUP_MOUNT_IDENTITIES+=("$mount_identity")
}

# cleanup_track_loop LOOPDEV BACKING_FILE [LABEL]
#   Register a loop device for cleanup.
#   Records backing-file identity (device:inode) for safe comparison.
cleanup_track_loop() {
  local loopdev="${1:?cleanup_track_loop: missing loop device}"
  local backing="${2:?cleanup_track_loop: missing backing file}"
  local label="${3:-}"

  # Lifecycle guard
  if ((CLEANUP_RUNNING)); then
    warn "cleanup_track_loop: cannot register during cleanup"
    return 1
  fi

  # Workspace validation
  if [[ -n "$CLEANUP_WORKSPACE_ROOT" ]]; then
    if ! _cleanup_validate_workspace "$backing"; then
      return 1
    fi
  fi

  # Verify loop device exists
  if ! [[ -e "/sys/block/${loopdev##*/}/loop/backing_file" ]]; then
    warn "cleanup_track_loop: loop $loopdev does not exist in sysfs"
    return 1
  fi

  # NOTE: Loop identity comparison uses device:inode of the backing file.
  # This catches wrong-image registration but not:
  #   - Reassociation to the same file with different offset/size
  #   - Pathname replacement during the cleanup window
  #
  # Enforced requirement: loop mappings and their backing files must not be
  # replaced or reassociated during the cleanup run. The workspace lock and
  # the lifecycle guard (CLEANUP_RUNNING) provide this protection when used
  # correctly by the caller.

  # Get the loop's actual backing path from kernel
  local actual_backing_path
  actual_backing_path="$(cat "/sys/block/${loopdev##*/}/loop/backing_file" 2>/dev/null)" || {
    warn "cleanup_track_loop: cannot read backing_file for $loopdev"
    return 1
  }

  # Compare intended backing with actual backing
  local intended_canonical
  intended_canonical="$(realpath "$backing" 2>/dev/null)" || intended_canonical="$backing"
  local actual_canonical
  actual_canonical="$(realpath "$actual_backing_path" 2>/dev/null)" || actual_canonical="$actual_backing_path"

  if [[ "$intended_canonical" != "$actual_canonical" ]]; then
    warn "cleanup_track_loop: $loopdev maps to $actual_canonical, not $intended_canonical"
    return 1
  fi

  # Get backing identity (device:inode)
  local backing_id=""
  if [[ -e "$actual_backing_path" ]]; then
    backing_id="$(stat -c '%d:%i' "$actual_backing_path" 2>/dev/null)" || backing_id=""
  fi

  if [[ -z "$backing_id" ]]; then
    warn "cleanup_track_loop: cannot resolve identity of $loopdev backing"
    return 1
  fi

  # Record the loop with verified identity
  CLEANUP_LOOPS+=("$loopdev")
  CLEANUP_LOOP_BACKINGS+=("$backing_id")
  CLEANUP_LOOP_LABELS+=("${label:-$loopdev}")
}

# cleanup_track_tempdir DIRECTORY [LABEL]
#   Register a temporary directory for removal. Only for directories
#   we created and that should be empty after unmounting.
#   LABEL is currently unused in output but reserved for structured logging.
cleanup_track_tempdir() {
  local dir="${1:?cleanup_track_tempdir: missing directory}"
  local label="${2:-}"

  # Workspace is required
  if [[ -z "$CLEANUP_WORKSPACE_ROOT" ]]; then
    die "cleanup_track_tempdir: CLEANUP_WORKSPACE_ROOT not set — call cleanup_set_workspace first"
  fi

  # Lifecycle guard
  if ((CLEANUP_RUNNING)); then
    warn "cleanup_track_tempdir: cannot register during cleanup"
    return 1
  fi

  # Validate path is inside workspace
  if ! _cleanup_validate_workspace "$dir"; then
    return 1
  fi

  # Store canonical path
  local canonical
  canonical="$(realpath "$dir" 2>/dev/null)" || canonical="$dir"

  CLEANUP_TEMPDIRS+=("$canonical")
}

# cleanup_set_workspace ROOT
#   Set the approved workspace boundary. All tracked paths must be under this.
cleanup_set_workspace() {
  local root="${1:?cleanup_set_workspace: missing workspace root}"
  [[ -d "$root" ]] || die "cleanup_set_workspace: $root is not a directory"

  local resolved
  resolved="$(realpath "$root" 2>/dev/null)" || die "cleanup_set_workspace: cannot resolve $root"

  case "$resolved" in
    / | /bin | /boot | /dev | /etc | /home | /lib* | /media | /mnt | \
      /opt | /proc | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /var)
      die "cleanup_set_workspace: refusing to use system path as workspace: $resolved"
      ;;
  esac

  # Protection blacklist: refuse workspaces under protected host trees.
  # Exception: project-owned RAM workspaces under /dev/shm are explicitly allowed.
  if protected_path "$resolved"; then
    case "$resolved" in
      /dev/shm/steamos-build | /dev/shm/steamos-build-*)
        # Project-owned RAM workspace — allowed by design
        debug "cleanup_set_workspace: allowing project RAM workspace: $resolved"
        ;;
      *)
        die "cleanup_set_workspace: refusing to use protected path as workspace: $resolved"
        ;;
    esac
  fi

  CLEANUP_WORKSPACE_ROOT="$resolved"
}

# _cleanup_validate_workspace PATH [PRE_NORMALIZED]
#   Verify PATH is inside the approved workspace boundary.
#   If PRE_NORMALIZED is non-empty, PATH is already a normalized canonical form.
#   Returns 1 if the path is outside the boundary or boundary is not set.
#   Returns 2 if the target is unavailable (neither realpath nor realpath -m succeeded).
_cleanup_validate_workspace() {
  local path="${1:?_cleanup_validate_workspace: missing path}"
  local pre_normalized="${2:-}" # if non-empty, $path is already a normalized canonical form

  [[ -n "$CLEANUP_WORKSPACE_ROOT" ]] || {
    warn "_cleanup_validate_workspace: no workspace boundary set"
    return 1
  }

  # Determine the effective (resolved) path
  local resolved
  if [[ -n "$pre_normalized" ]]; then
    # Cleanup revalidation: use the canonical path captured at registration.
    # The path may no longer exist on disk (parent mount removed), but
    # the stored canonical form is still valid for containment checking.
    resolved="$pre_normalized"
  else
    # Registration / creation time: require full path resolution.
    # This ensures symlink resolution happens before accepting a path.
    resolved="$(realpath "$path" 2>/dev/null)" || {
      warn "_cleanup_validate_workspace: cannot resolve $path"
      return 2 # TARGET UNAVAILABLE
    }
  fi

  case "$resolved" in
    / | /bin | /boot | /dev | /etc | /home | /lib* | /media | /mnt | \
      /opt | /proc | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /var)
      warn "_cleanup_validate_workspace: refusing to clean system path: $resolved"
      return 1
      ;;
  esac

  local _in_workspace=0
  if [[ -n "${CLEANUP_WORKSPACE_ROOT:-}" ]]; then
    local _ws_resolved
    _ws_resolved="$(realpath -m -- "$resolved" 2>/dev/null)" || _ws_resolved="$resolved"
    if [[ "$_ws_resolved" == "${CLEANUP_WORKSPACE_ROOT}" || "$_ws_resolved" == "${CLEANUP_WORKSPACE_ROOT%/}"/* ]]; then
      _in_workspace=1
    fi
  fi
  if [[ $_in_workspace -eq 0 ]] && protected_path "$resolved"; then
    warn "_cleanup_validate_workspace: refusing to clean protected path: $resolved"
    return 1
  fi

  if [[ "$path" == *".."* ]]; then
    warn "_cleanup_validate_workspace: path contains '..': $path"
    return 1
  fi

  local ws="${CLEANUP_WORKSPACE_ROOT%/}/"
  if [[ "$resolved" == "$CLEANUP_WORKSPACE_ROOT" ]] || [[ "$resolved" == "${ws}"* ]]; then
    return 0
  fi

  warn "_cleanup_validate_workspace: $path is outside workspace $CLEANUP_WORKSPACE_ROOT"
  return 1
}

# _cleanup_read_mount_inventory
#   Read kernel mount inventory, decode escape sequences, print clean paths.
#   Returns 0 on success, 1 on failure.
_cleanup_read_mount_inventory() {
  local raw line

  raw="$(timeout 10 findmnt -rno TARGET --kernel 2>/dev/null)" || return 1

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '%b\n' "$line" || return 1
  done <<<"$raw"

  return 0
}

# Capture composite mount identity: id:source:fstype:options
# Returns empty string if the mount cannot be identified.
_cleanup_capture_mount_identity() {
  local target="${1:?_cleanup_capture_mount_identity: missing target}"
  local raw
  raw="$(findmnt -rno ID,SOURCE,FSTYPE,OPTIONS -M "$target" --kernel 2>/dev/null | head -1)" || {
    return 1
  }
  [[ -n "$raw" ]] || return 1

  local _id _src _fstype _opts
  _id="$(echo "$raw" | awk '{print $1}')"
  _src="$(echo "$raw" | awk '{print $2}')"
  _fstype="$(echo "$raw" | awk '{print $3}')"
  _opts="$(echo "$raw" | awk '{$1=$2=$3=""; sub(/^[ \t]+/, ""); print}')"

  [[ -n "$_id" ]] || return 1

  printf '%s:%s:%s:%s' "$_id" "$_src" "$_fstype" "$_opts"
}

# _cleanup_check_tracked_mounts
#   Read kernel mount inventory and verify all tracked mounts are gone.
#   Returns 0 if all gone, 1 if any remain.
_cleanup_check_tracked_mounts() {
  local rc=0

  local all_mounts
  all_mounts="$(_cleanup_read_mount_inventory 2>/dev/null)" || {
    warn "_cleanup_check_tracked_mounts: cannot read mount inventory"
    return 1
  }

  local i _n=0
  [[ ${CLEANUP_MOUNTS[0]+_} ]] && _n=${#CLEANUP_MOUNTS[@]}
  for ((i = 0; i < _n; i++)); do
    local m="${CLEANUP_MOUNTS[$i]}"
    if grep -qxF -- "$m" <<<"$all_mounts" 2>/dev/null; then
      warn "_cleanup_check_tracked_mounts: $m still mounted"
      # Detailed diagnostics: what's still mounted there
      local _cm_detail
      _cm_detail="$(findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS -M "$m" 2>/dev/null || true)"
      if [[ -n "$_cm_detail" ]]; then
        warn "  findmnt for $m:"
        emit_prefixed_lines warn "    " "$_cm_detail"
      fi
      # Check for child mounts that might prevent parent unmount
      local _cm_children
      _cm_children="$(findmnt -rno TARGET,SOURCE --submounts -M "$m" 2>/dev/null || true)"
      if [[ -n "$_cm_children" ]]; then
        local _cm_child_count
        _cm_child_count="$(echo "$_cm_children" | wc -l)"
        if ((_cm_child_count > 1)); then
          warn "  $m has $((_cm_child_count - 1)) child mount(s):"
          emit_prefixed_lines warn "    " "$_cm_children"
        fi
      fi
      # Processes using this mount
      local _cm_fuser
      _cm_fuser="$(fuser -vm "$m" 2>&1 || true)"
      if [[ -n "$_cm_fuser" ]]; then
        warn "  Processes using $m:"
        emit_prefixed_lines warn "    " "$_cm_fuser"
      fi
      rc=1
    fi
  done

  return "$rc"
}

# _cleanup_prune_outside_workspace_mounts
#   Remove entries from CLEANUP_MOUNTS[] that are no longer in the workspace.
#   These mounts were handled by overlay_cleanup or other subsystems and should
#   not cause Phase 2 verification to fail.
_cleanup_prune_outside_workspace_mounts() {
  local _pruned=0
  local i
  local _n=0
  [[ ${CLEANUP_MOUNTS[0]+_} ]] && _n=${#CLEANUP_MOUNTS[@]}

  # Read mount inventory once — if we can't read it, don't prune anything
  local _all_mounts
  _all_mounts="$(_cleanup_read_mount_inventory 2>/dev/null)"
  if [[ -z "$_all_mounts" ]]; then
    warn "_cleanup_prune_outside_workspace_mounts: cannot read mount inventory — skipping pruning"
    cleanup_log "PRUNE SKIP: cannot read mount inventory"
    return 0
  fi

  for ((i = _n - 1; i >= 0; i--)); do
    local m="${CLEANUP_MOUNTS[$i]}"
    local label="${CLEANUP_MOUNT_LABELS[$i]:-}"

    # Check if path is still in workspace — distinguish exit codes
    local _in_workspace=1
    if [[ -n "$CLEANUP_WORKSPACE_ROOT" ]]; then
      local _vrc=0
      _cleanup_validate_workspace "$m" "${CLEANUP_MOUNT_NORMALIZED[$i]:-}" || _vrc=$?
      if ((_vrc == 2)); then
        warn "_cleanup_prune_outside_workspace_mounts: cannot validate $m — preserving"
        cleanup_log "SKIP (target unavailable): $m"
        continue
      elif ((_vrc == 1)); then
        _in_workspace=0
      fi
    fi

    if ((_in_workspace == 0)); then
      # Only prune if the mount is also absent from the kernel mount table
      if grep -qxF -- "$m" <<<"$_all_mounts" 2>/dev/null; then
        # Mount is outside workspace but still mounted — keep it tracked
        warn "_cleanup_prune_outside_workspace_mounts: $m is outside workspace but still mounted — preserving"
        cleanup_log "PRESERVE (outside workspace, still mounted): $m (label=${label:-unknown})"
        continue
      fi

      cleanup_log "PRUNE (outside workspace, not mounted): $m (label=${label:-unknown})"
      warn "_cleanup_prune_outside_workspace_mounts: pruning $m (outside workspace, not mounted)"
      unset 'CLEANUP_MOUNTS[i]'
      unset 'CLEANUP_MOUNT_LABELS[i]'
      unset 'CLEANUP_MOUNT_IDS[i]'
      unset 'CLEANUP_MOUNT_NORMALIZED[i]'
      unset 'CLEANUP_MOUNT_IDENTITIES[i]'
      ((++_pruned)) || true
    fi
  done

  if ((_pruned > 0)); then
    CLEANUP_MOUNTS=("${CLEANUP_MOUNTS[@]}")
    CLEANUP_MOUNT_LABELS=("${CLEANUP_MOUNT_LABELS[@]}")
    CLEANUP_MOUNT_IDS=("${CLEANUP_MOUNT_IDS[@]}")
    CLEANUP_MOUNT_NORMALIZED=("${CLEANUP_MOUNT_NORMALIZED[@]}")
    CLEANUP_MOUNT_IDENTITIES=("${CLEANUP_MOUNT_IDENTITIES[@]}")
    cleanup_log "Pruned $_pruned outside-workspace mount(s) from tracking"
  fi

  return 0
}

# _cleanup_assert_no_mounts_under DIRECTORY
#   Check that no mounts exist at or below DIRECTORY.
#   Returns 0 if clean, 1 if mounts found.
_cleanup_assert_no_mounts_under() {
  local dir="${1:?_cleanup_assert_no_mounts_under: missing directory}"

  # Normalize directory
  local normalized
  normalized="$(realpath "$dir" 2>/dev/null)" || normalized="${dir%/}"
  normalized="${normalized%/}"
  local normalized_with_slash="${normalized}/"

  [[ -d "$normalized" ]] || return 0

  # Read kernel mount inventory with decoding
  local all_mounts
  all_mounts="$(_cleanup_read_mount_inventory)" || {
    warn "_cleanup_assert_no_mounts_under: cannot read kernel mount table"
    return 1
  }

  # Search for exact match or descendant
  local found=0
  local m
  while IFS="" read -r m; do
    [[ -n "$m" ]] || continue
    local m_normalized
    m_normalized="$(realpath "$m" 2>/dev/null)" || m_normalized="$m"
    m_normalized="${m_normalized%/}"
    # Exact match
    [[ "$m_normalized" == "$normalized" ]] && {
      found=1
      break
    }
    # Descendant match
    [[ "$m_normalized" == "${normalized_with_slash}"* ]] && {
      found=1
      break
    }
  done <<<"$all_mounts"

  if ((found)); then
    warn "_cleanup_assert_no_mounts_under: mount(s) remain under $dir"
    return 1
  fi

  return 0
}

# cleanup_unmount_registered
#   Unmount all tracked mounts in reverse registration order.
#   Returns 0 if all unmounted, 1 if any remain.
cleanup_unmount_registered() {
  local rc=0
  local i

  local _mount_count=0
  [[ ${CLEANUP_MOUNTS[0]+_} ]] && _mount_count=${#CLEANUP_MOUNTS[@]}
  cleanup_log "=== cleanup_unmount_registered: start ($_mount_count mounts) ==="
  cleanup_log_namespace

  # Reverse iteration
  local _n=0
  [[ ${CLEANUP_MOUNTS[0]+_} ]] && _n=${#CLEANUP_MOUNTS[@]}
  for ((i = _n - 1; i >= 0; i--)); do
    local m="${CLEANUP_MOUNTS[$i]}"
    local label="${CLEANUP_MOUNT_LABELS[$i]:-}"
    local expected_id="${CLEANUP_MOUNT_IDS[$i]:-}"

    # Step 1: Check mount existence FIRST — before any containment validation.
    # When a parent mount was removed during cleanup ordering, the child mount's
    # path becomes unreachable, realpath fails, and this was misinterpreted as
    # "outside workspace." By checking existence first, we correctly distinguish
    # "already unmounted" from "outside workspace."
    if ! mountpoint -q "$m" 2>/dev/null; then
      # Path may not exist anymore (parent unmounted) or mount was already released.
      # Check kernel mountinfo to distinguish "already unmounted" from "target unavailable".
      local _mountinfo_ok=0
      local _mount_still_tracked=0
      if [[ -n "$expected_id" ]]; then
        local _mountinfo_line
        # Look for the exact mount ID in kernel mountinfo and verify the target matches
        if _mountinfo_line="$(findmnt -rno ID,TARGET --kernel 2>/dev/null | grep -w "$expected_id")"; then
          _mountinfo_ok=1
          # Extract the target from the mountinfo line and compare with the stored normalized path
          local _info_target
          _info_target="$(echo "$_mountinfo_line" | awk '{print $2}')"
          # Use the normalized path for comparison (the canonical form we registered)
          local _compare_target="${CLEANUP_MOUNT_NORMALIZED[$i]:-$m}"
          if [[ "$_info_target" == "$_compare_target" ]]; then
            _mount_still_tracked=1
          fi
        fi
      fi

      if ((_mount_still_tracked)); then
        # Mount ID still at registered target but path inaccessible
        warn "cleanup_unmount_registered: $m target unavailable (mount ID $expected_id still in kernel but path inaccessible)"
        cleanup_log "SKIP (target unavailable): $m (label=${label:-unknown})"
        rc=1
        continue
      fi

      if ((_mountinfo_ok)); then
        # Mount ID found but at a different target — identity/target changed
        warn "cleanup_unmount_registered: $m identity/target changed (mount ID $expected_id moved to $_info_target) — preserving"
        cleanup_log "SKIP (identity changed): $m (ID=$expected_id, current target=$_info_target, label=${label:-unknown})"
        rc=1
        continue
      fi

      # Mount ID not found in kernel mount table — already unmounted
      debug "cleanup_unmount_registered: $m already unmounted"
      cleanup_log "SKIP (already unmounted): $m (label=${label:-unknown})"
      continue
    fi

    # Step 2: Mount is accessible — check for stacked mounts before identity verification
    local _mount_targets
    _mount_targets="$(findmnt -rno TARGET --kernel -M "$m" 2>/dev/null)" || _mount_targets=""
    local _target_count
    _target_count="$(echo "$_mount_targets" | grep -c . 2>/dev/null)" || _target_count=0

    if ((_target_count > 1)); then
      warn "cleanup_unmount_registered: $m has stacked mounts ($_target_count) — refusing teardown"
      cleanup_log "SKIP (stacked mounts): $m (count=$_target_count, label=${label:-unknown})"
      rc=1
      continue
    fi

    # Step 3: Validate containment using stored normalized path
    if [[ -n "$CLEANUP_WORKSPACE_ROOT" ]]; then
      local _vrc=0
      _cleanup_validate_workspace "$m" "${CLEANUP_MOUNT_NORMALIZED[$i]:-}" || _vrc=$?
      if ((_vrc == 2)); then
        warn "cleanup_unmount_registered: $m target unavailable (cannot canonicalize)"
        cleanup_log "SKIP (target unavailable): $m (label=${label:-unknown})"
        rc=1
        continue
      elif ((_vrc != 0)); then
        warn "cleanup_unmount_registered: $m outside workspace — preserving"
        cleanup_log "SKIP (outside workspace): $m (label=${label:-unknown})"
        rc=1
        continue
      fi
    fi

    # Step 4: Identity verification (composite: id:source:fstype:options)
    local expected_identity="${CLEANUP_MOUNT_IDENTITIES[$i]:-}"
    local current_identity
    current_identity="$(_cleanup_capture_mount_identity "$m" 2>/dev/null)" || current_identity=""

    if [[ -z "$expected_identity" ]]; then
      # Legacy record without composite identity — fall back to ID-only check
      local _legacy_id="${CLEANUP_MOUNT_IDS[$i]:-}"
      local _current_id
      _current_id="$(findmnt -rno ID -M "$m" --kernel 2>/dev/null | head -1)" || _current_id=""
      if [[ -z "$_legacy_id" || -z "$_current_id" ]]; then
        warn "cleanup_unmount_registered: cannot verify identity of $m — preserving"
        cleanup_log "SKIP (identity unverifiable): $m (label=${label:-unknown})"
        rc=1
        continue
      fi
      if [[ "$_current_id" != "$_legacy_id" ]]; then
        warn "cleanup_unmount_registered: $m identity changed ($_legacy_id → $_current_id) — preserving"
        cleanup_log "SKIP (identity changed): $m ($_legacy_id → $_current_id, label=${label:-unknown})"
        rc=1
        continue
      fi
    elif [[ -z "$current_identity" ]]; then
      warn "cleanup_unmount_registered: cannot verify identity of $m — mount not found in mountinfo"
      cleanup_log "SKIP (identity unverifiable): $m (label=${label:-unknown})"
      rc=1
      continue
    else
      # Detect numeric-only stored identity (legacy/fallback from failed _cleanup_capture_mount_identity)
      if [[ "$expected_identity" == *:* ]]; then
        # Composite identity — parse and compare all components
        local _e_id _e_src _e_fstype _e_opts
        _e_id="$(echo "$expected_identity" | cut -d: -f1)"
        _e_src="$(echo "$expected_identity" | cut -d: -f2)"
        _e_fstype="$(echo "$expected_identity" | cut -d: -f3)"
        _e_opts="$(echo "$expected_identity" | cut -d: -f4-)"

        # Parse current identity: id:source:fstype:options
        local _c_id _c_src _c_fstype _c_opts
        _c_id="$(echo "$current_identity" | cut -d: -f1)"
        _c_src="$(echo "$current_identity" | cut -d: -f2)"
        _c_fstype="$(echo "$current_identity" | cut -d: -f3)"
        _c_opts="$(echo "$current_identity" | cut -d: -f4-)"

        # Check source — this is the strongest identity signal
        if [[ "$_c_src" != "$_e_src" ]]; then
          warn "cleanup_unmount_registered: $m source changed ($_e_src → $_c_src) — different mount, preserving"
          cleanup_log "SKIP (identity changed): $m (source=$_e_src → $_c_src, label=${label:-unknown})"
          rc=1
          continue
        fi

        # Check fstype — a different filesystem type means a different mount
        if [[ "$_c_fstype" != "$_e_fstype" ]]; then
          warn "cleanup_unmount_registered: $m fstype changed ($_e_fstype → $_c_fstype) — different mount, preserving"
          cleanup_log "SKIP (identity changed): $m (fstype=$_e_fstype → $_c_fstype, label=${label:-unknown})"
          rc=1
          continue
        fi

        # Check mount ID — if changed, log a warning but don't refuse if source+fstype match
        if [[ "$_c_id" != "$_e_id" ]]; then
          warn "cleanup_unmount_registered: $m mount ID changed ($_e_id → $_c_id) — source/fstype still match, proceeding"
          cleanup_log "NOTICE (mount ID changed): $m ($_e_id → $_c_id, source=$_c_src, fstype=$_c_fstype, label=${label:-unknown})"
        fi

        # Check options — warn on drift but don't refuse
        if [[ "$_c_opts" != "$_e_opts" ]]; then
          warn "cleanup_unmount_registered: $m options changed ($_e_opts → $_c_opts)"
          cleanup_log "NOTICE (options changed): $m ($_e_opts → $_c_opts, label=${label:-unknown})"
        fi
      else
        # Legacy or fallback identity (numeric-only mount ID) — use ID-only comparison
        local _current_id_only
        _current_id_only="$(findmnt -rno ID -M "$m" --kernel 2>/dev/null | head -1)" || _current_id_only=""
        if [[ -z "$_current_id_only" ]]; then
          warn "cleanup_unmount_registered: cannot verify identity of $m — mount not found in mountinfo"
          cleanup_log "SKIP (identity unverifiable): $m (label=${label:-unknown})"
          rc=1
          continue
        fi
        if [[ "$expected_identity" != "$_current_id_only" ]]; then
          warn "cleanup_unmount_registered: $m identity changed ($expected_identity → $_current_id_only) — preserving"
          cleanup_log "SKIP (identity changed): $m ($expected_identity → $_current_id_only, label=${label:-unknown})"
          rc=1
          continue
        fi
      fi
    fi

    # Ledger: mark releasing
    if [[ -n "$_LEDGER_RUN_DIR" ]]; then
      _cleanup_ledger_mark_releasing "mount:$m" || true
    fi

    if strict_unmount "$m" "${label:-cleanup}"; then
      # Ledger: mark released
      if [[ -n "$_LEDGER_RUN_DIR" ]]; then
        _cleanup_ledger_mark_released "mount:$m" || true
      fi
      debug "cleanup_unmount_registered: unmounted $m"
    else
      warn "cleanup_unmount_registered: failed to unmount $m (label=${label:-unknown})"
      # Detailed diagnostics: findmnt tree for the failed mount
      local _mnt_detail
      _mnt_detail="$(findmnt -R "$m" 2>/dev/null || true)"
      if [[ -n "$_mnt_detail" ]]; then
        warn "  findmnt for $m:"
        emit_prefixed_lines warn "    " "$_mnt_detail"
      fi
      # Processes holding the mount busy
      local _fuser_out
      _fuser_out="$(fuser -vm "$m" 2>&1 || true)"
      if [[ -n "$_fuser_out" ]]; then
        warn "  Processes using $m:"
        emit_prefixed_lines warn "    " "$_fuser_out"
      else
        warn "  No processes found using $m (mount may be held by kernel or namespace)"
      fi
      # Check if mount is in a different mount namespace
      local _mnt_ns
      _mnt_ns="$(findmnt -rno TARGET,PROPAGATION -M "$m" 2>/dev/null || true)"
      if [[ -n "$_mnt_ns" ]]; then
        debug "  Mount propagation info: $_mnt_ns"
      fi
      rc=1
    fi
  done

  cleanup_log "=== cleanup_unmount_registered: done (rc=$rc) ==="
  return "$rc"
}

# _cleanup_detach_registered_loops
#   Detach all tracked loop devices.
#   Returns 0 if all detached, 1 if any remain.
_cleanup_detach_registered_loops() {
  local rc=0
  local i

  local _loop_count=0
  [[ ${CLEANUP_LOOPS[0]+_} ]] && _loop_count=${#CLEANUP_LOOPS[@]}
  cleanup_log "=== _cleanup_detach_registered_loops: start ($_loop_count loops) ==="

  # Read configured-loop inventory once — failure means we can't verify
  local loop_inventory
  loop_inventory="$(losetup -a 2>/dev/null)" || {
    warn "_cleanup_detach_registered_loops: cannot read loop inventory"
    cleanup_log "LOOP_DETACH FAILED: cannot read loop inventory"
    CLEANUP_INCOMPLETE=1
    return 1
  }

  # Verify no unexpected mounts remain before detaching loops
  if [[ -n "$CLEANUP_WORKSPACE_ROOT" ]]; then
    if ! _cleanup_assert_no_mounts_under "$CLEANUP_WORKSPACE_ROOT"; then
      warn "_cleanup_detach_registered_loops: unexpected mounts remain under workspace — preserving loops"
      cleanup_log "LOOP_DETACH BLOCKED: unexpected mounts remain under workspace"
      # Detailed diagnostics: show exactly what mounts are still present
      warn "  Workspace root: $CLEANUP_WORKSPACE_ROOT"
      local _ws_mounts
      _ws_mounts="$(findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS --submounts -M "$CLEANUP_WORKSPACE_ROOT" 2>/dev/null || true)"
      if [[ -n "$_ws_mounts" ]]; then
        warn "  Unexpected mounts under $CLEANUP_WORKSPACE_ROOT:"
        emit_prefixed_lines warn "    " "$_ws_mounts"
      else
        # Fallback: try broader search
        _ws_mounts="$(findmnt -rno TARGET,SOURCE,FSTYPE 2>/dev/null | grep -F "$CLEANUP_WORKSPACE_ROOT" || true)"
        if [[ -n "$_ws_mounts" ]]; then
          warn "  Mounts matching workspace root:"
          emit_prefixed_lines warn "    " "$_ws_mounts"
        fi
      fi
      # Show mount namespace info for debugging cross-namespace issues
      local _ws_mnt_ns
      _ws_mnt_ns="$(readlink /proc/self/ns/mnt 2>/dev/null || echo "unknown")"
      debug "  Current mount namespace: $_ws_mnt_ns"
      CLEANUP_INCOMPLETE=1
      return 1
    fi
  fi

  # ── sysfs/loop diagnostics ──────────────────────────────────────────────
  # Dump diagnostic state before entering the detach loop so the cleanup log
  # records the kernel's view of loop/sysfs regardless of per-loop outcome.
  cleanup_log "--- sysfs/loop diagnostics ---"
  cleanup_log "$(findmnt -rn -M /sys -o TARGET,SOURCE,FSTYPE,VFS-OPTIONS,PROPAGATION 2>/dev/null || echo 'findmnt /sys failed')"
  cleanup_log "$(ls -ld /sys/block/loop0 /sys/block/loop0/loop 2>&1 || true)"
  cleanup_log "$(ls -l /sys/block/loop0/loop/backing_file 2>&1 || true)"
  cleanup_log "$(losetup --list --noheadings --output NAME,BACK-FILE,AUTOCLEAR 2>/dev/null || echo 'losetup list failed')"

  local _n=0
  [[ ${CLEANUP_LOOPS[0]+_} ]] && _n=${#CLEANUP_LOOPS[@]}
  for ((i = 0; i < _n; i++)); do
    local l="${CLEANUP_LOOPS[$i]}"
    local expected_backing="${CLEANUP_LOOP_BACKINGS[$i]:-}"

    # Check if loop is still attached using cached inventory
    if ! grep -q "^${l}:" <<<"$loop_inventory" 2>/dev/null; then
      debug "_cleanup_detach_registered_loops: $l already detached"
      cleanup_log "LOOP_DETACH SKIP (already detached): $l"
      continue
    fi

    # ── Dual-source identity verification ──────────────────────────────────
    # Source 1: sysfs
    local _sys_backing="/sys/block/${l##*/}/loop/backing_file"
    local _sysfs_backing=""
    local _sys_path="$_sys_backing"
    if [[ ! -e "$_sys_backing" ]]; then
      warn "Loop sysfs backing path absent: $_sys_path"
    elif [[ ! -r "$_sys_backing" ]]; then
      warn "Loop sysfs backing path unreadable: $_sys_path"
    else
      _sysfs_backing="$(< "$_sys_backing")" 2>/dev/null || {
        warn "Failed reading loop backing path: $_sys_path"
        _sysfs_backing=""
      }
      if [[ -n "$_sysfs_backing" ]]; then
        debug "Loop backing identity: device=$l sysfs=$_sys_path backing=$_sysfs_backing"
      fi
    fi

    # Source 2: losetup
    local _losetup_backing=""
    local _losetup_line
    _losetup_line="$(losetup "$l" 2>/dev/null)" || _losetup_line=""
    if [[ -n "$_losetup_line" ]]; then
      # Parse backing file from losetup output
      # Format: /dev/loop0: []: (/path/to/file)
      # or:     /dev/loop0: []: (/path/to/file (deleted))
      _losetup_backing="${_losetup_line#*(}"
      _losetup_backing="${_losetup_backing%)}"
      _losetup_backing="${_losetup_backing% (deleted)}"
    fi

    # Resolve identities (device:inode) for each available source
    local _sys_id=""
    local _lo_id=""
    local _sys_available=0
    local _lo_available=0
    local _sys_resolved=0
    local _lo_resolved=0

    if [[ -n "$_sysfs_backing" ]]; then
      _sys_available=1
      if [[ -e "$_sysfs_backing" ]]; then
        _sys_id="$(stat -c '%d:%i' "$_sysfs_backing" 2>/dev/null)" || _sys_id=""
        if [[ -n "$_sys_id" ]]; then
          _sys_resolved=1
        fi
      fi
    fi

    if [[ -n "$_losetup_backing" ]]; then
      _lo_available=1
      if [[ -e "$_losetup_backing" ]]; then
        _lo_id="$(stat -c '%d:%i' "$_losetup_backing" 2>/dev/null)" || _lo_id=""
        if [[ -n "$_lo_id" ]]; then
          _lo_resolved=1
        fi
      fi
    fi

    # Log both sources with all resolved identities
    debug "Identity sources for $l: registered=$expected_backing sysfs=$_sysfs_backing (id=$_sys_id) losetup=$_losetup_backing (id=$_lo_id)"
    cleanup_log "IDENTITY $l registered=$expected_backing sysfs=$_sysfs_backing (id=$_sys_id) losetup=$_losetup_backing (id=$_lo_id) autoclear=$(losetup -l -O AUTOCLEAR "$l" 2>/dev/null | tail -1 || echo '?')"

    # Decision tree: dual-source identity verification
    local _current_backing_id=""
    local _authorize=0
    local _resolved_mismatch=0

    if ((_sys_resolved && _lo_resolved)); then
      # Both sources resolved — check for agreement first
      if [[ "$_sys_id" == "$_lo_id" && -n "$_sys_id" ]]; then
        # Sources agree with each other — check against registered
        if [[ "$_sys_id" == "$expected_backing" ]]; then
          debug "Both sources agree and match registered identity for $l"
          _current_backing_id="$_sys_id"
          _authorize=1
        else
          warn "$l identity MISMATCH: both sources agree (id=$_sys_id) but registered=$expected_backing"
          cleanup_log "LOOP_DETACH MISMATCH: $l both=$_sys_id registered=$expected_backing"
        fi
      else
        # Sources disagree — preserve and log
        warn "$l identity DISAGREEMENT: sysfs=$_sysfs_backing (id=$_sys_id) vs losetup=$_losetup_backing (id=$_lo_id) vs registered=$expected_backing"
        cleanup_log "LOOP_DETACH DISAGREEMENT: $l sysfs=$_sysfs_backing($_sys_id) losetup=$_losetup_backing($_lo_id) registered=$expected_backing"
      fi
    elif ((_sys_resolved && !_lo_resolved)); then
      # Only sysfs resolved
      if [[ -n "$_sys_id" && "$_sys_id" == "$expected_backing" ]]; then
        debug "Only sysfs resolved and matches registered identity for $l"
        _current_backing_id="$_sys_id"
        _authorize=1
      elif [[ -n "$_sys_id" ]]; then
        # sysfs resolved an identity that doesn't match registered — preserve
        _resolved_mismatch=1
      elif [[ -z "$_sys_id" && -n "$_sysfs_backing" ]]; then
        # sysfs path exists but stat failed — try workspace fallback
        if [[ -n "${CLEANUP_WORKSPACE_ROOT:-}" ]]; then
          local _sys_ws_resolved
          _sys_ws_resolved="$(realpath -m "$_sysfs_backing" 2>/dev/null)" || _sys_ws_resolved="$_sysfs_backing"
          if [[ "$_sys_ws_resolved" == "${CLEANUP_WORKSPACE_ROOT%/}"/* ]]; then
            debug "sysfs backing stale but inside workspace — accepting registered identity for $l"
            cleanup_log "LOOP_DETACH STALE-WORKSPACE fallback: $l sysfs=$_sysfs_backing"
            _current_backing_id="$expected_backing"
            _authorize=1
          fi
        fi
      fi
    elif ((!_sys_resolved && _lo_resolved)); then
      # Only losetup resolved
      if [[ -n "$_lo_id" && "$_lo_id" == "$expected_backing" ]]; then
        debug "Only losetup resolved and matches registered identity for $l"
        _current_backing_id="$_lo_id"
        _authorize=1
      elif [[ -n "$_lo_id" ]]; then
        # losetup resolved an identity that doesn't match registered — preserve
        _resolved_mismatch=1
      elif [[ -n "$_losetup_backing" && -z "$_lo_id" && -n "${CLEANUP_WORKSPACE_ROOT:-}" ]]; then
        # Backing file deleted/renamed — check if path was in workspace
        local _lo_ws_resolved
        _lo_ws_resolved="$(realpath -m "$_losetup_backing" 2>/dev/null)" || _lo_ws_resolved="$_losetup_backing"
        if [[ "$_lo_ws_resolved" == "${CLEANUP_WORKSPACE_ROOT%/}"/* ]]; then
          debug "losetup backing deleted but inside workspace — accepting registered identity for $l"
          cleanup_log "LOOP_DETACH WORKSPACE-DELETED fallback: $l losetup=$_losetup_backing"
          _current_backing_id="$expected_backing"
          _authorize=1
        fi
      fi
    fi

    # Workspace fallbacks: only when no source resolved a mismatching identity
    # (when a source resolved but doesn't match registered, we must preserve
    # unconditionally — no fallbacks)
    if ((!_authorize && !_resolved_mismatch)); then
      local _both_resolved=0
      if ((_sys_resolved && _lo_resolved)); then
        _both_resolved=1
      fi

      if ((_both_resolved)); then
        # Both sources resolved but neither matched registered identity —
        # this is a disagreement or agreed-mismatch; preserve unconditionally
        warn "_cleanup_detach_registered_loops: $l both sources resolved but neither matches — preserving"
        cleanup_log "LOOP_DETACH PRESERVE (both resolved, no match): $l"
      elif [[ -n "${CLEANUP_WORKSPACE_ROOT:-}" ]]; then
        # At least one source unavailable — try workspace fallbacks
        # Workspace fallback for stale sysfs path (the original rename case)
        if [[ -z "$_current_backing_id" && -n "$_sysfs_backing" ]]; then
          local _sys_fb_resolved
          _sys_fb_resolved="$(realpath -m "$_sysfs_backing" 2>/dev/null)" || _sys_fb_resolved="$_sysfs_backing"
          if [[ "$_sys_fb_resolved" == "${CLEANUP_WORKSPACE_ROOT%/}"/* ]]; then
            debug "sysfs backing stale but inside workspace — accepting registered identity for $l"
            cleanup_log "LOOP_DETACH STALE-WORKSPACE fallback: $l sysfs=$_sysfs_backing"
            _current_backing_id="$expected_backing"
            _authorize=1
          fi
        fi
        # Workspace fallback for deleted losetup path
        if [[ -z "$_current_backing_id" && -n "$_losetup_backing" ]]; then
          local _lo_fb_resolved
          _lo_fb_resolved="$(realpath -m "$_losetup_backing" 2>/dev/null)" || _lo_fb_resolved="$_losetup_backing"
          if [[ "$_lo_fb_resolved" == "${CLEANUP_WORKSPACE_ROOT%/}"/* ]]; then
            debug "losetup backing deleted but inside workspace — accepting registered identity for $l"
            cleanup_log "LOOP_DETACH WORKSPACE-DELETED fallback: $l losetup=$_losetup_backing"
            _current_backing_id="$expected_backing"
            _authorize=1
          fi
        fi
      fi
    fi

    # If all identity checks failed, we cannot verify identity — preserve the loop
    if [[ -z "$_current_backing_id" ]]; then
      warn "_cleanup_detach_registered_loops: $l identity verification failed — preserving"
      warn "  registered=$expected_backing sysfs=$_sysfs_backing losetup=$_losetup_backing"
      cleanup_log "LOOP_DETACH SKIP (identity unverifiable): $l registered=$expected_backing sysfs=$_sysfs_backing losetup=$_losetup_backing"
      rc=1
      continue
    fi

    if [[ -z "$expected_backing" ]]; then
      warn "_cleanup_detach_registered_loops: cannot verify identity of $l — preserving"
      cleanup_log "LOOP_DETACH SKIP (missing identity): $l"
      rc=1
      continue
    fi

    # Ledger: compute loop ID from backing file path (matches creation ID format)
    local _pf_ledger_loop_id=""
    if [[ -f "/sys/block/${l##*/}/loop/backing_file" ]]; then
      local _pf_bp_path
      _pf_bp_path="$(cat "/sys/block/${l##*/}/loop/backing_file" 2>/dev/null)" || _pf_bp_path=""
      _pf_bp_path="${_pf_bp_path% (deleted)}"
      if [[ -n "$_pf_bp_path" ]]; then
        _pf_ledger_loop_id="loop:$(realpath "$_pf_bp_path" 2>/dev/null || printf '%s' "$_pf_bp_path")"
      fi
    fi

    # Ledger: mark releasing
    if [[ -n "$_LEDGER_RUN_DIR" && -n "$_pf_ledger_loop_id" ]]; then
      _cleanup_ledger_mark_releasing "$_pf_ledger_loop_id" || true
    fi

    # Wait for ext4 superblock to release before detaching
    if ! wait_ext4_gone "$l" 2>/dev/null; then
      warn "_cleanup_detach_registered_loops: ext4 superblock still alive for $l — proceeding anyway"
      cleanup_log "LOOP_DETACH WARN: ext4 superblock still alive for $l"
    fi

    cleanup_log "LOOP_DETACH $l (backing: ${expected_backing:-unknown})"
    # Detach loop
    if strict_detach_loop "$l" 2>/dev/null; then
      # Ledger: mark released
      if [[ -n "$_LEDGER_RUN_DIR" && -n "$_pf_ledger_loop_id" ]]; then
        _cleanup_ledger_mark_released "$_pf_ledger_loop_id" || true
      fi
      debug "_cleanup_detach_registered_loops: detached $l"
      cleanup_log "LOOP_DETACH OK: $l"
    else
      warn "_cleanup_detach_registered_loops: failed to detach $l (backing: ${expected_backing:-unknown})"
      cleanup_log "LOOP_DETACH FAILED: $l (backing: ${expected_backing:-unknown})"
      rc=1
    fi
  done

  # Post-detach verification: confirm all tracked loops are actually detached
  local verify_rc=0
  local _n2=0
  [[ ${CLEANUP_LOOPS[0]+_} ]] && _n2=${#CLEANUP_LOOPS[@]}
  for ((i = 0; i < _n2; i++)); do
    local _pf_vl="${CLEANUP_LOOPS[$i]}"
    if [[ -f "/sys/block/${_pf_vl##*/}/loop/backing_file" ]] || losetup "$_pf_vl" &>/dev/null; then
      warn "_cleanup_detach_registered_loops: $_pf_vl still attached after detach attempts"
      verify_rc=1
    fi
  done

  if ((verify_rc != 0)); then
    warn "_cleanup_detach_registered_loops: some loops could not be detached"
    cleanup_log "LOOP_DETACH VERIFICATION FAILED: some loops could not be detached"
    CLEANUP_INCOMPLETE=1
  fi

  cleanup_log "=== _cleanup_detach_registered_loops: done (rc=$rc) ==="
  return $((rc || verify_rc))
}

# _cleanup_remove_registered_tempdirs
#   Remove registered temporary directories (must be empty after unmounting).
#   Returns 0 if all removed, 1 if any remain.
_cleanup_remove_registered_tempdirs() {
  local rc=0
  local i

  local _tempdir_count=0
  [[ ${CLEANUP_TEMPDIRS[0]+_} ]] && _tempdir_count=${#CLEANUP_TEMPDIRS[@]}
  cleanup_log "=== _cleanup_remove_registered_tempdirs: start ($_tempdir_count dirs) ==="

  # Reverse iteration (same as mounts)
  local _n=0
  [[ ${CLEANUP_TEMPDIRS[0]+_} ]] && _n=${#CLEANUP_TEMPDIRS[@]}
  for ((i = _n - 1; i >= 0; i--)); do
    local d="${CLEANUP_TEMPDIRS[$i]}"

    if [[ ! -d "$d" ]]; then
      # Directory does not exist — already cleaned or parent removed
      debug "_cleanup_remove_registered_tempdirs: $d does not exist (already clean or parent removed)"
      cleanup_log "TEMPDIR SKIP (absent): $d"
      continue
    fi

    # Revalidate path is still inside workspace before removal
    if [[ -n "$CLEANUP_WORKSPACE_ROOT" ]]; then
      local _vrc=0
      _cleanup_validate_workspace "$d" || _vrc=$?
      if ((_vrc == 2)); then
        warn "_cleanup_remove_registered_tempdirs: $d target unavailable (cannot canonicalize)"
        cleanup_log "TEMPDIR SKIP (target unavailable): $d"
        rc=1
        continue
      elif ((_vrc != 0)); then
        warn "_cleanup_remove_registered_tempdirs: $d outside workspace — preserving"
        cleanup_log "TEMPDIR SKIP (outside workspace): $d"
        rc=1
        continue
      fi
    fi

    cleanup_log "TEMPDIR REMOVE: $d"
    # rmdir handles emptiness check internally — no separate ls -A race
    if ! rmdir "$d" 2>/dev/null; then
      warn "_cleanup_remove_registered_tempdirs: could not remove $d (not empty or still in use)"
      cleanup_log "TEMPDIR REMOVE FAILED: $d"
      rc=1
    else
      cleanup_log "TEMPDIR REMOVE OK: $d"
    fi
  done

  # Post-removal verification: confirm all tracked tempdirs are actually gone
  local _n2=0
  [[ ${CLEANUP_TEMPDIRS[0]+_} ]] && _n2=${#CLEANUP_TEMPDIRS[@]}
  for ((i = 0; i < _n2; i++)); do
    if [[ -d "${CLEANUP_TEMPDIRS[$i]}" ]]; then
      warn "_cleanup_remove_registered_tempdirs: ${CLEANUP_TEMPDIRS[$i]} still exists after removal"
      cleanup_log "TEMPDIR VERIFY FAILED: ${CLEANUP_TEMPDIRS[$i]} still exists"
      rc=1
    fi
  done

  cleanup_log "=== _cleanup_remove_registered_tempdirs: done (rc=$rc) ==="
  return "$rc"
}

# cleanup_environment
#   Orchestrate cleanup of all registered resources.
#   Order: stop jobs → unmount → verify mounts → detach loops → remove dirs → verify
#   Returns 0 if fully clean, 1 if incomplete (preserves what it can't clean).
cleanup_environment() {
  if ((CLEANUP_RUNNING)); then
    warn "cleanup_environment: cleanup already running"
    return 1
  fi

  local mounts_ok=1
  local loops_ok=1

  CLEANUP_RUNNING=1
  CLEANUP_INCOMPLETE=0
  CLEANUP_ATTEMPTED=1

  local _env_mount_count=0 _env_loop_count=0 _env_tempdir_count=0
  [[ ${CLEANUP_MOUNTS[0]+_} ]] && _env_mount_count=${#CLEANUP_MOUNTS[@]}
  [[ ${CLEANUP_LOOPS[0]+_} ]] && _env_loop_count=${#CLEANUP_LOOPS[@]}
  [[ ${CLEANUP_TEMPDIRS[0]+_} ]] && _env_tempdir_count=${#CLEANUP_TEMPDIRS[@]}
  cleanup_log "=== cleanup_environment: start (mounts=$_env_mount_count loops=$_env_loop_count tempdirs=$_env_tempdir_count) ==="
  cleanup_log_namespace
  cleanup_log_mount_state

  # Phase 0: Stop background workers
  cleanup_log "--- Phase 0: stop workers ---"
  # Use the robust stop function (SIGTERM → wait → SIGKILL → verify).
  _cleanup_stop_workers || {
    warn "cleanup_environment: some workers could not be stopped — proceeding with unmount"
  }

  # Phase 1: Unmount registered mounts
  cleanup_log "--- Phase 1: unmount registered mounts ---"
  cleanup_unmount_registered || mounts_ok=0

  # Phase 1.5: Prune mounts that are no longer in workspace
  # (these were handled by overlay_cleanup or other subsystems)
  cleanup_log "--- Phase 1.5: prune outside-workspace mounts ---"
  _cleanup_prune_outside_workspace_mounts

  # Phase 2: Verify mounts are released
  cleanup_log "--- Phase 2: verify mounts released ---"
  _cleanup_check_tracked_mounts || mounts_ok=0

  if ((!mounts_ok)); then
    warn "cleanup_environment: mount cleanup incomplete — preserving loops and workspace"
    cleanup_log "cleanup_environment: mount cleanup incomplete — aborting"
    warn "  Cleanup status: mounts_ok=$mounts_ok loops_ok=$loops_ok"
    local _warn_mount_count=0 _warn_loop_count=0 _warn_tempdir_count=0
    [[ ${CLEANUP_MOUNTS[0]+_} ]] && _warn_mount_count=${#CLEANUP_MOUNTS[@]}
    [[ ${CLEANUP_LOOPS[0]+_} ]] && _warn_loop_count=${#CLEANUP_LOOPS[@]}
    [[ ${CLEANUP_TEMPDIRS[0]+_} ]] && _warn_tempdir_count=${#CLEANUP_TEMPDIRS[@]}
    warn "  Registered mounts: $_warn_mount_count, loops: $_warn_loop_count, tempdirs: $_warn_tempdir_count"
    # Show which mounts are still tracked (not yet released)
    local _ce_i
    local _ce_remaining=0
    local _ce_n=0
    [[ ${CLEANUP_MOUNTS[0]+_} ]] && _ce_n=${#CLEANUP_MOUNTS[@]}
    for ((_ce_i = 0; _ce_i < _ce_n; _ce_i++)); do
      if mountpoint -q "${CLEANUP_MOUNTS[$_ce_i]}" 2>/dev/null; then
        warn "  Still mounted: ${CLEANUP_MOUNTS[$_ce_i]} (label=${CLEANUP_MOUNT_LABELS[$_ce_i]:-unknown})"
        _ce_remaining=$((_ce_remaining + 1))
      fi
    done
    warn "  Mounts still mounted: $_ce_remaining of $_ce_n"
    CLEANUP_INCOMPLETE=1
    CLEANUP_RUNNING=0
    return 1
  fi

  # Phase 3: Detach registered loops
  cleanup_log "--- Phase 3: detach registered loops ---"
  _cleanup_detach_registered_loops || loops_ok=0

  if ((!loops_ok)); then
    warn "cleanup_environment: loop cleanup incomplete — preserving workspace"
    cleanup_log "cleanup_environment: loop cleanup incomplete — aborting"
    warn "  Cleanup status: mounts_ok=$mounts_ok loops_ok=$loops_ok"
    # Show which loops are still tracked
    local _ce_li
    local _ce_remaining_loops=0
    local _ce_ln=0
    [[ ${CLEANUP_LOOPS[0]+_} ]] && _ce_ln=${#CLEANUP_LOOPS[@]}
    for ((_ce_li = 0; _ce_li < _ce_ln; _ce_li++)); do
      if losetup "${CLEANUP_LOOPS[$_ce_li]}" &>/dev/null; then
        warn "  Still attached: ${CLEANUP_LOOPS[$_ce_li]} (label=${CLEANUP_LOOP_LABELS[$_ce_li]:-unknown})"
        _ce_remaining_loops=$((_ce_remaining_loops + 1))
      fi
    done
    warn "  Loops still attached: $_ce_remaining_loops of $_ce_ln"
    CLEANUP_INCOMPLETE=1
    CLEANUP_RUNNING=0
    return 1
  fi

  # Phase 4: Remove registered temp directories
  cleanup_log "--- Phase 4: remove registered tempdirs ---"
  local rc=0
  _cleanup_remove_registered_tempdirs || rc=1

  # Phase 5: Final verification
  cleanup_log "--- Phase 5: final verification ---"
  cleanup_verify || rc=1

  # Ledger: mark run as CLEAN
  if ((rc == 0)) && [[ -n "$_LEDGER_RUN_DIR" ]]; then
    cleanup_ledger_finish || true
  fi

  CLEANUP_INCOMPLETE=$rc
  CLEANUP_RUNNING=0

  cleanup_log "=== cleanup_environment: done (rc=$rc) ==="
  return "$rc"
}

# cleanup_verify
#   Verify the workspace is fully clean.
#   Returns 0 if clean, 1 if residuals remain.
cleanup_verify() {
  local rc=0

  # Check tracked mounts are gone
  _cleanup_check_tracked_mounts || rc=1

  # Check tracked loops are detached (with identity verification)
  local i
  local _n=0
  [[ ${CLEANUP_LOOPS[0]+_} ]] && _n=${#CLEANUP_LOOPS[@]}
  for ((i = 0; i < _n; i++)); do
    local l="${CLEANUP_LOOPS[$i]}"
    local expected_id="${CLEANUP_LOOP_BACKINGS[$i]:-}"

    local is_attached=0
    if [[ -f "/sys/block/${l##*/}/loop/backing_file" ]]; then
      is_attached=1
    elif losetup "$l" &>/dev/null; then
      is_attached=1
    fi

    if ((is_attached)); then
      if [[ -n "$expected_id" ]]; then
        local current_backing=""
        if [[ -f "/sys/block/${l##*/}/loop/backing_file" ]]; then
          current_backing="$(cat "/sys/block/${l##*/}/loop/backing_file" 2>/dev/null)" || current_backing=""
          if [[ -n "$current_backing" && -e "$current_backing" ]]; then
            current_backing="$(stat -c '%d:%i' "$current_backing" 2>/dev/null)" || current_backing=""
          fi
        fi
        if [[ -n "$current_backing" && "$current_backing" != "$expected_id" ]]; then
          warn "cleanup_verify: $l identity changed ($expected_id → $current_backing)"
          rc=1
        elif [[ -z "$current_backing" ]]; then
          warn "cleanup_verify: $l still attached but identity unverifiable"
          rc=1
        else
          warn "cleanup_verify: $l still attached with correct identity"
          rc=1
        fi
      else
        warn "cleanup_verify: $l still attached"
        rc=1
      fi
    fi
  done

  # Check tracked tempdirs are gone
  local _n2=0
  [[ ${CLEANUP_TEMPDIRS[0]+_} ]] && _n2=${#CLEANUP_TEMPDIRS[@]}
  for ((i = 0; i < _n2; i++)); do
    if [[ -d "${CLEANUP_TEMPDIRS[$i]}" ]]; then
      warn "cleanup_verify: ${CLEANUP_TEMPDIRS[$i]} still exists"
      rc=1
    fi
  done

  # Check for untracked resources under workspace
  if [[ -n "$CLEANUP_WORKSPACE_ROOT" ]]; then
    _audit_workspace_strays "$CLEANUP_WORKSPACE_ROOT" || rc=1
  fi

  if ((rc == 0)); then
    debug "cleanup_verify: workspace is clean"
  fi

  return "$rc"
}

# _cleanup_reset
#   Clear all tracking state. Call after successful cleanup or before a new run.
_cleanup_reset() {
  if ((CLEANUP_RUNNING)); then
    warn "_cleanup_reset: cannot reset during cleanup"
    return 1
  fi

  local has_registrations=0
  [[ ${CLEANUP_MOUNTS[0]+_} ]] && has_registrations=1
  [[ ${CLEANUP_LOOPS[0]+_} ]] && has_registrations=1
  [[ ${CLEANUP_TEMPDIRS[0]+_} ]] && has_registrations=1

  if ((has_registrations)); then
    # Require cleanup was attempted AND succeeded
    if ((!CLEANUP_ATTEMPTED || CLEANUP_INCOMPLETE)); then
      warn "_cleanup_reset: cannot reset unresolved cleanup state"
      return 1
    fi

    # Verify success before clearing
    if ! cleanup_verify; then
      warn "_cleanup_reset: verification failed — refusing to clear registrations"
      return 1
    fi
  fi

  CLEANUP_MOUNTS=()
  CLEANUP_MOUNT_IDS=()
  CLEANUP_MOUNT_LABELS=()
  CLEANUP_MOUNT_NORMALIZED=()
  CLEANUP_MOUNT_IDENTITIES=()
  CLEANUP_LOOPS=()
  CLEANUP_LOOP_BACKINGS=()
  CLEANUP_LOOP_LABELS=()
  CLEANUP_TEMPDIRS=()
  CLEANUP_RUNNING=0
  CLEANUP_INCOMPLETE=0
  CLEANUP_ATTEMPTED=0
}

# ── Creation-side wrappers ─────────────────────────────────────────────────────
# These wrappers handle the full lifecycle: validate → create → register → rollback on failure.
# ────────────────────────────────────────────────────────────────────────────────

# cleanup_mount TARGET LABEL -- MOUNT_ARGS...
#   Create a mount and register it for cleanup.
#   If mount succeeds but registration fails, immediately unmount.
#   Uses nameref for output (not command substitution).
#   Returns 0 on success, 1 on failure.
cleanup_mount() {
  local target="${1:?cleanup_mount: missing target}"
  local label="${2:-}"
  shift 2 || shift $# # Consume target and label

  # Skip -- separator if present
  [[ "${1:-}" == "--" ]] && shift

  # Capture mount arguments for logging
  local _mount_args=("$@")

  # --- Preconditions ---
  if ((CLEANUP_RUNNING)); then
    warn "cleanup_mount: cannot create mounts during cleanup"
    return 1
  fi

  if [[ -z "$CLEANUP_WORKSPACE_ROOT" ]]; then
    warn "cleanup_mount: CLEANUP_WORKSPACE_ROOT not set — call cleanup_set_workspace first"
    return 1
  fi

  if ! _cleanup_validate_workspace "$target"; then
    return 1
  fi

  # Check target is not already a mountpoint (reject stacking)
  if mountpoint -q "$target" 2>/dev/null; then
    warn "cleanup_mount: $target is already a mountpoint — stacking not supported"
    return 1
  fi

  # Ledger: persist PREPARED record
  # shellcheck disable=SC2155  # fallback printf guarantees non-empty assignment; return value not checked
  local _pf_ledger_id="mount:$(realpath "$target" 2>/dev/null || printf '%s' "$target")"
  if [[ -n "$_LEDGER_RUN_DIR" ]]; then
    _cleanup_ledger_prepare "$_pf_ledger_id" "mount" "$target" "" "$label" || {
      warn "cleanup_mount: ledger prepare failed — aborting"
      return 1
    }
  fi

  # Attempt mount
  log "  Mounting $label: $target ${_mount_args[*]:-}"
  cleanup_log "MOUNT $label: $target ${_mount_args[*]:-}"
  if ! mount "$@" "$target" 2>/dev/null; then
    warn "cleanup_mount: mount failed for $target"
    cleanup_log "MOUNT FAILED $label: $target ${_mount_args[*]:-}"
    return 1
  fi

  # Register for cleanup
  if ! cleanup_track_mount "$target" "$label"; then
    warn "cleanup_mount: registration failed — attempting rollback"
    # Verified rollback only — no unchecked operations
    if strict_unmount "$target" "cleanup_mount rollback" 2>/dev/null; then
      debug "cleanup_mount: rollback succeeded"
    else
      # Clean unmount failed — preserve resource for cleanup_environment
      warn "cleanup_mount: rollback FAILED — $target remains mounted"
      CLEANUP_INCOMPLETE=1
      # Force-register so cleanup_environment can find it
      local _pf_mnt_id
      _pf_mnt_id="$(findmnt -rno ID -M "$target" --kernel 2>/dev/null | head -1)" || _pf_mnt_id=""
      local _forced_identity
      _forced_identity="$(_cleanup_capture_mount_identity "$target" 2>/dev/null)" || _forced_identity="$_pf_mnt_id"
      CLEANUP_MOUNTS+=("$target")
      CLEANUP_MOUNT_IDS+=("$_pf_mnt_id")
      CLEANUP_MOUNT_LABELS+=("${label:-$target}")
      CLEANUP_MOUNT_NORMALIZED+=("$target")
      CLEANUP_MOUNT_IDENTITIES+=("$_forced_identity")
    fi
    return 1
  fi

  # Ledger: transition to ACTIVE
  if [[ -n "$_LEDGER_RUN_DIR" ]]; then
    local _ledger_identity
    _ledger_identity="$(_cleanup_capture_mount_identity "$target")" || _ledger_identity="$(findmnt -rno ID -M "$target" --kernel 2>/dev/null | head -1)"
    _cleanup_ledger_activate "$_pf_ledger_id" "$_ledger_identity" || true
  fi

  cleanup_log "MOUNT OK $label: $target ${_mount_args[*]:-}"
  debug "cleanup_mount: mounted and registered $target"
  return 0
}

# cleanup_mount_readonly_sysfs TARGET [LABEL]
# Mount a fresh read-only sysfs and verify the result.
#
# Creates a single sysfs instance without recursive inheritance of
# auxiliary host mounts (efivars, debugfs, tracefs, configfs, BPF,
# cgroup2, etc.).  The host kernel's sysfs objects remain visible for
# read-only inspection.
#
# Verification checks: mount count, filesystem type, VFS read-only flag,
# and propagation mode.  On any failure the mount is torn down and the
# function returns 1.
cleanup_mount_readonly_sysfs() {
  local target="${1:?cleanup_mount_readonly_sysfs: missing target}"
  local label="${2:-chroot sys}"

  cleanup_mount "$target" "$label" \
    -- -t sysfs -o ro,nosuid,nodev,noexec sysfs ||
    return 1

  local count fstype opts propagation

  count="$(
    findmnt -rn --kernel -M "$target" -o TARGET 2>/dev/null |
    awk 'END { print NR }'
  )" || count=0

  fstype="$(
    findmnt -rn --kernel -M "$target" -o FSTYPE 2>/dev/null
  )" || fstype=""

  opts="$(
    findmnt -rn --kernel -M "$target" -o VFS-OPTIONS 2>/dev/null
  )" || opts=""

  propagation="$(
    findmnt -rn --kernel -M "$target" -o PROPAGATION 2>/dev/null
  )" || propagation=""

  if ((count != 1)) ||
     [[ "$fstype" != "sysfs" ]] ||
     [[ ",$opts," != *,ro,* ]] ||
     [[ -z "$propagation" || "$propagation" == "shared" || "$propagation" == "shared:"* || "$propagation" == "shared,"* ]]; then
    warn "Invalid chroot sysfs: target=$target count=$count fstype=$fstype vfs_options=$opts propagation=$propagation"
    strict_unmount "$target" "$label verification rollback" || true
    return 1
  fi

  debug "$label: sysfs mounted and verified at $target"
  return 0
}

# cleanup_attach_loop BACKING_FILE LABEL [OUTPUT_VAR] -- LOOP_ARGS...
#   Attach a loop device and register it for cleanup.
#   OUTPUT_VAR receives the loop device path (default: CLEANUP_ATTACHED_LOOP).
#   Names starting with _pf_ or CLEANUP_ are reserved and rejected.
cleanup_attach_loop() {
  local _pf_backing="${1:?cleanup_attach_loop: missing backing file}"
  local _pf_label="${2:-}"

  # Parse optional output variable name (3rd arg before --)
  local _pf_output_var="CLEANUP_ATTACHED_LOOP"
  if [[ "${3:-}" != "--" && -n "${3:-}" ]]; then
    _pf_output_var="$3"
    shift 3 || shift $#
  else
    shift 2 || shift $#
  fi
  [[ "${1:-}" == "--" ]] && shift

  # Validate output variable name — must be a valid bash identifier
  if [[ ! "$_pf_output_var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    warn "cleanup_attach_loop: invalid output variable name: $_pf_output_var"
    return 1
  fi

  # Reject output names that collide with internal prefixed names
  case "$_pf_output_var" in
    _pf_* | CLEANUP_*)
      warn "cleanup_attach_loop: output variable name '$_pf_output_var' is reserved"
      return 1
      ;;
  esac

  # --- Preconditions ---
  if ((CLEANUP_RUNNING)); then
    warn "cleanup_attach_loop: cannot create loops during cleanup"
    return 1
  fi

  if [[ -z "$CLEANUP_WORKSPACE_ROOT" ]]; then
    warn "cleanup_attach_loop: CLEANUP_WORKSPACE_ROOT not set"
    return 1
  fi

  if ! _cleanup_validate_workspace "$_pf_backing"; then
    return 1
  fi

  if [[ ! -f "$_pf_backing" ]]; then
    warn "cleanup_attach_loop: backing file does not exist: $_pf_backing"
    return 1
  fi

  # Check for existing loop on this backing file
  local _pf_existing=""
  _pf_existing="$(loops_for_file "$_pf_backing" 2>/dev/null)"
  local _pf_loops_rc=$?

  if [[ -n "$_pf_existing" ]]; then
    local _pf_first_loop
    _pf_first_loop="$(echo "$_pf_existing" | head -1)"
    if [[ -b "$_pf_first_loop" ]] || losetup "$_pf_first_loop" &>/dev/null; then
      warn "cleanup_attach_loop: $_pf_backing already has loop device(s): $_pf_existing"
      return 1
    else
      debug "cleanup_attach_loop: reported loops for $_pf_backing do not exist — proceeding"
    fi
  fi

  if ((_pf_loops_rc != 0)) && [[ -z "$_pf_existing" ]]; then
    warn "cleanup_attach_loop: could not query existing loops for $_pf_backing (rc=$_pf_loops_rc)"
    return 1
  fi

  # Ledger: persist PREPARED record (backing file known, loop device not yet)
  # shellcheck disable=SC2155  # fallback printf guarantees non-empty assignment; return value not checked
  local _pf_ledger_id="loop:$(realpath "$_pf_backing" 2>/dev/null || printf '%s' "$_pf_backing")"
  if [[ -n "$_LEDGER_RUN_DIR" ]]; then
    _cleanup_ledger_prepare "$_pf_ledger_id" "loop" "$_pf_backing" "" "$_pf_label" || {
      warn "cleanup_attach_loop: ledger prepare failed — aborting"
      return 1
    }
  fi

  # Attempt attach
  local _pf_loopdev
  _pf_loopdev="$(losetup --find --show "$@" "$_pf_backing" 2>/dev/null)" || {
    warn "cleanup_attach_loop: losetup failed for $_pf_backing"
    return 1
  }

  # Register for cleanup
  if ! cleanup_track_loop "$_pf_loopdev" "$_pf_backing" "$_pf_label"; then
    warn "cleanup_attach_loop: registration failed — attempting rollback"
    if strict_detach_loop "$_pf_loopdev" 2>/dev/null; then
      debug "cleanup_attach_loop: rollback succeeded"
    else
      # Rollback failed — emergency-register
      warn "cleanup_attach_loop: rollback FAILED — $_pf_loopdev remains attached"
      CLEANUP_INCOMPLETE=1
      local _pf_backing_id=""
      if [[ -f "/sys/block/${_pf_loopdev##*/}/loop/backing_file" ]]; then
        local _pf_bp
        _pf_bp="$(cat "/sys/block/${_pf_loopdev##*/}/loop/backing_file" 2>/dev/null)" || _pf_bp=""
        if [[ -n "$_pf_bp" && -e "$_pf_bp" ]]; then
          _pf_backing_id="$(stat -c '%d:%i' "$_pf_bp" 2>/dev/null)" || _pf_backing_id="$_pf_bp"
        fi
      fi
      CLEANUP_LOOPS+=("$_pf_loopdev")
      CLEANUP_LOOP_BACKINGS+=("$_pf_backing_id")
      CLEANUP_LOOP_LABELS+=("${_pf_label:-$_pf_loopdev}")
    fi
    return 1
  fi

  # Ledger: transition to ACTIVE
  if [[ -n "$_LEDGER_RUN_DIR" ]]; then
    local _pf_loop_identity=""
    if [[ -f "/sys/block/${_pf_loopdev##*/}/loop/backing_file" ]]; then
      local _pf_bp
      _pf_bp="$(cat "/sys/block/${_pf_loopdev##*/}/loop/backing_file" 2>/dev/null)" || _pf_bp=""
      if [[ -n "$_pf_bp" && -e "$_pf_bp" ]]; then
        _pf_loop_identity="$(stat -c '%d:%i' "$_pf_bp" 2>/dev/null)" || _pf_loop_identity=""
      fi
    fi
    _cleanup_ledger_activate "$_pf_ledger_id" "$_pf_loop_identity" || true
  fi

  # Output loop device via nameref
  local -n _pf_result_ref="$_pf_output_var"
  _pf_result_ref="$_pf_loopdev"
  debug "cleanup_attach_loop: attached and registered $_pf_loopdev (backing: $_pf_backing)"
  return 0
}

# cleanup_mount_chroot ROOT
#   Mount standard chroot filesystems (proc, sys, dev, dev/shm).
#   Registers each mount individually for reverse-order teardown.
#   Returns 0 if all mounted, 1 on partial failure.
cleanup_mount_chroot() {
  local root="${1:?cleanup_mount_chroot: missing root}"

  # --- Preconditions ---
  if ((CLEANUP_RUNNING)); then
    warn "cleanup_mount_chroot: cannot create mounts during cleanup"
    return 1
  fi
  if [[ -z "$CLEANUP_WORKSPACE_ROOT" ]]; then
    warn "cleanup_mount_chroot: CLEANUP_WORKSPACE_ROOT not set"
    return 1
  fi
  if ! _cleanup_validate_workspace "$root"; then
    return 1
  fi

  [[ -d "$root" ]] || die "cleanup_mount_chroot: $root is not a directory"

  # Record registration boundary — only roll back what we create
  local boundary=0
  [[ ${CLEANUP_MOUNTS[0]+_} ]] && boundary=${#CLEANUP_MOUNTS[@]}

  # Ensure mount directories exist
  if ! mkdir -p "$root/proc" "$root/sys" "$root/dev" "$root/dev/pts" "$root/dev/shm" 2>/dev/null; then
    warn "cleanup_mount_chroot: could not create mount directories under $root"
    return 1
  fi

  local rc=0

  # proc
  if ! mountpoint -q "$root/proc" 2>/dev/null; then
    if cleanup_mount "$root/proc" "chroot proc" -- -t proc proc; then
      debug "cleanup_mount_chroot: mounted proc"
    else
      warn "cleanup_mount_chroot: failed to mount proc"
      rc=1
    fi
  fi
  ((rc)) && {
    _cleanup_chroot_rollback "$boundary"
    return "$rc"
  }

  # sys — fresh read-only sysfs (avoids stacked mounts from recursive bind).
  # Exposes the host kernel's sysfs objects for inspection, but does not
  # recursively import efivars, debugfs, tracefs, configfs, BPF, or
  # cgroup2 submounts.
  if ! mountpoint -q "$root/sys" 2>/dev/null; then
    if ! cleanup_mount_readonly_sysfs "$root/sys" "chroot sys"; then
      warn "cleanup_mount_chroot: failed to mount sysfs"
      rc=1
    fi
  fi
  ((rc)) && {
    _cleanup_chroot_rollback "$boundary"
    return "$rc"
  }

  # dev — recursive bind; --make-rslave keeps submounts (pts, shm) in sync
  if ! mountpoint -q "$root/dev" 2>/dev/null; then
    if cleanup_mount "$root/dev" "chroot dev" -- --rbind /dev; then
      if ! mount --make-rslave "$root/dev" 2>/dev/null; then
        warn "cleanup_mount_chroot: failed to set propagation on /dev"
        rc=1
      fi
    else
      warn "cleanup_mount_chroot: failed to mount /dev"
      rc=1
    fi
  fi
  ((rc)) && {
    _cleanup_chroot_rollback "$boundary"
    return "$rc"
  }

  # dev/shm — remove inherited bind from rbind, then mount fresh tmpfs
  if mountpoint -q "$root/dev/shm" 2>/dev/null; then
    umount -R "$root/dev/shm" 2>/dev/null || {
      warn "Failed to remove inherited /dev/shm — attempting to continue"
    }
  fi
  if cleanup_mount "$root/dev/shm" "chroot dev/shm" -- -t tmpfs tmpfs -o mode=1777,nosuid,nodev; then
    debug "cleanup_mount_chroot: mounted dev/shm"
  else
    warn "cleanup_mount_chroot: failed to mount dev/shm"
    rc=1
  fi
  ((rc)) && {
    _cleanup_chroot_rollback "$boundary"
    return "$rc"
  }

  return "$rc"
}

# _cleanup_chroot_rollback BOUNDARY
#   Roll back only mounts registered after BOUNDARY.
_cleanup_chroot_rollback() {
  local boundary="${1:?_cleanup_chroot_rollback: missing boundary}"
  local i
  local rc=0

  # Read inventory once for verification
  local inventory=""
  inventory="$(_cleanup_read_mount_inventory 2>/dev/null)" || {
    warn "_cleanup_chroot_rollback: cannot read mount inventory"
    CLEANUP_INCOMPLETE=1
    return 1
  }

  # Unmount in reverse, only from our registration boundary onward
  local _n=0
  [[ ${CLEANUP_MOUNTS[0]+_} ]] && _n=${#CLEANUP_MOUNTS[@]}
  for ((i = _n - 1; i >= boundary; i--)); do
    local m="${CLEANUP_MOUNTS[$i]}"
    local expected_id="${CLEANUP_MOUNT_IDS[$i]:-}"

    # Verify mount is still present in inventory before attempting unmount
    if ! grep -qxF -- "$m" <<<"$inventory" 2>/dev/null; then
      # Already absent — just remove from tracking
      unset 'CLEANUP_MOUNTS[i]'
      unset 'CLEANUP_MOUNT_IDS[i]'
      unset 'CLEANUP_MOUNT_LABELS[i]'
      unset 'CLEANUP_MOUNT_NORMALIZED[i]'
      unset 'CLEANUP_MOUNT_IDENTITIES[i]'
      continue
    fi

    # Mount exists — attempt unmount
    if ! strict_unmount "$m" "chroot rollback" 2>/dev/null; then
      warn "_cleanup_chroot_rollback: could not unmount $m — preserving"
      CLEANUP_INCOMPLETE=1
      rc=1
      continue
    fi

    # Verify unmount succeeded
    local post_inventory=""
    post_inventory="$(_cleanup_read_mount_inventory 2>/dev/null)" || post_inventory=""
    if [[ -n "$post_inventory" ]] && grep -qxF -- "$m" <<<"$post_inventory" 2>/dev/null; then
      warn "_cleanup_chroot_rollback: $m still present after unmount — preserving"
      CLEANUP_INCOMPLETE=1
      rc=1
      continue
    fi

    # Ledger: mark released
    if [[ -n "$_LEDGER_RUN_DIR" ]]; then
      _cleanup_ledger_mark_released "mount:$m" || true
    fi

    # Successfully unmounted — remove from tracking
    unset 'CLEANUP_MOUNTS[i]'
    unset 'CLEANUP_MOUNT_IDS[i]'
    unset 'CLEANUP_MOUNT_LABELS[i]'
    unset 'CLEANUP_MOUNT_NORMALIZED[i]'
    unset 'CLEANUP_MOUNT_IDENTITIES[i]'
  done

  # Re-index arrays
  CLEANUP_MOUNTS=("${CLEANUP_MOUNTS[@]+"${CLEANUP_MOUNTS[@]}"}")
  CLEANUP_MOUNT_IDS=("${CLEANUP_MOUNT_IDS[@]+"${CLEANUP_MOUNT_IDS[@]}"}")
  CLEANUP_MOUNT_LABELS=("${CLEANUP_MOUNT_LABELS[@]+"${CLEANUP_MOUNT_LABELS[@]}"}")
  CLEANUP_MOUNT_NORMALIZED=("${CLEANUP_MOUNT_NORMALIZED[@]+"${CLEANUP_MOUNT_NORMALIZED[@]}"}")
  CLEANUP_MOUNT_IDENTITIES=("${CLEANUP_MOUNT_IDENTITIES[@]+"${CLEANUP_MOUNT_IDENTITIES[@]}"}")

  return "$rc"
}

# _cleanup_stop_workers
#   Stop all background jobs launched by the build.
#   Waits for them to exit. Does NOT kill arbitrary processes.
#   Returns 0 when all workers have exited.
#
#   NOTE: This covers shell-level background jobs (jobs -p).
#   Pipeline members and subprocess trees are NOT guaranteed to be stopped.
#   Callers should ensure build jobs are launched as direct background jobs,
#   not through subprocess pipelines, for reliable shutdown.
_cleanup_stop_workers() {
  local timeout=10
  local waited=0

  # Get list of background job PIDs
  # Note: this covers shell-level background jobs (jobs -p).
  # Pipeline members and subprocess trees are NOT guaranteed to be stopped.
  # Callers should ensure build jobs are launched as direct background jobs,
  # not through subprocess pipelines, for reliable shutdown.
  local -a pids=()
  local job
  local _raw_pids
  _raw_pids=$(jobs -p 2>/dev/null) || true
  if [[ -n "$_raw_pids" ]]; then
    while IFS="" read -r job; do
      local pid="${job%% *}"
      [[ -n "$pid" ]] && pids+=("$pid")
    done <<<"$_raw_pids"
  fi

  local _n=0
  [[ ${pids[0]+_} ]] && _n=${#pids[@]}
  if [[ $_n -eq 0 ]]; then
    debug "_cleanup_stop_workers: no background jobs"
    return 0
  fi

  debug "_cleanup_stop_workers: stopping $_n background job(s)"

  # Send SIGTERM to each
  for pid in "${pids[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done

  # Wait with timeout
  while ((waited < timeout)); do
    local all_done=1
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        all_done=0
        break
      fi
    done
    ((all_done)) && break
    sleep 1
    waited=$((waited + 1))
  done

  # Force-kill any remaining
  for pid in "${pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      warn "_cleanup_stop_workers: force-killing PID $pid"
      kill -KILL "$pid" 2>/dev/null || true
      sleep 0.5
    fi
  done

  # Verify termination
  local survivors=0
  for pid in "${pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      warn "_cleanup_stop_workers: PID $pid still alive after SIGKILL"
      survivors=$((survivors + 1))
    fi
  done

  if ((survivors > 0)); then
    warn "_cleanup_stop_workers: $survivors direct job(s) could not be stopped — descendants may still be running"
    return 1
  fi

  # Reap direct children
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  debug "_cleanup_stop_workers: all direct jobs stopped"
  return 0
}

# cleanup_release MOUNTPOINT
#   Mark a mount as intentionally released (dismantled during build).
#   Removes it from tracking arrays to prevent stale entries.
cleanup_release() {
  local target="${1:?cleanup_release: missing mountpoint}"

  # Cannot release during cleanup
  if ((CLEANUP_RUNNING)); then
    warn "cleanup_release: cannot release during cleanup"
    return 1
  fi

  # Normalize path
  local normalized
  normalized="$(realpath "$target" 2>/dev/null)" || normalized="$target"

  # Read mount inventory — FAIL if we can't verify
  local inventory
  inventory="$(_cleanup_read_mount_inventory 2>/dev/null)" || {
    warn "cleanup_release: cannot read mount inventory — refusing to release $target"
    return 1
  }

  # Verify mount is actually gone
  if grep -qxF -- "$normalized" <<<"$inventory" 2>/dev/null; then
    warn "cleanup_release: $target is still mounted — cannot release"
    return 1
  fi

  # Ledger: mark released
  if [[ -n "$_LEDGER_RUN_DIR" ]]; then
    _cleanup_ledger_mark_released "mount:$normalized" || true
  fi

  # Remove from tracking
  local i
  local _n=0
  [[ ${CLEANUP_MOUNTS[0]+_} ]] && _n=${#CLEANUP_MOUNTS[@]}
  for ((i = _n - 1; i >= 0; i--)); do
    if [[ "${CLEANUP_MOUNTS[$i]}" == "$normalized" || "${CLEANUP_MOUNTS[$i]}" == "$target" ]]; then
      unset 'CLEANUP_MOUNTS[i]'
      unset 'CLEANUP_MOUNT_IDS[i]'
      unset 'CLEANUP_MOUNT_LABELS[i]'
      unset 'CLEANUP_MOUNT_NORMALIZED[i]'
      unset 'CLEANUP_MOUNT_IDENTITIES[i]'
      CLEANUP_MOUNTS=("${CLEANUP_MOUNTS[@]+"${CLEANUP_MOUNTS[@]}"}")
      CLEANUP_MOUNT_IDS=("${CLEANUP_MOUNT_IDS[@]+"${CLEANUP_MOUNT_IDS[@]}"}")
      CLEANUP_MOUNT_LABELS=("${CLEANUP_MOUNT_LABELS[@]+"${CLEANUP_MOUNT_LABELS[@]}"}")
      CLEANUP_MOUNT_NORMALIZED=("${CLEANUP_MOUNT_NORMALIZED[@]+"${CLEANUP_MOUNT_NORMALIZED[@]}"}")
      CLEANUP_MOUNT_IDENTITIES=("${CLEANUP_MOUNT_IDENTITIES[@]+"${CLEANUP_MOUNT_IDENTITIES[@]}"}")
      debug "cleanup_release: released $target from tracking"
      return 0
    fi
  done

  debug "cleanup_release: $target not found in tracking"
  return 0
}

# _cleanup_report_blockers TARGET
#   Report why resources at TARGET could not be cleaned up.
#   Shows remaining mounts, associated loops, and holders.
_cleanup_report_blockers() {
  local target="${1:-}"

  if [[ -n "$target" ]]; then
    warn "_cleanup_report_blockers: diagnostics for $target"
  fi

  # Report remaining mounts — use exact or descendant matching
  local remaining=""
  remaining="$(_cleanup_read_mount_inventory 2>/dev/null)" || {
    warn "_cleanup_report_blockers: cannot read mount inventory"
    remaining=""
  }

  if [[ -n "$remaining" && -n "$target" ]]; then
    local target_normalized
    target_normalized="$(realpath "$target" 2>/dev/null)" || target_normalized="$target"
    target_normalized="${target_normalized%/}"
    local target_with_slash="${target_normalized}/"

    warn "  Remaining mounts:"
    local found=0
    local m
    while IFS="" read -r m; do
      [[ -n "$m" ]] || continue
      local m_normalized
      m_normalized="$(realpath "$m" 2>/dev/null)" || m_normalized="$m"
      m_normalized="${m_normalized%/}"
      # Exact match or proper descendant
      if [[ "$m_normalized" == "$target_normalized" || "$m_normalized" == "${target_with_slash}"* ]]; then
        warn "    $m"
        found=1
      fi
    done <<<"$remaining"
    ((found)) || warn "    (none)"
  elif [[ -n "$remaining" ]]; then
    warn "  All mounts:"
    while IFS="" read -r m; do
      [[ -n "$m" ]] && warn "    $m"
    done <<<"$remaining"
  else
    warn "  Mount inventory: unavailable or empty"
  fi

  # Report active loops — only those associated with workspace
  if [[ -n "$CLEANUP_WORKSPACE_ROOT" ]]; then
    local workspace_loops=""
    local l
    for l in "${CLEANUP_LOOPS[@]+"${CLEANUP_LOOPS[@]}"}"; do
      if losetup "$l" &>/dev/null; then
        local backing_path=""
        if [[ -f "/sys/block/${l##*/}/loop/backing_file" ]]; then
          backing_path="$(cat "/sys/block/${l##*/}/loop/backing_file" 2>/dev/null)" || backing_path=""
        fi
        if [[ -n "$backing_path" && "$backing_path" == "$CLEANUP_WORKSPACE_ROOT"* ]]; then
          workspace_loops+="    $l → $backing_path"$'\n'
        fi
      fi
    done
    if [[ -n "$workspace_loops" ]]; then
      warn "  Workspace loops:"
      printf '%s' "$workspace_loops"
    fi
  fi

  # Report processes using the target (read-only, no killing)
  if [[ -n "$target" ]] && command -v fuser &>/dev/null; then
    local holders
    holders="$(fuser -vm "$target" 2>&1)" || holders=""
    if [[ -n "$holders" ]]; then
      warn "  Processes using $target:"
      while IFS="" read -r h; do
        [[ -n "$h" ]] && warn "    $h"
      done <<<"$holders"
    else
      warn "  No processes found using $target"
    fi
  elif [[ -n "$target" ]]; then
    warn "  fuser not available — cannot identify processes"
  fi

  return 0
}

# ── Pseudo-filesystem mount guard ────────────────────────────────────────────
# Prevents recursive deletion of a chroot root while pseudo-filesystem
# mounts (/dev, /sys, /proc) remain beneath it.  These indicate the tree
# is still an active chroot and must not be torn down.
_assert_no_pseudo_mounts() {
  local root="${1:?_assert_no_pseudo_mounts: missing root path}"
  # Refuse destructive operations while virtual/pseudo-filesystem mounts
  # (/dev, /sys, /proc) remain beneath the given root.  These indicate
  # the tree is still an active chroot and must not be torn down.
  local _pseudo_output _findmnt_rc=0
  _pseudo_output="$(findmnt -rn -R "$root" 2>/dev/null)" || _findmnt_rc=$?
  if [[ $_findmnt_rc -ne 0 ]]; then
    # Exit code 1 = no match (path is not a mountpoint). Safe: no submounts exist.
    # Only die on genuine query failures (32 = bad option, 64 = other error).
    if [[ $_findmnt_rc -eq 1 ]]; then
      return 0
    fi
    die "Refusing destructive cleanup: cannot query mount table for $root"
  fi
  if echo "$_pseudo_output" \
    | awk -v root="$root" '
        { dev = root "/dev"; sys = root "/sys"; proc = root "/proc"; n = length($1) }
        (index($1, dev) == 1 && (n == length(dev) || substr($1, length(dev)+1, 1) == "/")) ||
        (index($1, sys) == 1 && (n == length(sys) || substr($1, length(sys)+1, 1) == "/")) ||
        (index($1, proc) == 1 && (n == length(proc) || substr($1, length(proc)+1, 1) == "/"))
        { found=1 }
        END { exit !found }'; then
    die "Refusing destructive cleanup: virtual filesystems remain mounted under $root"
  fi
}

# ── Safe recursive directory removal ────────────────────────────────────────
# Checks for any mount at or below the target before running rm -rf.
# This prevents traversing into bind mounts and destroying host filesystem
# entries (e.g. /dev device nodes through an overlay).
safe_rmdir() {
  local dir="$1"
  if [[ ! -e "$dir" ]]; then
    return 0
  fi

  # Absolute safety rule: refuse if pseudo-filesystem mounts remain
  _assert_no_pseudo_mounts "$dir"

  # Protection blacklist: refuse to remove protected host paths
  # Exclude paths under the workspace (same pattern as cleanup_recover)
  local _ws_rmdir=0
  if [[ -n "${CLEANUP_WORKSPACE_ROOT:-}" ]]; then
    local _ws_resolved
    _ws_resolved="$(realpath -m -- "$dir" 2>/dev/null)" || _ws_resolved="$dir"
    if [[ "$_ws_resolved" == "${CLEANUP_WORKSPACE_ROOT}" || "$_ws_resolved" == "${CLEANUP_WORKSPACE_ROOT%/}"/* ]]; then
      _ws_rmdir=1
    fi
  fi
  if [[ $_ws_rmdir -eq 0 ]] && protected_path "$dir"; then
    warn "safe_rmdir: refusing to remove protected path: $dir"
    return 1
  fi

  # Check for any mount at or below $dir (covers bind-mounted children).
  local normalized="${dir%/}"
  local mount_targets
  if ! mount_targets="$(findmnt -rno TARGET --kernel 2>/dev/null)"; then
    warn "safe_rmdir: unable to read kernel mount table — skipping removal of $dir"
    return 1
  fi
  local mount_target
  while IFS= read -r mount_target; do
    [[ -z "$mount_target" ]] && continue
    # Exact match or descendant (mount_target is at or below dir)
    if [[ "$mount_target" == "$normalized" || "$mount_target" == "$normalized"/* ]]; then
      warn "$dir has active submounts ($mount_target) — skipping removal"
      return 1
    fi
  done <<<"$mount_targets"

  # Race-condition guard: re-verify no mounts appeared since the scan above.
  local _recheck
  if ! _recheck="$(findmnt -rno TARGET --kernel 2>/dev/null)"; then
    warn "safe_rmdir: cannot re-verify mount table — refusing to remove $dir"
    return 1
  fi
  local _recheck_target
  while IFS= read -r _recheck_target; do
    [[ -z "$_recheck_target" ]] && continue
    if [[ "$_recheck_target" == "$normalized" || "$_recheck_target" == "$normalized"/* ]]; then
      warn "safe_rmdir: mount appeared during cleanup of $dir ($_recheck_target) — aborting"
      return 1
    fi
  done <<<"$_recheck"

  # NOTE: best-effort race guard — a mount can still appear between the
  # re-verification above and the rm -rf below.  Absolute safety would
  # require mount-namespace isolation (unshare --mount).  The double-scan
  # approach is sufficient for single-threaded sequential cleanup.
  rm -rf "$dir"
}

# cleanup_force_teardown WORKSPACE
#   Emergency last-resort cleanup when normal cleanup_environment fails.
#   Kills processes, lazy-unmounts, detaches loops, removes temp dirs.
#   ALWAYS returns 1 — this path means something went wrong.
#   Callers should NOT continue after this succeeds.
cleanup_force_teardown() {
  local workspace="${1:?cleanup_force_teardown: missing workspace}"

  cleanup_log "=== cleanup_force_teardown: start (workspace=$workspace) ==="
  cleanup_log_namespace

  warn "cleanup_force_teardown: emergency teardown of $workspace"

  # Phase 1: Kill any processes still using resources under workspace
  if command -v fuser &>/dev/null; then
    local holders
    holders="$(fuser -vm "$workspace" 2>&1)" || true
    if [[ -n "$holders" ]]; then
      warn "cleanup_force_teardown: killing processes holding $workspace"
      fuser -k -s KILL "$workspace" 2>/dev/null || true
      sleep 1
    fi
  fi

  # Phase 2: Lazy-unmount all tracked mounts
  local i
  local _n=0
  [[ ${CLEANUP_MOUNTS[0]+_} ]] && _n=${#CLEANUP_MOUNTS[@]}
  for ((i = _n - 1; i >= 0; i--)); do
    local m="${CLEANUP_MOUNTS[$i]}"
    # Protection blacklist: skip protected host resources
    if protected_path "$m"; then
      warn "cleanup_force_teardown: skipping protected mount: $m"
      continue
    fi
    # Propagation guard for virtual-fs binds
    if ! _check_bind_propagation "$m"; then
      warn "cleanup_force_teardown: skipping shared virtual-fs bind: $m"
      cleanup_log "FORCE_TEARDOWN SKIP (shared propagation): $m"
      continue
    fi
    if mountpoint -q "$m" 2>/dev/null; then
      warn "cleanup_force_teardown: lazy-unmounting $m (propagation=${_PROPAGATION_TYPE:-n/a})"
      cleanup_log "FORCE_TEARDOWN UNMOUNT $m (propagation=${_PROPAGATION_TYPE:-n/a})"
      umount -Rl "$m" 2>/dev/null || true
    fi
  done

  # Phase 3: Detach all tracked loops
  local _n2=0
  [[ ${CLEANUP_LOOPS[0]+_} ]] && _n2=${#CLEANUP_LOOPS[@]}
  for ((i = _n2 - 1; i >= 0; i--)); do
    local l="${CLEANUP_LOOPS[$i]}"
    if losetup "$l" &>/dev/null; then
      warn "cleanup_force_teardown: detaching loop $l"
      sync 2>/dev/null || true
      losetup -d "$l" 2>/dev/null || true
    fi
  done

  # Phase 4: Remove tracked temp directories
  local _n3=0
  [[ ${CLEANUP_TEMPDIRS[0]+_} ]] && _n3=${#CLEANUP_TEMPDIRS[@]}
  for ((i = _n3 - 1; i >= 0; i--)); do
    local d="${CLEANUP_TEMPDIRS[$i]}"
    if [[ -d "$d" ]]; then
      warn "cleanup_force_teardown: removing $d"
      safe_rmdir "$d" 2>/dev/null || true
    fi
  done

  # Phase 5: Remove workspace itself
  if [[ -d "$workspace" ]]; then
    warn "cleanup_force_teardown: removing workspace $workspace"
    safe_rmdir "$workspace" 2>/dev/null || true
  fi

  # ALWAYS fail — this path means something went wrong
  warn "cleanup_force_teardown: emergency teardown complete — resources may be inconsistent"
  return 1
}

# refresh_loop_size LOOPDEV
#   Refresh a loop device's capacity after the backing file was extended.
#   Calls `losetup -c` to re-read the device size from the kernel.
#   Dies on failure — a stale loop size causes I/O errors at the boundary.
refresh_loop_size() {
  local loopdev="${1:?refresh_loop_size: missing loop device}"

  if ! losetup -c "$loopdev" 2>/dev/null; then
    die "refresh_loop_size: failed to refresh loop device size: $loopdev"
  fi

  debug "refresh_loop_size: refreshed $loopdev capacity"
  return 0
}

# _audit_workspace_strays WORKSPACE
#   Detect untracked resources under the workspace.
#   Compares live kernel state against the CLEANUP_* tracking arrays.
#   Reports any mounts, loops, or ext4 superblocks that exist but weren't registered.
#   Returns 0 if clean, 1 if strays found.
_audit_workspace_strays() {
  local workspace="${1:?_audit_workspace_strays: missing workspace}"
  local rc=0

  local ws_real
  ws_real="$(realpath "$workspace" 2>/dev/null)" || ws_real="$workspace"
  local ws_with_slash="${ws_real%/}/"

  # --- Check 1: Untracked mounts under workspace ---
  local all_mounts
  all_mounts="$(_cleanup_read_mount_inventory 2>/dev/null)" || {
    warn "_audit_workspace_strays: cannot read mount inventory"
    return 1
  }

  # Build set of tracked mounts for comparison
  local tracked_mounts=""
  local i
  local _n=0
  [[ ${CLEANUP_MOUNTS[0]+_} ]] && _n=${#CLEANUP_MOUNTS[@]}
  for ((i = 0; i < _n; i++)); do
    tracked_mounts+="${CLEANUP_MOUNTS[$i]}"$'\n'
  done

  local untracked_mounts=""
  local m
  while IFS="" read -r m; do
    [[ -n "$m" ]] || continue
    local m_real
    m_real="$(realpath "$m" 2>/dev/null)" || m_real="$m"
    m_real="${m_real%/}"
    # Check if this mount is under our workspace
    if [[ "$m_real" == "$ws_real" || "$m_real" == "${ws_with_slash}"* ]]; then
      # Check if it's tracked
      if ! grep -qxF -- "$m" <<<"$tracked_mounts" 2>/dev/null; then
        untracked_mounts+="$m"$'\n'
      fi
    fi
  done <<<"$all_mounts"

  if [[ -n "$untracked_mounts" ]]; then
    warn "_audit_workspace_strays: untracked mounts under workspace:"
    while IFS="" read -r m; do
      [[ -n "$m" ]] && warn "  $m"
    done <<<"$untracked_mounts"
    rc=1
  fi

  # --- Check 2: Untracked loops backed by workspace files ---
  local loop_json
  loop_json="$(losetup -J 2>/dev/null)" || {
    warn "_audit_workspace_strays: cannot read loop inventory"
    return 1
  }

  # Build set of tracked loop backings for comparison
  local tracked_backings=""
  local _n2=0
  [[ ${CLEANUP_LOOPS[0]+_} ]] && _n2=${#CLEANUP_LOOPS[@]}
  for ((i = 0; i < _n2; i++)); do
    tracked_backings+="${CLEANUP_LOOP_BACKINGS[$i]}"$'\n'
  done

  local untracked_loops=""
  # Extract workspace-backed loops from JSON; output: "device\tbacking_file"
  local ws_loops
  ws_loops="$(python3 -c '
import json, sys

ws_real = sys.argv[1]
ws_slash = sys.argv[2]

try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)

for dev in data.get("loopdevices", []):
    name = dev.get("name") or ""
    backing = dev.get("back-file") or ""
    clean = backing.removesuffix(" (deleted)")
    if not name or not clean:
        continue
    if clean == ws_real or clean.startswith(ws_slash):
        print(name + "\t" + clean)
' "$ws_real" "$ws_with_slash" <<<"$loop_json")" || true

  if [[ -n "$ws_loops" ]]; then
    while IFS=$'\t' read -r l_dev l_backing; do
      [[ -n "$l_dev" ]] || continue
      local l_identity=""
      if [[ -e "$l_backing" ]]; then
        l_identity="$(stat -c '%d:%i' "$l_backing" 2>/dev/null)" || l_identity=""
      fi
      if [[ -z "$l_identity" ]] || ! grep -qxF -- "$l_identity" <<<"$tracked_backings" 2>/dev/null; then
        untracked_loops+="  $l_dev ($l_backing)"$'\n'
      fi
    done <<<"$ws_loops"
  fi

  if [[ -n "$untracked_loops" ]]; then
    warn "_audit_workspace_strays: untracked loops backed by workspace files:"
    while IFS="" read -r l; do
      [[ -n "$l" ]] && warn "  $l"
    done <<<"$untracked_loops"
    rc=1
  fi

  # --- Check 3: Ext4 superblocks for workspace loops ---
  local ext4_dir="/sys/fs/ext4"
  if [[ -d "$ext4_dir" ]]; then
    local untracked_ext4=""
    local ext4_entry
    for ext4_entry in "$ext4_dir"/*/; do
      [[ -d "$ext4_entry" ]] || continue
      local ext4_name
      ext4_name="$(basename "$ext4_entry")"
      # Check if this ext4 superblock is for a workspace loop
      # (ext4 sysfs entries are named after the loop device, e.g., loop0)
      if [[ "$ext4_name" == loop* ]]; then
        local ext4_loop="/dev/$ext4_name"
        if [[ -b "$ext4_loop" ]]; then
          # Check if this loop is backed by a workspace file
          local ext4_backing=""
          if [[ -f "/sys/block/${ext4_name}/loop/backing_file" ]]; then
            ext4_backing="$(cat "/sys/block/${ext4_name}/loop/backing_file" 2>/dev/null)" || ext4_backing=""
          fi
          if [[ -n "$ext4_backing" && ("$ext4_backing" == "$ws_real"* || "$ext4_backing" == "${ws_with_slash}"*) ]]; then
            # Check if tracked
            local ext4_id=""
            if [[ -e "$ext4_backing" ]]; then
              ext4_id="$(stat -c '%d:%i' "$ext4_backing" 2>/dev/null)" || ext4_id=""
            fi
            if [[ -z "$ext4_id" ]] || ! grep -qxF -- "$ext4_id" <<<"$tracked_backings" 2>/dev/null; then
              untracked_ext4+="  $ext4_name (backing: $ext4_backing)"$'\n'
            fi
          fi
        fi
      fi
    done

    if [[ -n "$untracked_ext4" ]]; then
      warn "_audit_workspace_strays: untracked ext4 superblocks:"
      printf '%s' "$untracked_ext4"
      rc=1
    fi
  fi

  # --- Summary ---
  if ((rc == 0)); then
    debug "_audit_workspace_strays: no stray resources detected under $workspace"
  else
    warn "_audit_workspace_strays: stray resources detected — manual cleanup may be required"
  fi

  return "$rc"
}

# ── Workspace-level exclusive lock ──────────────────────────────────────────────
# Shared by build, cleanup, and flash operations to prevent concurrent
# operations that could conflict on mounts/loops.

WORKSPACE_LOCK_FD=""
WORKSPACE_LOCK_PATH="/run/lock/steamos-build-workspace.lock"

# workspace_lock_acquire
#   Acquire the workspace-level exclusive lock. Non-blocking.
#   Returns 0 if acquired, 1 if another operation holds it.
# shellcheck disable=SC2120  # callers intentionally pass no args (use default lock path)
workspace_lock_acquire() {
  local lock_path="${1:-$WORKSPACE_LOCK_PATH}"
  mkdir -p "$(dirname "$lock_path")" 2>/dev/null || {
    warn "workspace_lock_acquire: cannot create lock directory"
    return 1
  }
  local fd=10
  # Use eval for fd assignment (bash requirement for variable fds)
  if ! eval "exec ${fd}>\"${lock_path}\"" 2>/dev/null; then
    warn "workspace_lock_acquire: cannot open lock file"
    return 1
  fi
  if ! flock -n "${fd}"; then
    eval "exec ${fd}>&-" 2>/dev/null || true
    warn "workspace_lock_acquire: another build/cleanup/flash is running"
    return 1
  fi
  WORKSPACE_LOCK_FD="$fd"
  WORKSPACE_LOCK_PATH="$lock_path"
  debug "workspace_lock_acquire: acquired lock on $lock_path (fd=$fd)"
  return 0
}

# workspace_lock_release
#   Release the workspace-level exclusive lock.
workspace_lock_release() {
  if [[ -n "${WORKSPACE_LOCK_FD:-}" ]]; then
    eval "exec ${WORKSPACE_LOCK_FD}>&-" 2>/dev/null || true
    debug "workspace_lock_release: released lock (fd=$WORKSPACE_LOCK_FD)"
    WORKSPACE_LOCK_FD=""
  fi
}

# ── Persistent resource ledger ──────────────────────────────────────────────────
# Optional crash-recovery layer. Extends the in-memory CLEANUP_* arrays with
# durable on-disk records so cleanup can resume after process death.

# Ledger state directory (set by cleanup_ledger_begin)
_LEDGER_STATE_ROOT=""
_LEDGER_RUN_ID=""
_LEDGER_RUN_DIR=""
_LEDGER_LOCK_FD=""

# Ledger schema version
_LEDGER_VERSION="1"

# Run states
_LEDGER_STATE_ACTIVE="ACTIVE"
_LEDGER_STATE_RECOVERING="RECOVERING"
_LEDGER_STATE_BLOCKED="BLOCKED"
_LEDGER_STATE_CLEAN="CLEAN"

# Resource states
_LEDGER_RES_PREPARED="PREPARED"
_LEDGER_RES_ACTIVE="ACTIVE"
_LEDGER_RES_RELEASING="RELEASING"
_LEDGER_RES_RELEASED="RELEASED"

# ── Internal ledger helpers ─────────────────────────────────────────────────────

# _ledger_write_file FILEPATH [LINES...]
#   Write content to a file atomically (write tmp, rename).
_ledger_write_file() {
  local filepath="${1:?_ledger_write_file: missing filepath}"
  shift

  local dir
  dir="$(dirname "$filepath")"
  local tmp="${filepath}.tmp.$$"

  # Write all lines
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >>"$tmp"
  done || {
    rm -f "$tmp"
    return 1
  }

  # Flush
  sync "$tmp" 2>/dev/null || true

  # Atomic replace
  if ! mv -- "$tmp" "$filepath" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi

  # Flush directory
  sync "$dir" 2>/dev/null || true

  return 0
}

# _ledger_append_resource ENTRY
#   Append a resource entry to the resources file.
_ledger_append_resource() {
  local entry="${1:?_ledger_append_resource: missing entry}"

  [[ -n "$_LEDGER_RUN_DIR" ]] || return 1

  printf '%s\n' "$entry" >>"$_LEDGER_RUN_DIR/resources" || return 1
  sync "$_LEDGER_RUN_DIR/resources" 2>/dev/null || true
  return 0
}

# _ledger_update_resource RESOURCE_ID NEW_STATE [ACTUAL_IDENTITY]
#   Update a resource record's state and identity.
_ledger_update_resource() {
  local res_id="${1:?_ledger_update_resource: missing resource id}"
  local new_state="${2:?_ledger_update_resource: missing state}"
  local actual_id="${3:-}"

  [[ -n "$_LEDGER_RUN_DIR" ]] || return 1
  [[ -f "$_LEDGER_RUN_DIR/resources" ]] || return 1

  local tmp="${_LEDGER_RUN_DIR}/resources.tmp.$$"
  : >"$tmp"

  local found=0
  while IFS=$'\t' read -r rid rtype rstate locator_b64 identity_b64 label_b64 last_err timestamp; do
    if [[ "$rid" == "$res_id" ]]; then
      found=1
      # Update state and identity
      if [[ -n "$actual_id" ]]; then
        identity_b64="$(printf '%s' "$actual_id" | base64 -w0)"
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$rid" "$rtype" "$new_state" "$locator_b64" "$identity_b64" "$label_b64" "$last_err" "$(date -Iseconds)" \
        >>"$tmp"
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$rid" "$rtype" "$rstate" "$locator_b64" "$identity_b64" "$label_b64" "$last_err" "$timestamp" \
        >>"$tmp"
    fi
  done <"$_LEDGER_RUN_DIR/resources"

  if ((!found)); then
    warn "_ledger_update_resource: resource $res_id not found"
    rm -f "$tmp"
    return 1
  fi

  sync "$tmp" 2>/dev/null || true
  mv -- "$tmp" "$_LEDGER_RUN_DIR/resources" 2>/dev/null || {
    rm -f "$tmp"
    return 1
  }
  sync "$_LEDGER_RUN_DIR" 2>/dev/null || true
  return 0
}

# _ledger_update_resource_error RESOURCE_ID NEW_STATE ERROR_REASON
#   Update a resource record's state and populate the last_err field.
_ledger_update_resource_error() {
  local res_id="${1:?_ledger_update_resource_error: missing resource id}"
  local new_state="${2:?_ledger_update_resource_error: missing state}"
  local error_reason="${3:?_ledger_update_resource_error: missing error reason}"

  [[ -n "$_LEDGER_RUN_DIR" ]] || return 1
  [[ -f "$_LEDGER_RUN_DIR/resources" ]] || return 1

  local tmp="${_LEDGER_RUN_DIR}/resources.tmp.$$"
  : >"$tmp"

  local found=0
  while IFS=$'\t' read -r rid rtype rstate locator_b64 identity_b64 label_b64 last_err timestamp; do
    if [[ "$rid" == "$res_id" ]]; then
      found=1
      local err_b64
      err_b64="$(printf '%s' "$error_reason" | base64 -w0)"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$rid" "$rtype" "$new_state" "$locator_b64" "$identity_b64" "$label_b64" "$err_b64" "$(date -Iseconds)" \
        >>"$tmp"
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$rid" "$rtype" "$rstate" "$locator_b64" "$identity_b64" "$label_b64" "$last_err" "$timestamp" \
        >>"$tmp"
    fi
  done <"$_LEDGER_RUN_DIR/resources"

  if ((!found)); then
    warn "_ledger_update_resource_error: resource $res_id not found"
    rm -f "$tmp"
    return 1
  fi

  sync "$tmp" 2>/dev/null || true
  mv -- "$tmp" "$_LEDGER_RUN_DIR/resources" 2>/dev/null || {
    rm -f "$tmp"
    return 1
  }
  sync "$_LEDGER_RUN_DIR" 2>/dev/null || true
  return 0
}

# _ledger_update_manifest KEY VALUE
#   Update a field in the manifest file.
_ledger_update_manifest() {
  local key="${1:?_ledger_update_manifest: missing key}"
  local value="${2:?_ledger_update_manifest: missing value}"

  [[ -n "$_LEDGER_RUN_DIR" ]] || return 1
  _ledger_update_manifest_in "$_LEDGER_RUN_DIR/manifest" "$key" "$value"
}

# _ledger_update_manifest_in FILE KEY VALUE
#   Update a field in a specific manifest file.
_ledger_update_manifest_in() {
  local filepath="${1:?_ledger_update_manifest_in: missing filepath}"
  local key="${2:?_ledger_update_manifest_in: missing key}"
  local value="${3:?_ledger_update_manifest_in: missing value}"

  [[ -f "$filepath" ]] || return 1

  local tmp="${filepath}.tmp.$$"
  local found=0

  while IFS=$'\t' read -r k v; do
    if [[ "$k" == "$key" ]]; then
      printf '%s\t%s\n' "$key" "$value" >>"$tmp"
      found=1
    else
      printf '%s\t%s\n' "$k" "$v" >>"$tmp"
    fi
  done <"$filepath"

  if ((!found)); then
    printf '%s\t%s\n' "$key" "$value" >>"$tmp"
  fi

  sync "$tmp" 2>/dev/null || true
  mv -- "$tmp" "$filepath" 2>/dev/null || {
    rm -f "$tmp"
    return 1
  }
  sync "$(dirname "$filepath")" 2>/dev/null || true
  return 0
}

# ── Public ledger API ──────────────────────────────────────────────────────────

# cleanup_ledger_begin STATE_ROOT WORKSPACE
#   Initialize a persistent resource ledger for a new run.
#   Creates state directory, acquires lock, writes initial manifest.
cleanup_ledger_begin() {
  local state_root="${1:?cleanup_ledger_begin: missing state root}"
  local workspace="${2:?cleanup_ledger_begin: missing workspace path}"

  # Validate workspace
  local ws_real
  ws_real="$(realpath "$workspace" 2>/dev/null)" || {
    warn "cleanup_ledger_begin: cannot resolve workspace: $workspace"
    return 1
  }

  # Generate run ID (timestamp + random)
  local run_id
  run_id="$(date +%s)-$$-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"

  # Create state directory
  local run_dir="$state_root/runs/$run_id"
  if ! mkdir -p "$run_dir" 2>/dev/null; then
    warn "cleanup_ledger_begin: could not create $run_dir"
    return 1
  fi

  # Restrict permissions
  chmod 700 "$run_dir" 2>/dev/null || true

  # Acquire workspace lock
  local lock_fd=9
  eval "exec ${lock_fd}>\"$run_dir/.lock\""
  if ! flock -n "${lock_fd}"; then
    warn "cleanup_ledger_begin: workspace is in use by another process"
    rmdir "$run_dir" 2>/dev/null || true
    return 1
  fi

  # Write manifest
  local boot_id
  boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" || boot_id="unknown"

  local ns_id
  ns_id="$(readlink /proc/self/ns/mnt 2>/dev/null)" || ns_id="unknown"

  local ws_identity
  ws_identity="$(stat -c '%d:%i' "$ws_real" 2>/dev/null)" || ws_identity=""

  if ! _ledger_write_file "$run_dir/manifest" \
    "schema_version	$_LEDGER_VERSION" \
    "run_id	$run_id" \
    "boot_id	$boot_id" \
    "mount_namespace	$ns_id" \
    "process_id	$$" \
    "process_start_time	$(awk '{print $22}' /proc/$$ 2>/dev/null || echo 0)" \
    "workspace_path	$(printf '%s' "$ws_real" | base64 -w0)" \
    "workspace_identity	$ws_identity" \
    "run_state	$_LEDGER_STATE_ACTIVE" \
    "created	$(date -Iseconds)"; then
    warn "cleanup_ledger_begin: failed to write manifest"
    exec {lock_fd}>&- 2>/dev/null || true
    return 1
  fi

  # Initialize empty resources file
  _ledger_write_file "$run_dir/resources"

  # Set global state
  _LEDGER_STATE_ROOT="$state_root"
  _LEDGER_RUN_ID="$run_id"
  _LEDGER_RUN_DIR="$run_dir"
  _LEDGER_LOCK_FD="$lock_fd"

  debug "cleanup_ledger_begin: initialized ledger at $run_dir (run=$run_id)"
  return 0
}

# _cleanup_ledger_prepare RESOURCE_ID TYPE LOCATOR [EXPECTED_IDENTITY] [LABEL]
#   Persist a PREPARED record before resource creation.
_cleanup_ledger_prepare() {
  local res_id="${1:?_cleanup_ledger_prepare: missing resource id}"
  local res_type="${2:?_cleanup_ledger_prepare: missing type (mount|loop)}"
  local locator="${3:?_cleanup_ledger_prepare: missing locator}"
  local expected_id="${4:-}"
  local label="${5:-}"

  [[ -n "$_LEDGER_RUN_DIR" ]] || {
    warn "_cleanup_ledger_prepare: no active ledger"
    return 1
  }

  local entry
  entry="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$res_id" \
    "$res_type" \
    "$_LEDGER_RES_PREPARED" \
    "$(printf '%s' "$locator" | base64 -w0)" \
    "$(printf '%s' "$expected_id" | base64 -w0)" \
    "$(printf '%s' "$label" | base64 -w0)" \
    "" \
    "$(date -Iseconds)")"

  if ! _ledger_append_resource "$entry"; then
    warn "_cleanup_ledger_prepare: failed to persist PREPARED record for $res_id"
    return 1
  fi

  debug "_cleanup_ledger_prepare: persisted PREPARED $res_type $res_id"
  return 0
}

# _cleanup_ledger_activate RESOURCE_ID [ACTUAL_IDENTITY]
#   Transition a resource from PREPARED to ACTIVE after successful creation.
_cleanup_ledger_activate() {
  local res_id="${1:?_cleanup_ledger_activate: missing resource id}"
  local actual_id="${2:-}"

  [[ -n "$_LEDGER_RUN_DIR" ]] || return 1

  _ledger_update_resource "$res_id" "$_LEDGER_RES_ACTIVE" "$actual_id"
}

# _cleanup_ledger_mark_releasing RESOURCE_ID
_cleanup_ledger_mark_releasing() {
  local res_id="${1:?_cleanup_ledger_mark_releasing: missing resource id}"

  [[ -n "$_LEDGER_RUN_DIR" ]] || return 1

  _ledger_update_resource "$res_id" "$_LEDGER_RES_RELEASING" ""
}

# _cleanup_ledger_mark_released RESOURCE_ID
_cleanup_ledger_mark_released() {
  local res_id="${1:?_cleanup_ledger_mark_released: missing resource id}"

  [[ -n "$_LEDGER_RUN_DIR" ]] || return 1

  _ledger_update_resource "$res_id" "$_LEDGER_RES_RELEASED" ""
}

# cleanup_ledger_finish
#   Mark the current run as CLEAN and release the lock.
cleanup_ledger_finish() {
  [[ -n "$_LEDGER_RUN_DIR" ]] || return 0

  # Update manifest state
  _ledger_update_manifest "run_state" "$_LEDGER_STATE_CLEAN"

  # Release lock
  if [[ -n "$_LEDGER_LOCK_FD" ]]; then
    eval "exec ${_LEDGER_LOCK_FD}>&-" 2>/dev/null || true
  fi

  debug "cleanup_ledger_finish: run $_LEDGER_RUN_ID marked CLEAN"
  _LEDGER_RUN_DIR=""
  _LEDGER_RUN_ID=""
  _LEDGER_LOCK_FD=""
  return 0
}

# _cleanup_ledger_read_pid MANIFEST_FILE
#   Read the process_id from a ledger manifest.
#   Returns the PID on success, empty string if not found.
_cleanup_ledger_read_pid() {
  local manifest="${1:?_cleanup_ledger_read_pid: missing manifest}"
  [[ -f "$manifest" ]] || return 1
  grep -m1 '^process_id' "$manifest" | cut -f2
}

# _cleanup_ledger_read_start_time MANIFEST_FILE
#   Read the process_start_time from a ledger manifest.
_cleanup_ledger_read_start_time() {
  local manifest="${1:?_cleanup_ledger_read_start_time: missing manifest}"
  [[ -f "$manifest" ]] || return 1
  grep -m1 '^process_start_time' "$manifest" | cut -f2
}

# cleanup_ledger_pid_alive MANIFEST_FILE
#   Check if the build process recorded in the ledger is still alive.
#   Returns 0 if alive, 1 if dead or unverifiable.
cleanup_ledger_pid_alive() {
  local manifest="${1:?cleanup_ledger_pid_alive: missing manifest}"
  local pid start_time
  pid="$(_cleanup_ledger_read_pid "$manifest")" || return 1
  [[ -n "$pid" ]] || return 1

  # Check PID is alive
  kill -0 "$pid" 2>/dev/null || return 1

  # Verify start time to guard against PID reuse
  start_time="$(grep -m1 '^process_start_time' "$manifest" | cut -f2)"
  if [[ -n "$start_time" && "$start_time" != "0" ]]; then
    local current_start
    current_start="$(awk '{print $22}' "/proc/$pid" 2>/dev/null)" || return 1
    if [[ "$current_start" != "$start_time" ]]; then
      debug "cleanup_ledger_pid_alive: PID $pid reused (start time mismatch: expected=$start_time actual=$current_start)"
      return 1
    fi
  fi

  return 0
}

# cleanup_enter_build_namespace MANIFEST
#   Attempt to enter the build's mount namespace via nsenter and perform
#   cleanup operations inside it.
#   Returns 0 if cleanup inside the namespace succeeded.
#   Returns 1 if nsenter was not possible or cleanup failed.
cleanup_enter_build_namespace() {
  local manifest="${1:?cleanup_enter_build_namespace: missing manifest}"
  local run_dir
  run_dir="$(dirname "$manifest")"

  # Check if build process is alive
  if ! cleanup_ledger_pid_alive "$manifest"; then
    debug "cleanup_enter_build_namespace: build process not running — cannot enter namespace"
    return 1
  fi

  local pid
  pid="$(_cleanup_ledger_read_pid "$manifest")" || return 1
  [[ -n "$pid" ]] || return 1

  # Verify nsenter is available
  if ! command -v nsenter >/dev/null 2>&1; then
    warn "cleanup_enter_build_namespace: nsenter not available"
    return 1
  fi

  # Verify the PID's mount namespace is accessible
  if [[ ! -e "/proc/$pid/ns/mnt" ]]; then
    warn "cleanup_enter_build_namespace: cannot access /proc/$pid/ns/mnt"
    return 1
  fi

  cleanup_log "ENTER_NAMESPACE pid=$pid manifest=$manifest"
  warn "cleanup_enter_build_namespace: entering build namespace pid=$pid"

  # Enter the build's mount namespace and run recovery.
  # cleanup_recover reads the manifest and handles all state reconstruction.
  # CLEANUP_NAMESPACE_OVERRIDE lets cleanup_recover skip the PID-alive guard,
  # since we're explicitly entering the live build's namespace for cleanup.
  nsenter --target "$pid" --mount -- \
    env CLEANUP_NAMESPACE_OVERRIDE=1 \
    bash -c '
      source "'"$BACKEND_DIR"'/common.sh" # lint-ignore: single-source
      source "'"$BACKEND_DIR"'/protected.sh" # lint-ignore: single-source
      source "'"$BACKEND_DIR"'/mounts.sh" # lint-ignore: single-source
      cleanup_recover "'"$run_dir"'"
    ' 2>&1 | while IFS= read -r _line; do
    cleanup_log "NSENTER: $_line"
  done
  local _ns_rc=${PIPESTATUS[0]:-$?}

  if ((_ns_rc != 0)); then
    warn "cleanup_enter_build_namespace: nsenter cleanup failed (rc=$_ns_rc)"
    cleanup_log "NSENTER FAILED pid=$pid rc=$_ns_rc"
    return 1
  fi

  cleanup_log "NSENTER OK pid=$pid"
  return 0
}

# cleanup_recover RUN_DIRECTORY
#   Attempt recovery of an incomplete run.
#   Validates ledger, reconciles resources, runs verified teardown.
cleanup_recover() {
  local run_dir="${1:?cleanup_recover: missing run directory}"

  cleanup_log "=== cleanup_recover: start (run_dir=$run_dir) ==="
  cleanup_log_namespace

  log "cleanup_recover: entering (run_dir=$run_dir)"

  [[ -d "$run_dir" ]] || {
    warn "cleanup_recover: $run_dir does not exist"
    log "cleanup_recover: returning 1 (released=0 preserved=0)"
    return 1
  }
  log "cleanup_recover: run dir check done"

  # Read manifest
  local manifest="$run_dir/manifest"
  [[ -f "$manifest" ]] || {
    warn "cleanup_recover: no manifest in $run_dir"
    log "cleanup_recover: returning 1 (released=0 preserved=0)"
    return 1
  }
  log "cleanup_recover: manifest check done"

  # ── Lock probe: check if the original build process is still alive ──────
  # If the build PID is still running, refuse to clean up — the build owns
  # the workspace and cleanup must not interfere.
  # CLEANUP_NAMESPACE_OVERRIDE=1 skips this check when we've explicitly
  # entered the live build's mount namespace via nsenter for cleanup.
  if cleanup_ledger_pid_alive "$manifest"; then
    if ((CLEANUP_NAMESPACE_OVERRIDE)); then
      debug "cleanup_recover: build PID alive but namespace override active — proceeding"
    else
      local _live_pid
      _live_pid="$(_cleanup_ledger_read_pid "$manifest")"
      warn "cleanup_recover: build process $_live_pid is still alive — skipping recovery"
      cleanup_log "RECOVER SKIP (build alive): pid=$_live_pid run_dir=$run_dir"
      _ledger_update_manifest_in "$manifest" "run_state" "$_LEDGER_STATE_RECOVERING"
      return 1
    fi
  fi
  debug "cleanup_recover: build process not running — proceeding with recovery"

  local boot_id workspace_path
  boot_id="$(grep -m1 '^boot_id' "$manifest" | cut -f2)" || boot_id=""
  workspace_path="$(grep -m1 '^workspace_path' "$manifest" | cut -f2)" || workspace_path=""

  # Decode workspace path
  workspace_path="$(printf '%s' "$workspace_path" | base64 -d 2>/dev/null)" || workspace_path=""
  log "cleanup_recover: manifest read done (boot_id=$boot_id workspace=$workspace_path)"

  # Determine recovery type
  local current_boot_id
  current_boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" || current_boot_id=""

  if [[ "$boot_id" == "$current_boot_id" ]]; then
    debug "cleanup_recover: same-boot recovery"
  else
    debug "cleanup_recover: post-reboot recovery (old boot=$boot_id, current=$current_boot_id)"
    # After reboot, mount IDs, PIDs, loop numbers are stale
    # Only workspace files are reliable
  fi

  # Validate workspace still exists and matches
  if [[ -n "$workspace_path" && -d "$workspace_path" ]]; then
    local ws_identity
    ws_identity="$(stat -c '%d:%i' "$workspace_path" 2>/dev/null)" || ws_identity=""
    local recorded_ws_id
    recorded_ws_id="$(grep -m1 '^workspace_identity' "$manifest" | cut -f2)" || recorded_ws_id=""

    if [[ -n "$recorded_ws_id" && "$ws_identity" != "$recorded_ws_id" ]]; then
      warn "cleanup_recover: workspace identity mismatch — directory may belong to another run"
      log "cleanup_recover: returning 1 (released=0 preserved=0)"
      return 1
    fi
  fi
  log "cleanup_recover: workspace validation done"

  # Set the workspace root so downstream functions (strict_unmount, etc.)
  # can distinguish workspace paths from protected host paths.
  if [[ -n "$workspace_path" ]]; then
    CLEANUP_WORKSPACE_ROOT="$workspace_path"
  fi

  # Read resource records
  local resources_file="$run_dir/resources"
  if [[ ! -f "$resources_file" ]]; then
    debug "cleanup_recover: no resources to recover"
    if ! _ledger_update_manifest_in "$manifest" "run_state" "$_LEDGER_STATE_CLEAN"; then
      warn "cleanup_recover: failed to persist CLEAN state to manifest (no-resources path)"
      log "cleanup_recover: returning 1 (released=0 preserved=0)"
      return 1
    fi
    log "cleanup_recover: returning 0 (released=0 preserved=0)"
    return 0
  fi

  # Set _LEDGER_RUN_DIR so helper functions can update the resources file
  local _prev_ledger_run_dir="${_LEDGER_RUN_DIR:-}"
  _LEDGER_RUN_DIR="$run_dir"

  # Get current mount and loop inventories
  log "cleanup_recover: reading mount inventory"
  local current_mounts
  current_mounts="$(_cleanup_read_mount_inventory 2>/dev/null)" || {
    warn "cleanup_recover: failed to read mount inventory — preserving all resources"
    # Mark all resources as preserved
    return 1
  }
  log "cleanup_recover: mount inventory done"

  local released=0 preserved=0

  # Process each resource record
  log "cleanup_recover: starting resource loop"
  while IFS=$'\t' read -r res_id res_type _res_state locator_b64 identity_b64 _label_b64 _last_err _timestamp; do
    [[ -n "$res_id" ]] || continue

    # Skip resources already in a terminal state — nothing to recover
    if [[ "$_res_state" == "$_LEDGER_RES_RELEASED" ]]; then
      debug "cleanup_recover: $res_id already RELEASED — skipping"
      continue
    fi

    local locator
    locator="$(printf '%s' "$locator_b64" | base64 -d 2>/dev/null)" || locator=""
    local expected_id
    expected_id="$(printf '%s' "$identity_b64" | base64 -d 2>/dev/null)" || expected_id=""

    # Protection blacklist: refuse to recover protected host resources
    # Exclude paths under the workspace (e.g. /dev/shm/steamos-build) from protected-path check
    # Check both the manifest workspace path AND the current workspace root
    local _in_workspace=0
    if [[ -n "$workspace_path" && "$locator" == "$workspace_path"/* ]]; then
      _in_workspace=1
    fi
    if [[ -n "${CLEANUP_WORKSPACE_ROOT:-}" && "$locator" == "${CLEANUP_WORKSPACE_ROOT}"/* ]]; then
      _in_workspace=1
    fi
    # Also check /dev/shm/steamos-build as a fallback workspace path
    if [[ "$locator" == /dev/shm/steamos-build || "$locator" == /dev/shm/steamos-build/* ]]; then
      _in_workspace=1
    fi
    if [[ -n "$locator" ]] && [[ $_in_workspace -eq 0 ]] && protected_path "$locator"; then
      warn "cleanup_recover: protected mount path — preserving: $locator"
      _ledger_update_resource_error "$res_id" "$_LEDGER_RES_ACTIVE" "protected mount path" || true
      preserved=$((preserved + 1))
      continue
    fi

    case "$res_type" in
      mount)
        # Check if mount still exists
        if [[ -n "$locator" ]] && grep -qxF -- "$locator" <<<"$current_mounts" 2>/dev/null; then
          # Mount exists — check identity if same boot
          if [[ "$boot_id" == "$current_boot_id" && -n "$expected_id" ]]; then
            # Detect legacy identity (numeric-only mount ID) vs composite (id:source:fstype:options)
            if [[ "$expected_id" == *:* ]]; then
              # Composite identity — parse and compare all components
              local _e_id _e_src _e_fstype _e_opts
              _e_id="$(echo "$expected_id" | cut -d: -f1)"
              _e_src="$(echo "$expected_id" | cut -d: -f2)"
              _e_fstype="$(echo "$expected_id" | cut -d: -f3)"
              _e_opts="$(echo "$expected_id" | cut -d: -f4-)"

              # Capture current full identity
              local _current_identity
              _current_identity="$(_cleanup_capture_mount_identity "$locator" 2>/dev/null)" || _current_identity=""

              if [[ -n "$_current_identity" ]]; then
                local _c_id _c_src _c_fstype _c_opts
                _c_id="$(echo "$_current_identity" | cut -d: -f1)"
                _c_src="$(echo "$_current_identity" | cut -d: -f2)"
                _c_fstype="$(echo "$_current_identity" | cut -d: -f3)"
                _c_opts="$(echo "$_current_identity" | cut -d: -f4-)"

                # Source or fstype change = different mount → BLOCKED
                if [[ "$_c_src" != "$_e_src" || "$_c_fstype" != "$_e_fstype" ]]; then
                  warn "cleanup_recover: mount identity mismatch at $locator"
                  warn "  expected: source=$_e_src fstype=$_e_fstype"
                  warn "  current:  source=$_c_src fstype=$_c_fstype"
                  _ledger_update_resource_error "$res_id" "$_LEDGER_RES_ACTIVE" "identity mismatch: source=$_e_src→$_c_src fstype=$_e_fstype→$_c_fstype" || true
                  preserved=$((preserved + 1))
                  continue
                fi
                # Mount ID change with matching source+fstype → WARNING but proceed
                if [[ "$_c_id" != "$_e_id" ]]; then
                  warn "cleanup_recover: mount ID changed ($_e_id → $_c_id) at $locator (source/fstype match)"
                fi
                # Options drift — warn and log but don't refuse
                if [[ "$_c_opts" != "$_e_opts" ]]; then
                  warn "cleanup_recover: options changed at $locator ($_e_opts → $_c_opts)"
                  _ledger_update_resource_error "$res_id" "$_LEDGER_RES_ACTIVE" "options changed: $_e_opts→$_c_opts" || true
                fi
              else
                # Cannot capture current identity for composite stored identity — fail-closed
                warn "cleanup_recover: cannot verify mount identity at $locator — preserving"
                _ledger_update_resource_error "$res_id" "$_LEDGER_RES_ACTIVE" "identity_unverifiable" || true
                preserved=$((preserved + 1))
                continue
              fi
            else
              # Legacy identity (numeric-only mount ID) — use ID-only comparison
              local _current_id_only
              _current_id_only="$(findmnt -rno ID -M "$locator" --kernel 2>/dev/null | head -1)" || _current_id_only=""
              if [[ "$expected_id" != "$_current_id_only" ]]; then
                warn "cleanup_recover: mount identity changed at $locator ($expected_id → $_current_id_only)"
                _ledger_update_resource_error "$res_id" "$_LEDGER_RES_ACTIVE" "identity changed: expected=$expected_id current=$_current_id_only" || true
                preserved=$((preserved + 1))
                continue
              fi
            fi
          fi
          # Eligible for cleanup
          debug "cleanup_recover: releasing mount $locator"
          if strict_unmount "$locator" "recovery"; then
            _cleanup_ledger_mark_released "$res_id" || true
            released=$((released + 1))
          else
            warn "cleanup_recover: could not unmount $locator — preserving"
            _ledger_update_resource_error "$res_id" "$_LEDGER_RES_ACTIVE" "unmount failed" || true
            preserved=$((preserved + 1))
          fi
        else
          # Mount absent — already cleaned
          _cleanup_ledger_mark_released "$res_id" || true
          released=$((released + 1))
        fi
        ;;
      loop)
        # Check if loop still exists
        if [[ -n "$locator" ]] && losetup "$locator" &>/dev/null; then
          # Loop exists — check backing identity if same boot
          if [[ "$boot_id" == "$current_boot_id" && -n "$expected_id" ]]; then
            local current_backing=""
            if [[ -f "/sys/block/${locator##*/}/loop/backing_file" ]]; then
              current_backing="$(cat "/sys/block/${locator##*/}/loop/backing_file" 2>/dev/null)" || current_backing=""
              if [[ -n "$current_backing" && -e "$current_backing" ]]; then
                current_backing="$(stat -c '%d:%i' "$current_backing" 2>/dev/null)" || current_backing=""
              fi
            fi
            if [[ "$current_backing" != "$expected_id" ]]; then
              warn "cleanup_recover: $locator backing changed — preserving"
              _ledger_update_resource_error "$res_id" "$_LEDGER_RES_ACTIVE" "backing changed: expected=$expected_id current=$current_backing" || true
              preserved=$((preserved + 1))
              continue
            fi
          fi
          # Eligible for cleanup
          debug "cleanup_recover: detaching loop $locator"
          if strict_detach_loop "$locator"; then
            _cleanup_ledger_mark_released "$res_id" || true
            released=$((released + 1))
          else
            warn "cleanup_recover: could not detach $locator — preserving"
            _ledger_update_resource_error "$res_id" "$_LEDGER_RES_ACTIVE" "detach failed" || true
            preserved=$((preserved + 1))
          fi
        else
          # Loop absent — already cleaned
          _cleanup_ledger_mark_released "$res_id" || true
          released=$((released + 1))
        fi
        ;;
    esac
  done <"$resources_file"

  # Restore previous _LEDGER_RUN_DIR
  _LEDGER_RUN_DIR="$_prev_ledger_run_dir"

  # Report result
  log "cleanup_recover: released=$released preserved=$preserved"

  if ((preserved > 0)); then
    warn "cleanup_recover: $preserved resource(s) could not be released — ledger retained"
    _ledger_update_manifest_in "$manifest" "run_state" "$_LEDGER_STATE_BLOCKED"
    log "cleanup_recover: returning 1 (released=$released preserved=$preserved)"
    return 1
  fi

  if ! _ledger_update_manifest_in "$manifest" "run_state" "$_LEDGER_STATE_CLEAN"; then
    warn "cleanup_recover: failed to persist CLEAN state to manifest"
    log "cleanup_recover: returning 1 (released=$released preserved=$preserved)"
    return 1
  fi
  debug "cleanup_recover: recovery complete"
  log "cleanup_recover: returning 0 (released=$released preserved=$preserved)"
  return 0
}

# cleanup_report_run_state RUN_DIR
#   Read-only: report a run's state and resource summary.
#   Returns 0 always (best-effort; never fails).
cleanup_report_run_state() {
  local run_dir="${1:?cleanup_report_run_state: missing run_dir}"
  local manifest="$run_dir/manifest"
  local resources_file="$run_dir/resources"
  local rid run_state created boot_id ws_path

  rid="$(basename "$run_dir")"

  # Read manifest fields (best-effort; tolerate missing/corrupt manifests)
  [[ -f "$manifest" ]] || {
    warn "  Run $rid: no manifest file"
    return 0
  }

  run_state="$(grep -m1 '^run_state' "$manifest" 2>/dev/null | cut -f2)" || run_state="unknown"
  created="$(grep -m1 '^created' "$manifest" 2>/dev/null | cut -f2)" || created="unknown"
  boot_id="$(grep -m1 '^boot_id' "$manifest" 2>/dev/null | cut -f2)" || boot_id=""
  ws_path="$(grep -m1 '^workspace_path' "$manifest" 2>/dev/null | cut -f2)" || ws_path=""
  [[ -n "$ws_path" ]] && ws_path="$(printf '%s' "$ws_path" | base64 -d 2>/dev/null)" || ws_path=""

  # Count resources
  local total=0 active_res=0 released=0
  if [[ -f "$resources_file" ]]; then
    while IFS=$'\t' read -r res_id res_type res_state _locator _identity _label _err _ts; do
      ((++total)) || true
      case "$res_state" in
        ACTIVE | RELEASING) ((++active_res)) || true ;;
        RELEASED) ((++released)) || true ;;
      esac
    done <"$resources_file" || warn "  Run $rid: could not read resources file"
  fi

  log_debug cleanup report-run "  Run $rid"
  log_debug cleanup report-run "    state:      $run_state"
  log_debug cleanup report-run "    created:    $created"
  [[ -n "$boot_id" ]] && log_debug cleanup report-run "    boot_id:    ${boot_id:0:12}..."
  [[ -n "$ws_path" ]] && log_debug cleanup report-run "    workspace:  $ws_path"
  log_debug cleanup report-run "    resources:  $total total ($active_res active, $released released)"
}
