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

# Unmount an exact mount hierarchy. Never lazy-unmount persistent storage.
strict_unmount() {
  local target="${1:?strict_unmount: missing target}"
  local label="${2:-mount}"

  mountpoint -q "$target" 2>/dev/null || return 0

  log "  Unmounting $label: $target"

  if ! umount -R "$target" 2>/dev/null; then
    warn "Could not cleanly unmount $label: $target"

    findmnt -R "$target" >&2 2>/dev/null || true
    fuser -vm "$target" >&2 2>/dev/null || true

    return 1
  fi

  if mountpoint -q "$target" 2>/dev/null; then
    warn "$label is still mounted after umount: $target"
    findmnt -R "$target" >&2 2>/dev/null || true
    return 1
  fi

  return 0
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

# Detach a loop device and verify it really disappeared.
strict_detach_loop() {
  local loop="${1:?strict_detach_loop: missing loop device}"

  losetup "$loop" >/dev/null 2>&1 || return 0

  sync
  blockdev --flushbufs "$loop" 2>/dev/null || true

  log "  Detaching loop device: $loop"

  if ! losetup -d "$loop" 2>/dev/null; then
    warn "losetup -d failed for $loop"
    losetup "$loop" >&2 2>/dev/null || true
    return 1
  fi

  udevadm settle --timeout=5 2>/dev/null || true

  local i
  for ((i = 0; i < 20; i++)); do
    if ! losetup "$loop" >/dev/null 2>&1; then
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

# ---------------------------------------------------------------------------
# System state snapshots (before/after build hygiene)
# ---------------------------------------------------------------------------

# Snapshot current system state (loops, mounts, ext4 superblocks).
# Writes to a file that can be compared later.
# Args: $1 = output file path
snapshot_system_state() {
  local outfile="${1:?snapshot_system_state: missing output file}"

  {
    echo "=== LOOP DEVICES ==="
    losetup -J 2>/dev/null || echo '{"loopdevices":[]}'
    echo ""
    echo "=== MOUNTS ==="
    findmnt --real --raw -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || true
    echo ""
    echo "=== EXT4 SUPERBLOCKS ==="
    local sys
    for sys in /sys/fs/ext4/*/; do
      [[ -d "$sys" ]] && basename "$sys"
    done 2>/dev/null || true
  } >"$outfile"
}

# Extract loop device names from a system state snapshot file.
# Args: $1 = snapshot file path
# Prints sorted loop device names, one per line.
_extract_loop_names() {
  local file="${1:?_extract_loop_names: missing file}"
  sed -n '/^=== LOOP DEVICES ===$/,/^===/{/^===/d;p}' "$file" \
    | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    for d in data.get("loopdevices", []):
        print(d.get("name",""))
except: pass
' 2>/dev/null | sort
}

# Compare two system state snapshots and report differences.
# Args: $1 = before snapshot, $2 = after snapshot, $3 = label (optional)
# Returns 0 if clean (no new entries), 1 if leftovers detected.
compare_system_state() {
  local before="${1:?compare_system_state: missing before snapshot}"
  local after="${2:?compare_system_state: missing after snapshot}"
  local label="${3:-build}"

  [[ -f "$before" && -f "$after" ]] || {
    warn "compare_system_state: missing snapshot files"
    return 1
  }

  local rc=0

  # Extract loop device names from JSON section
  local loops_before loops_after
  loops_before="$(_extract_loop_names "$before")"
  loops_after="$(_extract_loop_names "$after")"

  # Extract mount targets from MOUNTS section (skip header line)
  local mounts_before mounts_after
  mounts_before="$(sed -n '/^=== MOUNTS ===$/,/^===/{/^===/d;/^TARGET/d;p}' "$before" \
    | awk '{print $1}' | sort)"
  mounts_after="$(sed -n '/^=== MOUNTS ===$/,/^===/{/^===/d;/^TARGET/d;p}' "$after" \
    | awk '{print $1}' | sort)"

  # Extract ext4 superblocks
  local ext4_before ext4_after
  ext4_before="$(sed -n '/^=== EXT4 SUPERBLOCKS ===$/,/^===/{/^===/d;p}' "$before" | sort)"
  ext4_after="$(sed -n '/^=== EXT4 SUPERBLOCKS ===$/,/^===/{/^===/d;p}' "$after" | sort)"

  # Compare loops
  local new_loops gone_loops
  new_loops="$(echo "$loops_before" | grep -v '^$' | comm -13 - <(echo "$loops_after" | grep -v '^$'))"
  gone_loops="$(echo "$loops_before" | grep -v '^$' | comm -23 - <(echo "$loops_after" | grep -v '^$'))"

  # Compare mounts
  local new_mounts gone_mounts
  new_mounts="$(echo "$mounts_before" | grep -v '^$' | comm -13 - <(echo "$mounts_after" | grep -v '^$'))"
  gone_mounts="$(echo "$mounts_before" | grep -v '^$' | comm -23 - <(echo "$mounts_after" | grep -v '^$'))"

  # Compare ext4 superblocks
  local new_ext4 gone_ext4
  new_ext4="$(echo "$ext4_before" | grep -v '^$' | comm -13 - <(echo "$ext4_after" | grep -v '^$'))"
  gone_ext4="$(echo "$ext4_before" | grep -v '^$' | comm -23 - <(echo "$ext4_after" | grep -v '^$'))"

  # Report
  log "System state comparison ($label):"

  if [[ -n "$new_loops" ]]; then
    warn "  NEW loop devices (left behind):"
    emit_prefixed_lines warn "    " "$new_loops" 1
    rc=1
  fi

  if [[ -n "$new_mounts" ]]; then
    warn "  NEW mounts (left behind):"
    emit_prefixed_lines warn "    " "$new_mounts" 1
    rc=1
  fi

  if [[ -n "$new_ext4" ]]; then
    warn "  NEW ext4 superblocks (left behind):"
    emit_prefixed_lines warn "    " "$new_ext4" 1
    rc=1
  fi

  if [[ -n "$gone_loops" ]]; then
    log "  Removed loop devices (expected):"
    emit_prefixed_lines log "    " "$gone_loops" 1
  fi

  if [[ -n "$gone_mounts" ]]; then
    log "  Removed mounts (expected):"
    emit_prefixed_lines log "    " "$gone_mounts" 1
  fi

  if [[ -n "$gone_ext4" ]]; then
    log "  Removed ext4 superblocks (expected):"
    emit_prefixed_lines log "    " "$gone_ext4" 1
  fi

  if ((rc == 0)); then
    log "  Clean — no leftover resources detected"
  fi

  return "$rc"
}

# ---------------------------------------------------------------------------
# Chroot filesystem mounting
# ---------------------------------------------------------------------------

# Mount proc/sys/dev into a chroot directory.
# Args: $1 = root path (e.g. $MNT, $MERGED, $NEWROOT)
mount_chroot_fs() {
  local root="${1:?mount_chroot_fs: missing root}"
  log "Mounting chroot filesystems in $root"
  mkdir -p "$root/proc" "$root/sys" "$root/dev"
  mount -t proc proc "$root/proc" \
    || die "Failed to mount proc in $root"
  mount --rbind /sys "$root/sys" \
    || {
      umount -R "$root/proc" 2>/dev/null
      die "Failed to mount sys in $root"
    }
  mount --make-rslave "$root/sys" 2>/dev/null || true
  mount --rbind /dev "$root/dev" \
    || {
      umount -R "$root/sys" "$root/proc" 2>/dev/null
      die "Failed to mount dev in $root"
    }
  mount --make-rslave "$root/dev" 2>/dev/null || true
  log "  chroot mounts ready: proc sys dev"
}

# Unmount proc/sys/dev from a chroot directory.
# Args: $1 = root path, $2 = mode (optional: "strict" to die on failure, default: permissive)
umount_chroot_fs() {
  local root="${1:?umount_chroot_fs: missing root}"
  local mode="${2:-}"

  # Collect only the children that are actually mounted — avoids spurious
  # warnings when cleanup runs before mount_chroot_fs was called.
  local -a targets=()
  local child
  for child in proc sys dev; do
    mountpoint -q "$root/$child" 2>/dev/null && targets+=("$root/$child")
  done

  if [[ ${#targets[@]} -eq 0 ]]; then
    log "Unmounting chroot filesystems in $root (nothing mounted)"
    return 0
  fi

  log "Unmounting chroot filesystems in $root"
  if ! umount -R "${targets[@]}" 2>/dev/null; then
    if [[ "$mode" == "strict" ]]; then
      warn "Failed to unmount chroot filesystems in $root"
      warn "  Active mounts:"
      findmnt --target "$root" -o SOURCE,TARGET,OPTIONS 2>/dev/null | while IFS="" read -r line; do
        warn "    $line"
      done
      die "Could not cleanly unmount chroot in $root"
    else
      warn "Regular unmount failed for $root, trying lazy unmount"
      umount -Rl "${targets[@]}" 2>/dev/null || true
    fi
  fi
  log "  chroot mounts removed"
}

# ---------------------------------------------------------------------------
# Mount unmount wrapper
# ---------------------------------------------------------------------------

# Unmount a path if it is a mountpoint.  No-op when not mounted.
# Args: $1 = path, $2 = label (used in error message)
ensure_unmounted() {
  local path="${1:?ensure_unmounted: missing path}"
  local label="${2:-$path}"
  if mountpoint -q "$path" 2>/dev/null; then
    strict_unmount "$path" "$label" || die "Could not clean stale $label"
  fi
}

# ---------------------------------------------------------------------------
# Persistent mount tracking (file-based)
# ---------------------------------------------------------------------------
# A plain-text file ($MOUNTS_FILE, typically $WORKDIR/mounts) records every
# mountpoint we create.  If the process is killed before cleanup runs, the next
# build reads this file and tears down the leftovers in reverse order.
#
# Callers set MOUNTS_FILE before using these helpers.  All functions are no-ops
# when MOUNTS_FILE is unset or the file does not exist.

# Append a mountpoint to the tracking file.  Idempotent — duplicates are
# silently skipped.
# Args: $1 = mountpoint path
track_mount() {
  local mnt="${1:?track_mount: missing mountpoint}"
  [[ -n "${MOUNTS_FILE:-}" ]] || return 0
  mkdir -p "$(dirname "$MOUNTS_FILE")"
  if [[ ! -f "$MOUNTS_FILE" ]] || ! grep -qxF "$mnt" "$MOUNTS_FILE" 2>/dev/null; then
    printf '%s\n' "$mnt" >>"$MOUNTS_FILE"
  fi
}

# Remove a mountpoint from the tracking file, but ONLY after verifying the
# mount is actually gone.  No-op if the entry does not exist or the path is
# still mounted.
# Args: $1 = mountpoint path
untrack_mount() {
  local mnt="${1:?untrack_mount: missing mountpoint}"
  [[ -n "${MOUNTS_FILE:-}" && -f "$MOUNTS_FILE" ]] || return 0

  # Safety: refuse to untrack if the mount is still alive.
  if mountpoint -q "$mnt" 2>/dev/null; then
    warn "untrack_mount: $mnt is still mounted — refusing to remove from tracking"
    return 1
  fi

  local tmp="${MOUNTS_FILE}.untrack.$$"
  grep -vxF "$mnt" "$MOUNTS_FILE" >"$tmp" 2>/dev/null || true
  if [[ -s "$tmp" ]]; then
    mv -- "$tmp" "$MOUNTS_FILE"
  else
    rm -f "$tmp" "$MOUNTS_FILE"
  fi
}

# Read the tracking file and tear down every listed mount in reverse order.
# Entries for mounts that are already gone are silently removed.  Entries whose
# unmount fails are left in place for the next attempt.
# Args: none (uses $MOUNTS_FILE)
cleanup_tracked_mounts() {
  [[ -n "${MOUNTS_FILE:-}" && -f "$MOUNTS_FILE" ]] || return 0

  log "Cleaning up tracked mounts from $MOUNTS_FILE"

  # Read into an array so we can process in reverse (LIFO).
  local -a mounts=()
  local line
  while IFS="" read -r line; do
    [[ -n "$line" ]] && mounts+=("$line")
  done <"$MOUNTS_FILE"

  if [[ ${#mounts[@]} -eq 0 ]]; then
    rm -f "$MOUNTS_FILE"
    return 0
  fi

  local rc=0
  local i
  for ((i = ${#mounts[@]} - 1; i >= 0; i--)); do
    local m="${mounts[$i]}"

    if ! mountpoint -q "$m" 2>/dev/null; then
      # Already gone — just clean the entry.
      untrack_mount "$m" 2>/dev/null || true
      continue
    fi

    if strict_unmount "$m" "tracked mount"; then
      untrack_mount "$m" 2>/dev/null || true
    else
      warn "cleanup_tracked_mounts: could not unmount $m"
      rc=1
    fi
  done

  # If everything was cleaned up, remove the file.
  if ((rc == 0)) && [[ -f "$MOUNTS_FILE" ]]; then
    local remaining
    remaining="$(wc -l <"$MOUNTS_FILE" 2>/dev/null || echo 1)"
    if [[ "$remaining" -eq 0 ]] 2>/dev/null; then
      rm -f "$MOUNTS_FILE"
    fi
  fi

  return "$rc"
}

# ── Cleanup tracking system ─────────────────────────────────────────────────────
# NEW GREENFIELD CODE — added as part of the mount/loop cleanup system redesign.
# This section provides resource tracking, workspace boundary enforcement,
# identity-verified teardown, and deterministic cleanup orchestration.
#
# Dependencies: strict_unmount (above), log/warn/die/debug (common.sh)
# ────────────────────────────────────────────────────────────────────────────────

CLEANUP_RUNNING=0
CLEANUP_INCOMPLETE=0
CLEANUP_ATTEMPTED=0

declare -a CLEANUP_MOUNTS=()
declare -a CLEANUP_MOUNT_IDS=()
declare -a CLEANUP_MOUNT_LABELS=()
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
  if ! cleanup_validate_workspace "$mountpoint"; then
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

  if (( mount_count == 0 )); then
    warn "cleanup_track_mount: could not resolve mount ID for $canonical"
    return 1
  fi

  if (( mount_count > 1 )); then
    warn "cleanup_track_mount: multiple mounts at $canonical ($mount_count) — stacked mounts not supported"
    return 1
  fi

  local mount_id
  mount_id="$(echo "$mount_ids" | head -1)"

  # Always append — no deduplication (handles stacked mounts)
  CLEANUP_MOUNTS+=("$canonical")
  CLEANUP_MOUNT_LABELS+=("${label:-$canonical}")
  CLEANUP_MOUNT_IDS+=("$mount_id")
}

# cleanup_track_loop LOOPDEV BACKING_FILE [LABEL]
#   Register a loop device for cleanup.
#   Records backing-file identity (device:inode) for safe comparison.
cleanup_track_loop() {
  local loopdev="${1:?cleanup_track_loop: missing loop device}"
  local backing="${2:?cleanup_track_loop: missing backing file}"
  local label="${3:-}"

  # Lifecycle guard
  if (( CLEANUP_RUNNING )); then
    warn "cleanup_track_loop: cannot register during cleanup"
    return 1
  fi

  # Workspace validation
  if [[ -n "$CLEANUP_WORKSPACE_ROOT" ]]; then
    if ! cleanup_validate_workspace "$backing"; then
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
  if ! cleanup_validate_workspace "$dir"; then
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
      /opt | /proc | /root | /run | /sbin | /srv | /sys | /usr | /var)
      die "cleanup_set_workspace: refusing to use system path as workspace: $resolved"
      ;;
  esac

  CLEANUP_WORKSPACE_ROOT="$resolved"
}

# cleanup_validate_workspace PATH
#   Verify PATH is inside the approved workspace boundary.
#   Returns 1 if the path is outside the boundary or boundary is not set.
cleanup_validate_workspace() {
  local path="${1:?cleanup_validate_workspace: missing path}"

  [[ -n "$CLEANUP_WORKSPACE_ROOT" ]] || {
    warn "cleanup_validate_workspace: no workspace boundary set"
    return 1
  }

  local resolved
  resolved="$(realpath "$path" 2>/dev/null)" || {
    warn "cleanup_validate_workspace: cannot resolve $path"
    return 1
  }

  # Reject dangerous paths
  case "$resolved" in
    / | /bin | /boot | /dev | /etc | /home | /lib* | /media | /mnt | \
      /opt | /proc | /root | /run | /sbin | /srv | /sys | /usr | /var)
      warn "cleanup_validate_workspace: refusing to clean system path: $resolved"
      return 1
      ;;
  esac

  # Reject paths with .. that could escape
  if [[ "$path" == *".."* ]]; then
    warn "cleanup_validate_workspace: path contains '..': $path"
    return 1
  fi

  # Must be inside workspace root (exact match or descendant)
  local ws="${CLEANUP_WORKSPACE_ROOT%/}/"
  if [[ "$resolved" == "$CLEANUP_WORKSPACE_ROOT" ]] || [[ "$resolved" == "${ws}"* ]]; then
    return 0
  fi

  warn "cleanup_validate_workspace: $path is outside workspace $CLEANUP_WORKSPACE_ROOT"
  return 1
}

# _cleanup_read_mount_inventory
#   Read kernel mount inventory, decode escape sequences, print clean paths.
#   Returns 0 on success, 1 on failure.
_cleanup_read_mount_inventory() {
  local raw line

  raw="$(findmnt -rno TARGET --kernel 2>/dev/null)" || return 1

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf '%b\n' "$line" || return 1
  done <<< "$raw"

  return 0
}

# cleanup_assert_no_mounts_under DIRECTORY
#   Check that no mounts exist at or below DIRECTORY.
#   Returns 0 if clean, 1 if mounts found.
cleanup_assert_no_mounts_under() {
  local dir="${1:?cleanup_assert_no_mounts_under: missing directory}"

  # Normalize directory
  local normalized
  normalized="$(realpath "$dir" 2>/dev/null)" || normalized="${dir%/}"
  normalized="${normalized%/}"
  local normalized_with_slash="${normalized}/"

  [[ -d "$normalized" ]] || return 0

  # Read kernel mount inventory with decoding
  local all_mounts
  all_mounts="$(_cleanup_read_mount_inventory)" || {
    warn "cleanup_assert_no_mounts_under: cannot read kernel mount table"
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
    [[ "$m_normalized" == "$normalized" ]] && { found=1; break; }
    # Descendant match
    [[ "$m_normalized" == "${normalized_with_slash}"* ]] && { found=1; break; }
  done <<< "$all_mounts"

  if (( found )); then
    warn "cleanup_assert_no_mounts_under: mount(s) remain under $dir"
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

  # Reverse iteration
  for ((i = ${#CLEANUP_MOUNTS[@]} - 1; i >= 0; i--)); do
    local m="${CLEANUP_MOUNTS[$i]}"
    local label="${CLEANUP_MOUNT_LABELS[$i]:-}"
    local expected_id="${CLEANUP_MOUNT_IDS[$i]:-}"

    # Revalidate path before unmounting
    if [[ -n "$CLEANUP_WORKSPACE_ROOT" ]]; then
      if ! cleanup_validate_workspace "$m"; then
        warn "cleanup_unmount_registered: $m no longer in workspace — preserving"
        rc=1
        continue
      fi
    fi

    if ! mountpoint -q "$m" 2>/dev/null; then
      debug "cleanup_unmount_registered: $m already unmounted"
      continue
    fi

    # Verify mount identity before unmounting — reject if multiple mounts (stacked)
    local current_ids
    current_ids="$(findmnt -rno ID -M "$m" --kernel 2>/dev/null)" || current_ids=""

    local current_count
    current_count="$(echo "$current_ids" | grep -c . 2>/dev/null)" || current_count=0

    if (( current_count == 0 )); then
      warn "cleanup_unmount_registered: cannot verify identity of $m — preserving"
      rc=1
      continue
    fi

    if (( current_count > 1 )); then
      warn "cleanup_unmount_registered: multiple mounts at $m ($current_count) — stacked mounts not supported"
      rc=1
      continue
    fi

    local current_id
    current_id="$(echo "$current_ids" | head -1)"

    if [[ -z "$expected_id" || -z "$current_id" ]]; then
      warn "cleanup_unmount_registered: cannot verify identity of $m — preserving"
      rc=1
      continue
    fi

    if [[ "$current_id" != "$expected_id" ]]; then
      warn "cleanup_unmount_registered: $m identity changed ($expected_id → $current_id) — preserving"
      rc=1
      continue
    fi

    # Ledger: mark releasing
    if [[ -n "$_LEDGER_RUN_DIR" ]]; then
      cleanup_ledger_mark_releasing "mount:$m" || true
    fi

    if strict_unmount "$m" "${label:-cleanup}"; then
      # Ledger: mark released
      if [[ -n "$_LEDGER_RUN_DIR" ]]; then
        cleanup_ledger_mark_released "mount:$m" || true
      fi
      debug "cleanup_unmount_registered: unmounted $m"
    else
      warn "cleanup_unmount_registered: failed to unmount $m"
      rc=1
    fi
  done

  return "$rc"
}

# cleanup_verify_mounts_released
#   Verify all tracked mounts are actually gone.
#   Returns 0 if all released, 1 if any remain.
cleanup_verify_mounts_released() {
  local rc=0
  local i

  # Read complete mount inventory ONCE — failure here means we can't verify
  local all_mounts
  all_mounts="$(_cleanup_read_mount_inventory)" || {
    warn "cleanup_verify_mounts_released: cannot read mount inventory"
    return 1
  }

  for (( i=0; i<${#CLEANUP_MOUNTS[@]}; i++ )); do
    local m="${CLEANUP_MOUNTS[$i]}"
    
    # Use here-string to avoid pipefail issues
    if grep -qxF -- "$m" <<< "$all_mounts" 2>/dev/null; then
      warn "cleanup_verify_mounts_released: $m still mounted"
      rc=1
    fi
  done

  return "$rc"
}

# cleanup_detach_registered_loops
#   Detach all tracked loop devices.
#   Returns 0 if all detached, 1 if any remain.
cleanup_detach_registered_loops() {
  local rc=0
  local i

  # Read configured-loop inventory once — failure means we can't verify
  local loop_inventory
  loop_inventory="$(losetup -a 2>/dev/null)" || {
    warn "cleanup_detach_registered_loops: cannot read loop inventory"
    CLEANUP_INCOMPLETE=1
    return 1
  }

  # Verify no unexpected mounts remain before detaching loops
  if [[ -n "$CLEANUP_WORKSPACE_ROOT" ]]; then
    if ! cleanup_assert_no_mounts_under "$CLEANUP_WORKSPACE_ROOT"; then
      warn "cleanup_detach_registered_loops: unexpected mounts remain under workspace — preserving loops"
      CLEANUP_INCOMPLETE=1
      return 1
    fi
  fi

  for ((i = 0; i < ${#CLEANUP_LOOPS[@]}; i++)); do
    local l="${CLEANUP_LOOPS[$i]}"
    local expected_backing="${CLEANUP_LOOP_BACKINGS[$i]:-}"

    # Check if loop is still attached using cached inventory
    if ! grep -q "^${l}:" <<< "$loop_inventory" 2>/dev/null; then
      debug "cleanup_detach_registered_loops: $l already detached"
      continue
    fi

    # Verify loop backing identity before detaching
    local current_backing_id=""
    
    # Try sysfs first (gives us the backing path, then we stat it)
    if [[ -f "/sys/block/${l##*/}/loop/backing_file" ]]; then
      local current_backing_path
      current_backing_path="$(cat "/sys/block/${l##*/}/loop/backing_file" 2>/dev/null)" || current_backing_path=""
      if [[ -n "$current_backing_path" && -e "$current_backing_path" ]]; then
        current_backing_id="$(stat -c '%d:%i' "$current_backing_path" 2>/dev/null)" || current_backing_id=""
      fi
    fi
    
    # If sysfs failed, we cannot verify identity — preserve the loop
    if [[ -z "$current_backing_id" ]]; then
      warn "cleanup_detach_registered_loops: cannot verify identity of $l (sysfs unavailable) — preserving"
      rc=1
      continue
    fi

    if [[ -z "$expected_backing" || -z "$current_backing_id" ]]; then
      warn "cleanup_detach_registered_loops: cannot verify identity of $l — preserving"
      rc=1
      continue
    fi

    if [[ "$current_backing_id" != "$expected_backing" ]]; then
      warn "cleanup_detach_registered_loops: $l backing changed ($expected_backing → $current_backing_id) — preserving"
      rc=1
      continue
    fi

    # Ledger: compute loop ID from backing file path (matches creation ID format)
    local _pf_ledger_loop_id=""
    if [[ -f "/sys/block/${l##*/}/loop/backing_file" ]]; then
      local _pf_bp_path
      _pf_bp_path="$(cat "/sys/block/${l##*/}/loop/backing_file" 2>/dev/null)" || _pf_bp_path=""
      if [[ -n "$_pf_bp_path" ]]; then
        _pf_ledger_loop_id="loop:$(realpath "$_pf_bp_path" 2>/dev/null || printf '%s' "$_pf_bp_path")"
      fi
    fi

    # Ledger: mark releasing
    if [[ -n "$_LEDGER_RUN_DIR" && -n "$_pf_ledger_loop_id" ]]; then
      cleanup_ledger_mark_releasing "$_pf_ledger_loop_id" || true
    fi

    if strict_detach_loop "$l" 2>/dev/null; then
      # Ledger: mark released
      if [[ -n "$_LEDGER_RUN_DIR" && -n "$_pf_ledger_loop_id" ]]; then
        cleanup_ledger_mark_released "$_pf_ledger_loop_id" || true
      fi
      debug "cleanup_detach_registered_loops: detached $l"
    else
      warn "cleanup_detach_registered_loops: failed to detach $l (backing: ${expected_backing:-unknown})"
      rc=1
    fi
  done

  return "$rc"
}

# cleanup_remove_registered_tempdirs
#   Remove registered temporary directories (must be empty after unmounting).
#   Returns 0 if all removed, 1 if any remain.
cleanup_remove_registered_tempdirs() {
  local rc=0
  local i

  # Reverse iteration (same as mounts)
  for ((i = ${#CLEANUP_TEMPDIRS[@]} - 1; i >= 0; i--)); do
    local d="${CLEANUP_TEMPDIRS[$i]}"

    [[ -d "$d" ]] || continue

    # Revalidate path is still inside workspace before removal
    if [[ -n "$CLEANUP_WORKSPACE_ROOT" ]]; then
      if ! cleanup_validate_workspace "$d"; then
        warn "cleanup_remove_registered_tempdirs: $d no longer in workspace — preserving"
        rc=1
        continue
      fi
    fi

    # rmdir handles emptiness check internally — no separate ls -A race
    if ! rmdir "$d" 2>/dev/null; then
      warn "cleanup_remove_registered_tempdirs: could not remove $d (not empty or still in use)"
      rc=1
    fi
  done

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

  # Phase 1: Unmount registered mounts
  cleanup_unmount_registered || mounts_ok=0

  # Phase 2: Verify mounts are released
  cleanup_verify_mounts_released || mounts_ok=0

  if ((!mounts_ok)); then
    warn "cleanup_environment: mount cleanup incomplete — preserving loops and workspace"
    CLEANUP_INCOMPLETE=1
    CLEANUP_RUNNING=0
    return 1
  fi

  # Phase 3: Detach registered loops
  cleanup_detach_registered_loops || loops_ok=0

  if ((!loops_ok)); then
    warn "cleanup_environment: loop cleanup incomplete — preserving workspace"
    CLEANUP_INCOMPLETE=1
    CLEANUP_RUNNING=0
    return 1
  fi

  # Phase 4: Remove registered temp directories
  local rc=0
  cleanup_remove_registered_tempdirs || rc=1

  # Phase 5: Final verification
  cleanup_verify || rc=1

  # Ledger: mark run as CLEAN
  if (( rc == 0 )) && [[ -n "$_LEDGER_RUN_DIR" ]]; then
    cleanup_ledger_finish || true
  fi

  CLEANUP_INCOMPLETE=$rc
  CLEANUP_RUNNING=0
  return "$rc"
}

# cleanup_verify
#   Verify the workspace is fully clean.
#   Returns 0 if clean, 1 if residuals remain.
cleanup_verify() {
  local rc=0
  local i

  # Check all tracked mounts
  local all_mounts
  all_mounts="$(_cleanup_read_mount_inventory)" || {
    warn "cleanup_verify: cannot read mount inventory"
    rc=1
  }

  for (( i=0; i<${#CLEANUP_MOUNTS[@]}; i++ )); do
    # Use here-string to avoid pipefail issues
    if grep -qxF -- "${CLEANUP_MOUNTS[$i]}" <<< "$all_mounts" 2>/dev/null; then
      warn "cleanup_verify: ${CLEANUP_MOUNTS[$i]} still mounted"
      rc=1
    fi
  done

  # Check all tracked loops
  # Read configured-loop inventory once
  local loop_inventory
  loop_inventory="$(losetup -a 2>/dev/null)" || {
    warn "cleanup_verify: cannot read loop inventory"
    rc=1
  }

  for (( i=0; i<${#CLEANUP_LOOPS[@]}; i++ )); do
    local l="${CLEANUP_LOOPS[$i]}"
    local is_attached=0

    # Check sysfs first (preferred)
    if [[ -e "/sys/block/${l##*/}/loop/backing_file" ]]; then
      is_attached=1
    # Fall back to loop inventory
    elif grep -q "^${l}:" <<< "$loop_inventory" 2>/dev/null; then
      is_attached=1
    fi

    if (( is_attached )); then
      warn "cleanup_verify: ${CLEANUP_LOOPS[$i]} still attached"
      rc=1
    fi
  done

  # Check all tracked tempdirs
  for ((i = 0; i < ${#CLEANUP_TEMPDIRS[@]}; i++)); do
    if [[ -d "${CLEANUP_TEMPDIRS[$i]}" ]]; then
      warn "cleanup_verify: ${CLEANUP_TEMPDIRS[$i]} still exists"
      rc=1
    fi
  done

  # Also verify no unexpected mounts under workspace
  if [[ -n "$CLEANUP_WORKSPACE_ROOT" ]]; then
    if ! cleanup_assert_no_mounts_under "$CLEANUP_WORKSPACE_ROOT"; then
      rc=1
    fi
  fi

  if ((rc == 0)); then
    debug "cleanup_verify: workspace is clean"
  fi

  return "$rc"
}

# cleanup_reset
#   Clear all tracking state. Call after successful cleanup or before a new run.
cleanup_reset() {
  if ((CLEANUP_RUNNING)); then
    warn "cleanup_reset: cannot reset during cleanup"
    return 1
  fi

  local has_registrations=0
  ((${#CLEANUP_MOUNTS[@]} > 0)) && has_registrations=1
  ((${#CLEANUP_LOOPS[@]} > 0)) && has_registrations=1
  ((${#CLEANUP_TEMPDIRS[@]} > 0)) && has_registrations=1

  if (( has_registrations )); then
    # Require cleanup was attempted AND succeeded
    if (( ! CLEANUP_ATTEMPTED || CLEANUP_INCOMPLETE )); then
      warn "cleanup_reset: cannot reset unresolved cleanup state"
      return 1
    fi

    # Verify success before clearing
    if ! cleanup_verify; then
      warn "cleanup_reset: verification failed — refusing to clear registrations"
      return 1
    fi
  fi

  CLEANUP_MOUNTS=()
  CLEANUP_MOUNT_IDS=()
  CLEANUP_MOUNT_LABELS=()
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
  shift 2 || shift $#  # Consume target and label

  # Skip -- separator if present
  [[ "${1:-}" == "--" ]] && shift

  # --- Preconditions ---
  if (( CLEANUP_RUNNING )); then
    warn "cleanup_mount: cannot create mounts during cleanup"
    return 1
  fi

  if [[ -z "$CLEANUP_WORKSPACE_ROOT" ]]; then
    warn "cleanup_mount: CLEANUP_WORKSPACE_ROOT not set — call cleanup_set_workspace first"
    return 1
  fi

  if ! cleanup_validate_workspace "$target"; then
    return 1
  fi

  # Check target is not already a mountpoint (reject stacking)
  if mountpoint -q "$target" 2>/dev/null; then
    warn "cleanup_mount: $target is already a mountpoint — stacking not supported"
    return 1
  fi

  # Ledger: persist PREPARED record
  local _pf_ledger_id="mount:$(realpath "$target" 2>/dev/null || printf '%s' "$target")"
  if [[ -n "$_LEDGER_RUN_DIR" ]]; then
    cleanup_ledger_prepare "$_pf_ledger_id" "mount" "$target" "" "$label" || {
      warn "cleanup_mount: ledger prepare failed — aborting"
      return 1
    }
  fi

  # Attempt mount
  if ! mount "$@" "$target" 2>/dev/null; then
    warn "cleanup_mount: mount failed for $target"
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
      CLEANUP_MOUNTS+=("$target")
      CLEANUP_MOUNT_IDS+=("$_pf_mnt_id")
      CLEANUP_MOUNT_LABELS+=("${label:-$target}")
    fi
    return 1
  fi

  # Ledger: transition to ACTIVE
  if [[ -n "$_LEDGER_RUN_DIR" ]]; then
    cleanup_ledger_activate "$_pf_ledger_id" "$(findmnt -rno ID -M "$target" --kernel 2>/dev/null | head -1)" || true
  fi

  debug "cleanup_mount: mounted and registered $target"
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
    _pf_*|CLEANUP_*|CLEANUP_ATTACHED_*)
      warn "cleanup_attach_loop: output variable name '$_pf_output_var' is reserved"
      return 1
      ;;
  esac

  # --- Preconditions ---
  if (( CLEANUP_RUNNING )); then
    warn "cleanup_attach_loop: cannot create loops during cleanup"
    return 1
  fi

  if [[ -z "$CLEANUP_WORKSPACE_ROOT" ]]; then
    warn "cleanup_attach_loop: CLEANUP_WORKSPACE_ROOT not set"
    return 1
  fi

  if ! cleanup_validate_workspace "$_pf_backing"; then
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

  if (( _pf_loops_rc != 0 )) && [[ -z "$_pf_existing" ]]; then
    warn "cleanup_attach_loop: could not query existing loops for $_pf_backing (rc=$_pf_loops_rc)"
    return 1
  fi

  # Ledger: persist PREPARED record (backing file known, loop device not yet)
  local _pf_ledger_id="loop:$(realpath "$_pf_backing" 2>/dev/null || printf '%s' "$_pf_backing")"
  if [[ -n "$_LEDGER_RUN_DIR" ]]; then
    cleanup_ledger_prepare "$_pf_ledger_id" "loop" "$_pf_backing" "" "$_pf_label" || {
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
    cleanup_ledger_activate "$_pf_ledger_id" "$_pf_loop_identity" || true
  fi

  # Output loop device via nameref
  local -n _pf_result_ref="$_pf_output_var"
  _pf_result_ref="$_pf_loopdev"
  debug "cleanup_attach_loop: attached and registered $_pf_loopdev (backing: $_pf_backing)"
  return 0
}

# cleanup_mount_chroot ROOT
#   Mount standard chroot filesystems (proc, sys, dev, dev/pts, dev/shm).
#   Registers each mount individually for reverse-order teardown.
#   Returns 0 if all mounted, 1 on partial failure.
cleanup_mount_chroot() {
  local root="${1:?cleanup_mount_chroot: missing root}"

  # --- Preconditions ---
  if (( CLEANUP_RUNNING )); then
    warn "cleanup_mount_chroot: cannot create mounts during cleanup"
    return 1
  fi
  if [[ -z "$CLEANUP_WORKSPACE_ROOT" ]]; then
    warn "cleanup_mount_chroot: CLEANUP_WORKSPACE_ROOT not set"
    return 1
  fi
  if ! cleanup_validate_workspace "$root"; then
    return 1
  fi

  [[ -d "$root" ]] || die "cleanup_mount_chroot: $root is not a directory"

  # Record registration boundary — only roll back what we create
  local boundary=${#CLEANUP_MOUNTS[@]}

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
  (( rc )) && { _cleanup_chroot_rollback "$boundary"; return "$rc"; }

  # sys — non-recursive bind
  if ! mountpoint -q "$root/sys" 2>/dev/null; then
    if cleanup_mount "$root/sys" "chroot sys" -- --bind /sys; then
      if ! mount --make-rslave "$root/sys" 2>/dev/null; then
        warn "cleanup_mount_chroot: failed to set propagation on /sys"
        rc=1
      fi
    else
      warn "cleanup_mount_chroot: failed to mount /sys"
      rc=1
    fi
  fi
  (( rc )) && { _cleanup_chroot_rollback "$boundary"; return "$rc"; }

  # dev
  if ! mountpoint -q "$root/dev" 2>/dev/null; then
    if cleanup_mount "$root/dev" "chroot dev" -- --bind /dev; then
      if ! mount --make-private "$root/dev" 2>/dev/null; then
        warn "cleanup_mount_chroot: failed to set propagation on /dev"
        rc=1
      fi
    else
      warn "cleanup_mount_chroot: failed to mount /dev"
      rc=1
    fi
  fi
  (( rc )) && { _cleanup_chroot_rollback "$boundary"; return "$rc"; }

  # dev/pts
  if ! mountpoint -q "$root/dev/pts" 2>/dev/null; then
    if cleanup_mount "$root/dev/pts" "chroot dev/pts" -- --bind /dev/pts; then
      if ! mount --make-private "$root/dev/pts" 2>/dev/null; then
        warn "cleanup_mount_chroot: failed to set propagation on /dev/pts"
        rc=1
      fi
    else
      warn "cleanup_mount_chroot: failed to mount /dev/pts"
      rc=1
    fi
  fi
  (( rc )) && { _cleanup_chroot_rollback "$boundary"; return "$rc"; }

  # dev/shm
  if ! mountpoint -q "$root/dev/shm" 2>/dev/null; then
    if cleanup_mount "$root/dev/shm" "chroot dev/shm" -- -t tmpfs tmpfs -o mode=1777,nosuid,nodev; then
      debug "cleanup_mount_chroot: mounted dev/shm"
    else
      warn "cleanup_mount_chroot: failed to mount dev/shm"
      rc=1
    fi
  fi
  (( rc )) && { _cleanup_chroot_rollback "$boundary"; return "$rc"; }

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
  for (( i=${#CLEANUP_MOUNTS[@]}-1; i>=boundary; i-- )); do
    local m="${CLEANUP_MOUNTS[$i]}"
    local expected_id="${CLEANUP_MOUNT_IDS[$i]:-}"

    # Verify mount is still present in inventory before attempting unmount
    if ! grep -qxF -- "$m" <<< "$inventory" 2>/dev/null; then
      # Already absent — just remove from tracking
      unset 'CLEANUP_MOUNTS[i]'
      unset 'CLEANUP_MOUNT_IDS[i]'
      unset 'CLEANUP_MOUNT_LABELS[i]'
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
    if [[ -n "$post_inventory" ]] && grep -qxF -- "$m" <<< "$post_inventory" 2>/dev/null; then
      warn "_cleanup_chroot_rollback: $m still present after unmount — preserving"
      CLEANUP_INCOMPLETE=1
      rc=1
      continue
    fi

    # Ledger: mark released
    if [[ -n "$_LEDGER_RUN_DIR" ]]; then
      cleanup_ledger_mark_released "mount:$m" || true
    fi

    # Successfully unmounted — remove from tracking
    unset 'CLEANUP_MOUNTS[i]'
    unset 'CLEANUP_MOUNT_IDS[i]'
    unset 'CLEANUP_MOUNT_LABELS[i]'
  done

  # Re-index arrays
  CLEANUP_MOUNTS=("${CLEANUP_MOUNTS[@]}")
  CLEANUP_MOUNT_IDS=("${CLEANUP_MOUNT_IDS[@]}")
  CLEANUP_MOUNT_LABELS=("${CLEANUP_MOUNT_LABELS[@]}")

  return "$rc"
}

# cleanup_stop_workers
#   Stop all background jobs launched by the build.
#   Waits for them to exit. Does NOT kill arbitrary processes.
#   Returns 0 when all workers have exited.
#
#   NOTE: This covers shell-level background jobs (jobs -p).
#   Pipeline members and subprocess trees are NOT guaranteed to be stopped.
#   Callers should ensure build jobs are launched as direct background jobs,
#   not through subprocess pipelines, for reliable shutdown.
cleanup_stop_workers() {
  local timeout=10
  local waited=0

  # Get list of background job PIDs
  # Note: this covers shell-level background jobs (jobs -p).
  # Pipeline members and subprocess trees are NOT guaranteed to be stopped.
  # Callers should ensure build jobs are launched as direct background jobs,
  # not through subprocess pipelines, for reliable shutdown.
  local -a pids=()
  local job
  while IFS="" read -r job; do
    local pid="${job%% *}"
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(jobs -p 2>/dev/null)

  if [[ ${#pids[@]} -eq 0 ]]; then
    debug "cleanup_stop_workers: no background jobs"
    return 0
  fi

  debug "cleanup_stop_workers: stopping ${#pids[@]} background job(s)"

  # Send SIGTERM to each
  for pid in "${pids[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done

  # Wait with timeout
  while (( waited < timeout )); do
    local all_done=1
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        all_done=0
        break
      fi
    done
    (( all_done )) && break
    sleep 1
    waited=$((waited + 1))
  done

  # Force-kill any remaining
  for pid in "${pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      warn "cleanup_stop_workers: force-killing PID $pid"
      kill -KILL "$pid" 2>/dev/null || true
      sleep 0.5
    fi
  done

  # Verify termination
  local survivors=0
  for pid in "${pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      warn "cleanup_stop_workers: PID $pid still alive after SIGKILL"
      survivors=$((survivors + 1))
    fi
  done

  if (( survivors > 0 )); then
    warn "cleanup_stop_workers: $survivors direct job(s) could not be stopped — descendants may still be running"
    return 1
  fi

  # Reap direct children
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  debug "cleanup_stop_workers: all direct jobs stopped"
  return 0
}

# cleanup_release MOUNTPOINT
#   Mark a mount as intentionally released (dismantled during build).
#   Removes it from tracking arrays to prevent stale entries.
cleanup_release() {
  local target="${1:?cleanup_release: missing mountpoint}"

  # Cannot release during cleanup
  if (( CLEANUP_RUNNING )); then
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
  if grep -qxF -- "$normalized" <<< "$inventory" 2>/dev/null; then
    warn "cleanup_release: $target is still mounted — cannot release"
    return 1
  fi

  # Ledger: mark released
  if [[ -n "$_LEDGER_RUN_DIR" ]]; then
    cleanup_ledger_mark_released "mount:$normalized" || true
  fi

  # Remove from tracking
  local i
  for (( i=${#CLEANUP_MOUNTS[@]}-1; i>=0; i-- )); do
    if [[ "${CLEANUP_MOUNTS[$i]}" == "$normalized" || "${CLEANUP_MOUNTS[$i]}" == "$target" ]]; then
      unset 'CLEANUP_MOUNTS[i]'
      unset 'CLEANUP_MOUNT_IDS[i]'
      unset 'CLEANUP_MOUNT_LABELS[i]'
      CLEANUP_MOUNTS=("${CLEANUP_MOUNTS[@]}")
      CLEANUP_MOUNT_IDS=("${CLEANUP_MOUNT_IDS[@]}")
      CLEANUP_MOUNT_LABELS=("${CLEANUP_MOUNT_LABELS[@]}")
      debug "cleanup_release: released $target from tracking"
      return 0
    fi
  done

  debug "cleanup_release: $target not found in tracking"
  return 0
}

# cleanup_report_blockers TARGET
#   Report why resources at TARGET could not be cleaned up.
#   Shows remaining mounts, associated loops, and holders.
cleanup_report_blockers() {
  local target="${1:-}"

  if [[ -n "$target" ]]; then
    warn "cleanup_report_blockers: diagnostics for $target"
  fi

  # Report remaining mounts — use exact or descendant matching
  local remaining=""
  remaining="$(_cleanup_read_mount_inventory 2>/dev/null)" || {
    warn "cleanup_report_blockers: cannot read mount inventory"
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
    done <<< "$remaining"
    (( found )) || warn "    (none)"
  elif [[ -n "$remaining" ]]; then
    warn "  All mounts:"
    while IFS="" read -r m; do
      [[ -n "$m" ]] && warn "    $m"
    done <<< "$remaining"
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
      done <<< "$holders"
    else
      warn "  No processes found using $target"
    fi
  elif [[ -n "$target" ]]; then
    warn "  fuser not available — cannot identify processes"
  fi

  return 0
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
    printf '%s\n' "$line" >> "$tmp"
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

  printf '%s\n' "$entry" >> "$_LEDGER_RUN_DIR/resources" || return 1
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

  local tmp="${_LEDGER_RUN_DIR/resources}.tmp.$$"
  : > "$tmp"

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
        >> "$tmp"
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$rid" "$rtype" "$rstate" "$locator_b64" "$identity_b64" "$label_b64" "$last_err" "$timestamp" \
        >> "$tmp"
    fi
  done < "$_LEDGER_RUN_DIR/resources"

  if (( ! found )); then
    warn "_ledger_update_resource: resource $res_id not found"
    rm -f "$tmp"
    return 1
  fi

  sync "$tmp" 2>/dev/null || true
  mv -- "$tmp" "$_LEDGER_RUN_DIR/resources" 2>/dev/null || { rm -f "$tmp"; return 1; }
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
      printf '%s\t%s\n' "$key" "$value" >> "$tmp"
      found=1
    else
      printf '%s\t%s\n' "$k" "$v" >> "$tmp"
    fi
  done < "$filepath"

  if (( ! found )); then
    printf '%s\t%s\n' "$key" "$value" >> "$tmp"
  fi

  sync "$tmp" 2>/dev/null || true
  mv -- "$tmp" "$filepath" 2>/dev/null || { rm -f "$tmp"; return 1; }
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

# cleanup_ledger_prepare RESOURCE_ID TYPE LOCATOR [EXPECTED_IDENTITY] [LABEL]
#   Persist a PREPARED record before resource creation.
cleanup_ledger_prepare() {
  local res_id="${1:?cleanup_ledger_prepare: missing resource id}"
  local res_type="${2:?cleanup_ledger_prepare: missing type (mount|loop)}"
  local locator="${3:?cleanup_ledger_prepare: missing locator}"
  local expected_id="${4:-}"
  local label="${5:-}"

  [[ -n "$_LEDGER_RUN_DIR" ]] || {
    warn "cleanup_ledger_prepare: no active ledger"
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
    warn "cleanup_ledger_prepare: failed to persist PREPARED record for $res_id"
    return 1
  fi

  debug "cleanup_ledger_prepare: persisted PREPARED $res_type $res_id"
  return 0
}

# cleanup_ledger_activate RESOURCE_ID [ACTUAL_IDENTITY]
#   Transition a resource from PREPARED to ACTIVE after successful creation.
cleanup_ledger_activate() {
  local res_id="${1:?cleanup_ledger_activate: missing resource id}"
  local actual_id="${2:-}"

  [[ -n "$_LEDGER_RUN_DIR" ]] || return 1

  _ledger_update_resource "$res_id" "$_LEDGER_RES_ACTIVE" "$actual_id"
}

# cleanup_ledger_mark_releasing RESOURCE_ID
cleanup_ledger_mark_releasing() {
  local res_id="${1:?cleanup_ledger_mark_releasing: missing resource id}"

  [[ -n "$_LEDGER_RUN_DIR" ]] || return 1

  _ledger_update_resource "$res_id" "$_LEDGER_RES_RELEASING" ""
}

# cleanup_ledger_mark_released RESOURCE_ID
cleanup_ledger_mark_released() {
  local res_id="${1:?cleanup_ledger_mark_released: missing resource id}"

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

# cleanup_recover RUN_DIRECTORY
#   Attempt recovery of an incomplete run.
#   Validates ledger, reconciles resources, runs verified teardown.
cleanup_recover() {
  local run_dir="${1:?cleanup_recover: missing run directory}"

  [[ -d "$run_dir" ]] || {
    warn "cleanup_recover: $run_dir does not exist"
    return 1
  }

  # Read manifest
  local manifest="$run_dir/manifest"
  [[ -f "$manifest" ]] || {
    warn "cleanup_recover: no manifest in $run_dir"
    return 1
  }

  local run_state boot_id workspace_path
  run_state="$(grep -m1 '^run_state' "$manifest" | cut -f2)" || run_state=""
  boot_id="$(grep -m1 '^boot_id' "$manifest" | cut -f2)" || boot_id=""
  workspace_path="$(grep -m1 '^workspace_path' "$manifest" | cut -f2)" || workspace_path=""

  # Decode workspace path
  workspace_path="$(printf '%s' "$workspace_path" | base64 -d 2>/dev/null)" || workspace_path=""

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
      return 1
    fi
  fi

  # Read resource records
  local resources_file="$run_dir/resources"
  if [[ ! -f "$resources_file" ]]; then
    debug "cleanup_recover: no resources to recover"
    _ledger_update_manifest_in "$manifest" "run_state" "$_LEDGER_STATE_CLEAN"
    return 0
  fi

  # Get current mount and loop inventories
  local current_mounts current_loops
  current_mounts="$(_cleanup_read_mount_inventory 2>/dev/null)" || current_mounts=""
  current_loops="$(losetup -a 2>/dev/null)" || current_loops=""

  local released=0 preserved=0

  # Process each resource record
  while IFS=$'\t' read -r res_id res_type res_state locator_b64 identity_b64 label_b64 last_err timestamp; do
    [[ -n "$res_id" ]] || continue

    local locator
    locator="$(printf '%s' "$locator_b64" | base64 -d 2>/dev/null)" || locator=""
    local expected_id
    expected_id="$(printf '%s' "$identity_b64" | base64 -d 2>/dev/null)" || expected_id=""

    case "$res_type" in
      mount)
        # Check if mount still exists
        if [[ -n "$locator" ]] && grep -qxF -- "$locator" <<< "$current_mounts" 2>/dev/null; then
          # Mount exists — check identity if same boot
          if [[ "$boot_id" == "$current_boot_id" && -n "$expected_id" ]]; then
            local current_id
            current_id="$(findmnt -rno ID -M "$locator" --kernel 2>/dev/null | head -1)" || current_id=""
            if [[ "$current_id" != "$expected_id" ]]; then
              warn "cleanup_recover: $locator identity changed — preserving"
              preserved=$((preserved + 1))
              continue
            fi
          fi
          # Eligible for cleanup
          debug "cleanup_recover: releasing mount $locator"
          if strict_unmount "$locator" "recovery" 2>/dev/null; then
            released=$((released + 1))
          else
            warn "cleanup_recover: could not unmount $locator — preserving"
            preserved=$((preserved + 1))
          fi
        else
          # Mount absent — already cleaned
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
              preserved=$((preserved + 1))
              continue
            fi
          fi
          # Eligible for cleanup
          debug "cleanup_recover: detaching loop $locator"
          if strict_detach_loop "$locator" 2>/dev/null; then
            released=$((released + 1))
          else
            warn "cleanup_recover: could not detach $locator — preserving"
            preserved=$((preserved + 1))
          fi
        else
          # Loop absent — already cleaned
          released=$((released + 1))
        fi
        ;;
    esac
  done < "$resources_file"

  # Report result
  log "cleanup_recover: released=$released preserved=$preserved"

  if (( preserved > 0 )); then
    warn "cleanup_recover: $preserved resource(s) could not be released — ledger retained"
    _ledger_update_manifest_in "$manifest" "run_state" "$_LEDGER_STATE_BLOCKED"
    return 1
  fi

  _ledger_update_manifest_in "$manifest" "run_state" "$_LEDGER_STATE_CLEAN"
  debug "cleanup_recover: recovery complete"
  return 0
}
