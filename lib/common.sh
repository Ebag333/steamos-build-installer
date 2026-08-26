#!/bin/bash
#
# steamos-nvidia-installer — lib/common.sh
# Shared helpers: logging/failure reporting, loop/mount primitives, and
# builder cleanup/payload helpers. Sourced by the build backend and repatch.
# Do not run it directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/common.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Shared logging/failure framework.  Callers may set these before sourcing:
#   LOG_TAG      short human-readable prefix (default: nvidia-usb)
#   LOGGER_TAG   systemd-journal tag (default: steamos-nvidia-build)
#   LOG_COLOR    1 for colored terminal prefixes, 0 for plain text
#   RUN_LOG      optional persistent log path included in failure headlines
#
# Callers may also define these optional hooks before or after sourcing:
#   failure_journal_context  -> prints compact caller-specific journal context
#   failure_snapshot_extra   -> emits caller-specific diagnostic sections
: "${LOG_TAG:=nvidia-usb}"
: "${LOGGER_TAG:=steamos-nvidia-build}"
: "${LOG_COLOR:=1}"
: "${CURRENT_STEP:=startup}"
: "${FAILURE_REPORTED:=0}"

log() {
  if [[ "${LOG_COLOR:-1}" -eq 1 ]]; then
    printf '\e[1;35m[%s]\e[0m %s\n' "$LOG_TAG" "$*"
  else
    printf '[%s] %s\n' "$LOG_TAG" "$*"
  fi
}

warn() {
  if [[ "${LOG_COLOR:-1}" -eq 1 ]]; then
    printf '\e[1;33m[%s] WARNING:\e[0m %s\n' "$LOG_TAG" "$*" >&2
  else
    printf '[%s] WARNING: %s\n' "$LOG_TAG" "$*" >&2
  fi
}

step() {
  CURRENT_STEP="$*"
  log "STEP: $CURRENT_STEP"
  logger -t "$LOGGER_TAG" -- "STEP: $CURRENT_STEP" 2>/dev/null || true
}

failure_snapshot() {
  local rc="${1:?failure_snapshot: missing rc}"
  local line="${2:?failure_snapshot: missing line}"
  local cmd="${3:-}"
  local reason="${4:-}"
  local journal_cmd journal_reason journal_context=""

  warn "FAILURE"
  warn "  rc:      $rc"
  warn "  step:    ${CURRENT_STEP:-unknown}"
  warn "  line:    $line"
  warn "  command: $cmd"
  [[ -n "$reason" ]] && warn "  reason:  $reason"

  journal_cmd="${cmd//$'\n'/ }"
  journal_reason="${reason//$'\n'/ }"
  journal_cmd="${journal_cmd:0:300}"
  journal_reason="${journal_reason:0:300}"

  if declare -F failure_journal_context >/dev/null 2>&1; then
    journal_context="$(failure_journal_context 2>/dev/null || true)"
    journal_context="${journal_context//$'\n'/ }"
    journal_context="${journal_context:0:300}"
  fi

  logger -t "$LOGGER_TAG" -- \
    "FAIL rc=$rc step='${CURRENT_STEP:-unknown}' line=$line${journal_context:+ $journal_context} command='$journal_cmd' reason='${journal_reason:-unspecified}' log='${RUN_LOG:-<stdout>}'" \
    2>/dev/null || true

  # Let the caller add domain-specific state (RAUC/slot state for repatch,
  # image/build state for the builder, etc.) without coupling common.sh to it.
  if declare -F failure_snapshot_extra >/dev/null 2>&1; then
    failure_snapshot_extra "$rc" "$line" "$cmd" "$reason" || true
  fi

  echo
  echo "=== MOUNTS ==="
  findmnt 2>&1 || true

  echo
  echo "=== LOOP DEVICES ==="
  losetup -a 2>&1 || true

  echo
  echo "=== SPACE ==="
  df -h /home 2>&1 || df -h 2>&1 || true
}

report_failure() {
  local rc="${1:?report_failure: missing rc}"
  local line="${2:?report_failure: missing line}"
  local cmd="${3:-}"
  local reason="${4:-}"

  # A manually invoked die() might follow a command that returned 0.
  ((rc != 0)) || rc=1

  # Prevent ERR + die, or failures inside diagnostics, from producing
  # multiple snapshots.
  if ((FAILURE_REPORTED)); then
    exit "$rc"
  fi
  FAILURE_REPORTED=1

  trap - ERR
  set +e

  failure_snapshot "$rc" "$line" "$cmd" "$reason"
  exit "$rc"
}

on_err() {
  local rc=$?
  local line="${BASH_LINENO[0]:-${LINENO}}"
  local cmd="$BASH_COMMAND"

  report_failure \
    "$rc" \
    "$line" \
    "$cmd" \
    "unhandled command failure"
}

die() {
  # Capture $? immediately so `cmd || die "..."` retains cmd's exit code.
  local rc=$?
  local reason="$*"
  local line="${BASH_LINENO[0]:-${LINENO}}"

  ((rc != 0)) || rc=1

  report_failure \
    "$rc" \
    "$line" \
    "die: $reason" \
    "$reason"
}

# ERR inheritance is required for failures originating inside functions,
# command substitutions, and subshells.  This is already enabled by repatch;
# enabling it here gives the builder the same enriched failure handling.
set -E
trap on_err ERR

# ensure_steamos_nvidia_dirs [BASE_PATH]
#   Create the persistent /home/.steamos-nvidia tree (logs + recovery).
#   Idempotent — safe to call repeatedly; never stomps existing dirs.
#   BASE_PATH defaults to /home; pass $HOMEMNT during image construction.
ensure_steamos_nvidia_dirs() {
  local base="${1:-/home}"
  local root="$base/.steamos-nvidia"

  mkdir -p "$root/logs" "$root/recovery"
  chmod 777 "$root/recovery"
}

# ---------------------------------------------------------------------------
# Script Directory Resolution
# ---------------------------------------------------------------------------
# Resolve the steamos-nvidia script directory.
# Prefers /home/.steamos-nvidia (writable, latest scripts),
# falls back to /usr/lib/steamos-nvidia (immutable, build-time).
#
# Args: $1 = (optional) explicit path to check first
# Output: path to the script directory
# Returns: 0 if found, 1 if neither exists

resolve_nvidia_dir() {
  local explicit="${1:-}"

  if [[ -n "$explicit" && -d "$explicit/lib" ]]; then
    echo "$explicit"
    return 0
  fi

  if [[ -d "/home/.steamos-nvidia/lib" ]]; then
    echo "/home/.steamos-nvidia"
    return 0
  fi

  if [[ -d "/usr/lib/steamos-nvidia" ]]; then
    echo "/usr/lib/steamos-nvidia"
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# Project Persistence (Self-Heal)
# ---------------------------------------------------------------------------
# Persist a copy of the project into /home/.steamos-nvidia/ so users can
# re-run from the device without caching the original scripts.
#
# Self-heal semantics:
#   - Same version → no-op (skip copy)
#   - Newer version → overwrite changed files
#   - Partially deleted/damaged → restore missing files
#   - Never deletes user files (logs/, recovery/)

# Compute a version identifier for the current project tree.
# Uses git describe if available, otherwise hashes key files.
_get_project_version() {
  local src="${1:?_get_project_version: missing source dir}"

  # Prefer git describe (includes tag + commit hash)
  if command -v git &>/dev/null && [[ -d "$src/.git" ]]; then
    git -C "$src" describe --always --dirty 2>/dev/null && return 0
  fi

  # Fallback: hash of key files that change with releases
  local hash_input=""
  for f in "$src/steamos-nvidia.sh" "$src/lib/common.sh" "$src/lib/backend.sh" \
    "$src/lib/library-loader.sh" "$src/lib/configs/customizations.conf"; do
    [[ -f "$f" ]] && hash_input+="$(cat "$f")"
  done

  if [[ -n "$hash_input" ]]; then
    echo "$hash_input" | md5sum | cut -d' ' -f1
  else
    date +%s
  fi
}

# Persist project files into /home/.steamos-nvidia/ with self-heal.
# Args: $1 = source dir (project root), $2 = (optional) target base (default /home)
#
# Copies: steamos-nvidia.sh, lib/, tools/, recipes/, build.conf, LICENSE
# Skips: .git/, .idea/, test-*.sh, docs/, __pycache__/
# Preserves: logs/, recovery/, .version
persist_project_files() {
  local src="${1:?persist_project_files: missing source dir}"
  local base="${2:-/home}"
  local dest="$base/.steamos-nvidia"
  local version_file="$dest/.version"

  # Compute current version
  local current_version
  current_version="$(_get_project_version "$src")"

  # Check if persisted version matches
  if [[ -f "$version_file" ]]; then
    local persisted_version
    persisted_version="$(cat "$version_file")"
    if [[ "$persisted_version" == "$current_version" ]]; then
      log "Project already persisted at $dest (version $current_version)"
      return 0
    fi
    log "Project version changed ($persisted_version → $current_version) — updating"
  else
    log "Persisting project to $dest"
  fi

  # Ensure target directory exists
  mkdir -p "$dest"

  # Sync project files using rsync if available, otherwise cp
  if command -v rsync &>/dev/null; then
    rsync -a --delete \
      --exclude='.git/' \
      --exclude='.idea/' \
      --exclude='test-*.sh' \
      --exclude='docs/' \
      --exclude='__pycache__/' \
      --exclude='logs/' \
      --exclude='recovery/' \
      --exclude='.version' \
      "$src/" "$dest/" \
      || {
        warn "rsync failed — falling back to cp"
        _persist_project_files_cp "$src" "$dest"
      }
  else
    _persist_project_files_cp "$src" "$dest"
  fi

  # Write version stamp
  echo "$current_version" >"$version_file"
  log "Project persisted (version $current_version)"
}

# Fallback copy when rsync is not available.
# Copies specific files/dirs, skips known exclusions.
_persist_project_files_cp() {
  local src="${1:?_persist_project_files_cp: missing source}"
  local dest="${2:?_persist_project_files_cp: missing dest}"

  # Copy top-level files
  local f
  for f in steamos-nvidia.sh steamos-recovery-update-diagnostics.sh build.conf LICENSE README.md; do
    [[ -f "$src/$f" ]] && cp -f "$src/$f" "$dest/$f"
  done

  # Copy directories
  local d
  for d in lib tools recipes; do
    [[ -d "$src/$d" ]] && cp -a "$src/$d" "$dest/$d"
  done
}

# Ensure the project is persisted to /home/.steamos-nvidia/.
# Entry point for all pipelines — handles source detection and calls persist.
# Args: $1 = (optional) source dir (default: $SCRIPT_DIR)
#        $2 = (optional) target base (default: /home)
ensure_project_persisted() {
  local src="${1:-${SCRIPT_DIR:-}}"
  local base="${2:-/home}"

  if [[ -z "$src" || ! -d "$src/lib" ]]; then
    warn "Cannot determine project source directory — skipping persistence"
    return 0
  fi

  ensure_steamos_nvidia_dirs "$base"
  persist_project_files "$src" "$base"
}

# curl_retry ATTEMPTS [CURL_ARGS...]
#   Run curl with retry on transient failures (network errors, HTTP 5xx).
curl_retry() {
  local attempts="${1:?curl_retry: missing attempt count}"
  shift
  local i
  for ((i = 1; i <= attempts; i++)); do
    if curl "$@"; then
      return 0
    fi
    ((i < attempts)) && {
      warn "curl attempt $i failed, retrying..."
      sleep 2
    }
  done
  warn "curl failed after $attempts attempts"
  return 1
}

# Weighted progress tracking.
# Weights are proportional to expected wall-clock time (not step count).
# progress_emit "step_name" at each major milestone; the frontend parses
# @@PROGRESS:XX@@ markers from the log stream to drive a yad progress bar.
_PROGRESS_TOTAL=97
_PROGRESS_SO_FAR=0

progress_emit() {
  local step="${1:?progress_emit: missing step name}"
  local weight=0
  case "$step" in
    decompress) weight=20 ;;
    create_fs) weight=5 ;;
    write_fs) weight=2 ;;
    mount) weight=1 ;;
    resolve_driver) weight=8 ;;
    setup_chroot) weight=5 ;;
    install_headers) weight=5 ;;
    install_driver) weight=25 ;;
    build_hid) weight=2 ;;
    install_hw) weight=15 ;;
    copy_payload) weight=3 ;;
    configure_grub) weight=3 ;;
    patch_installer) weight=1 ;;
    finalize) weight=2 ;;
  esac
  if ((weight > 0)); then
    _PROGRESS_SO_FAR=$((_PROGRESS_SO_FAR + weight))
    ((_PROGRESS_SO_FAR > _PROGRESS_TOTAL)) && _PROGRESS_SO_FAR=$_PROGRESS_TOTAL
    local pct=$((_PROGRESS_SO_FAR * 100 / _PROGRESS_TOTAL))
    printf '%s\n' "@@PROGRESS:$pct@@"
  fi
}

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

  [[ -e "$sys" ]] || return 0

  # Wait up to 15 seconds for the ext4 superblock to release.
  # The jbd2 journal thread can hold it for several seconds after unmount
  # while flushing dirty metadata.
  for ((i = 0; i < 150; i++)); do
    [[ ! -e "$sys" ]] && return 0
    # After 2 seconds, try flushing block device buffers to speed up release
    if ((i == 20)); then
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
      sed -n '1p;/^State:/p;/^voluntary/p' "/proc/$journal_pid/status" 2>/dev/null \
        | while IFS= read -r line; do warn "    $line"; done

      # Kernel stack trace — shows the exact call chain
      if [[ -r "/proc/$journal_pid/stack" ]]; then
        local _stack
        _stack="$(cat "/proc/$journal_pid/stack" 2>/dev/null || true)"
        if [[ -n "$_stack" ]]; then
          warn "    kernel stack:"
          printf '%s\n' "$_stack" | while IFS= read -r line; do warn "      $line"; done
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
    printf '%s\n' "$_loop_refs" | while IFS= read -r line; do warn "    $line"; done
  fi

  # Check for any remaining mount references
  local _mount_refs
  _mount_refs="$(findmnt -rn -S "$loop" 2>/dev/null || true)"
  if [[ -n "$_mount_refs" ]]; then
    warn "  Remaining mount references for $loop:"
    printf '%s\n' "$_mount_refs" | while IFS= read -r line; do warn "    $line"; done
  fi

  # Ext4 sysfs state
  if [[ -d "$sys" ]]; then
    local _ext4_state
    _ext4_state="$(find "$sys" -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | head -20)"
    if [[ -n "$_ext4_state" ]]; then
      warn "  ext4 sysfs entries for $name:"
      printf '%s\n' "$_ext4_state" | while IFS= read -r entry; do warn "    $entry"; done
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

  warn "$loop is still attached after losetup -d"
  losetup -l -O NAME,AUTOCLEAR,RO,BACK-FILE "$loop" >&2 2>/dev/null || true
  return 1
}

# Tear down everything mounted/created on OUR loop device + the overlay, and
# drop the udisks guard rule. Idempotent — safe to run twice (EXIT trap).
cleanup() {
  local _had_e=0
  [[ -o errexit ]] && _had_e=1
  set +e

  local rc=0
  local kid m

  # Stop background children owned by this shell.
  for kid in $(jobs -p 2>/dev/null); do
    kill "$kid" 2>/dev/null || true
    wait "$kid" 2>/dev/null || true
  done

  # ------------------------------------------------------------
  # Overlay must disappear before its lower filesystem.
  # ------------------------------------------------------------
  if ! overlay_cleanup; then
    warn "cleanup: overlay teardown incomplete"
    warn "cleanup: refusing to unmount main image filesystems underneath it"
    rc=1
  else
    # ----------------------------------------------------------
    # Main image filesystem mounts.
    # ----------------------------------------------------------
    for m in "${HOMEMNT:-}" "${EFIMNT:-}" "${MNT:-}"; do
      [[ -n "$m" ]] || continue

      if mountpoint -q "$m" 2>/dev/null; then
        if ! strict_unmount "$m" "main image filesystem"; then
          rc=1
        fi
      fi
    done

    # ----------------------------------------------------------
    # Main image loop.
    # ----------------------------------------------------------
    if ((rc == 0)) && [[ -n "${LOOPDEV:-}" ]]; then
      while IFS= read -r m; do
        [[ -n "$m" ]] || continue

        if ! strict_unmount "$m" "remaining mount from $LOOPDEV"; then
          rc=1
        fi
      done < <(mounts_for_loop "$LOOPDEV")

      if ((rc == 0)); then
        strict_detach_loop "$LOOPDEV" || rc=1
      fi
    fi
  fi

  # Udev rule itself is safe to remove regardless of mount cleanup result.
  if [[ -n "${UDEV_RULE:-}" && -f "$UDEV_RULE" ]]; then
    rm -f "$UDEV_RULE"
    udevadm control --reload 2>/dev/null || true
  fi

  # ------------------------------------------------------------
  # Final diagnostics.
  # ------------------------------------------------------------
  if [[ -n "${OVL_IMG:-}" ]]; then
    local remaining
    remaining="$(loops_for_file "$OVL_IMG")"

    if [[ -n "$remaining" ]]; then
      warn "cleanup: overlay workspace still attached:"
      while IFS= read -r m; do
        [[ -n "$m" ]] && warn "  $m"
      done <<<"$remaining"
      rc=1
    fi
  fi

  if [[ -n "${LOOPDEV:-}" ]] \
    && losetup "$LOOPDEV" >/dev/null 2>&1; then
    warn "cleanup: main image loop still attached: $LOOPDEV"
    losetup "$LOOPDEV" >&2 2>/dev/null || true
    rc=1
  fi

  # ------------------------------------------------------------
  # Remove build workspace (always, even on failure).
  # ------------------------------------------------------------
  if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then
    log "Cleaning up build workspace: $WORKDIR"
    rm -rf "$WORKDIR" 2>/dev/null || warn "cleanup: could not remove $WORKDIR"
  fi

  [[ "$_had_e" -eq 1 ]] && set -e
  return "$rc"
}

# Diff the chroot's new packages against the pristine image db to get the list
# of files that actually ship, then size-check it against available rootfs space.
compute_payload() {
  # "Before" = the pristine image's own pacman db (read directly, host-side) —
  # NOT the chroot's, whose db carries installs cached in the overlay upper
  # layer from previous runs and would make the diff come out empty.
  #
  # Use pacman -Q (name + version) instead of -Qq (name only) so that
  # version upgrades are detected — e.g. nvidia-utils 580→590 would otherwise
  # be invisible to comm since both lines contain the same package name.
  pacman -Q --dbpath "$MNT/usr/lib/holo/pacmandb" | LC_ALL=C sort >"$WORKDIR/pkgs-before.txt"
  in_chroot "pacman -Q" | LC_ALL=C sort >"$WORKDIR/pkgs-after.txt"

  # New or upgraded packages minus build-only toolchain = what ships in the image.
  # The optional extra-exclude file is populated by build modules (e.g. AoTofu)
  # that record their own transitive build-only dependencies.
  compute_new_pkgs "$WORKDIR/pkgs-before.txt" "$WORKDIR/pkgs-after.txt" "$WORKDIR/build-only-exclusions.txt"
  if [[ ${#NEW_PKGS[@]} -eq 0 ]]; then
    log "No runtime package changes — module-only payload"
  else
    log "Payload packages: ${NEW_PKGS[*]}"
  fi

  FILELIST="$WORKDIR/payload-files.txt"
  generate_payload_filelist "$FILELIST" "${NEW_PKGS[@]}"

  if [[ $TRIM_CUDA -eq 1 ]]; then
    log "Trimming CUDA/OpenCL/NVVM/OptiX libraries"
    grep -Ev 'libcuda|libcudadebugger|libnvidia-nvvm|libnvidia-opencl|libnvoptix|nvidia-cuda-mps|OpenCL' \
      "$FILELIST" >"$FILELIST.trim" && mv "$FILELIST.trim" "$FILELIST"
  fi
  sed 's|^/||' "$FILELIST" >"$FILELIST.rel"

  # Space check: pacman -Qlq lists directories too — size only files/symlinks.
  # If no runtime packages changed, PAYLOAD_MB is 0 (module-only update).
  if [[ -s "$FILELIST" ]]; then
    PAYLOAD_MB="$(
      set +o pipefail
      cd "$MERGED" && while IFS= read -r p; do
        if [[ -f "$p" || -L "$p" ]]; then printf '%s\0' "$p"; fi
      done <"$FILELIST.rel" | { du -scm --no-dereference --files0-from=- 2>/dev/null || true; } | tail -1 | cut -f1
    )"
    [[ "$PAYLOAD_MB" =~ ^[0-9]+$ ]] || die "Could not size the payload"
  else
    PAYLOAD_MB=0
  fi
  MODULES_MB="$(du -sm "$UPPER/usr/lib/modules/$KVER/updates" | cut -f1)"
  AVAIL_MB="$(df -m --output=avail "$MNT" | tail -1 | tr -d ' ')"
  log "Payload ≈ ${PAYLOAD_MB} MB files + ${MODULES_MB} MB modules (before btrfs zstd); rootfs has ${AVAIL_MB} MB free"
  if ((PAYLOAD_MB + MODULES_MB > AVAIL_MB * 2)); then # zstd roughly halves it
    die "Not enough space in rootfs. Rerun with --trim-cuda."
  fi
}
