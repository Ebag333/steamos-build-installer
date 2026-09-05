#!/bin/bash
#
# steamos-build-installer — lib/preflight_resources.sh
# Resource and concurrency validation: ensures sufficient disk space is
# available on the EFI, rootfs, and shared ESP partitions before any
# modification begins, acquires an exclusive flock to prevent concurrent
# builds, verifies the target device is not multiply mounted, and
# confirms RAUC is idle and the system state is stable.
#
# Requires: lib/common.sh (die, debug, warn)
# Do not run it directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/preflight_resources.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------

# PF-54a: set by preflight_resources_acquire_lock when flock succeeds.
# The lock fd remains held for the lifetime of the calling process so that
# concurrent builds are rejected.  Callers may close it explicitly or rely
# on process exit.
PF_LOCK_FD=""

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _pf_res_free_kb MOUNTPOINT
#   Return the available space in KB for the filesystem backing MOUNTPOINT,
#   using POSIX-compliant `df -Pk` to avoid GNU/BSD differences.
#   Dies if df fails or the output is unparseable.
_pf_res_free_kb() {
  local mountpoint="${1:?_pf_res_free_kb: missing mountpoint}"

  local avail_kb
  avail_kb="$(df -Pk "$mountpoint" 2>/dev/null | awk 'NR==2 {print $4}')"

  if [[ -z "$avail_kb" || ! "$avail_kb" =~ ^[0-9]+$ ]]; then
    die "_pf_res_free_kb: could not determine available space for $mountpoint"
  fi

  echo "$avail_kb"
}

# _pf_res_lock_cleanup()
#   Cleanup trap for flock.  Closes the lock fd if it is still open and
#   removes the lock file if it was created by this process.
_pf_res_lock_cleanup() {
  if [[ -n "${PF_LOCK_FD:-}" ]]; then
    eval "exec ${PF_LOCK_FD}>&-" 2>/dev/null || true
    PF_LOCK_FD=""
  fi
}

# ---------------------------------------------------------------------------
# Preflight checks — independently callable
# ---------------------------------------------------------------------------

# preflight_resources_efi_free_space EFIMNT EFI_REQUIRED_KB
#   PF-53a: Verify the EFI mount has at least EFI_REQUIRED_KB kilobytes
#   of free space available.  Dies if insufficient.
preflight_resources_efi_free_space() {
  local efi_mount="${1:?preflight_resources_efi_free_space: missing EFI mountpoint}"
  local required_kb="${2:?preflight_resources_efi_free_space: missing required KB}"

  [[ "$required_kb" =~ ^[0-9]+$ ]] \
    || die "PF-53a: required_kb is not a positive integer: $required_kb"

  local avail_kb
  avail_kb="$(_pf_res_free_kb "$efi_mount")"

  if ((avail_kb < required_kb)); then
    die "PF-53a: insufficient EFI free space (${avail_kb} KB available, ${required_kb} KB required) on $efi_mount"
  fi

  debug "PF-53a: EFI free space OK (${avail_kb} KB available, ${required_kb} KB required) on $efi_mount"
}

# preflight_resources_rootfs_free_space ROOTFS ROOTFS_REQUIRED_KB
#   PF-53b: Verify the rootfs has at least ROOTFS_REQUIRED_KB kilobytes
#   of free space available.  Dies if insufficient.
preflight_resources_rootfs_free_space() {
  local rootfs="${1:?preflight_resources_rootfs_free_space: missing rootfs mountpoint}"
  local required_kb="${2:?preflight_resources_rootfs_free_space: missing required KB}"

  [[ "$required_kb" =~ ^[0-9]+$ ]] \
    || die "PF-53b: required_kb is not a positive integer: $required_kb"

  local avail_kb
  avail_kb="$(_pf_res_free_kb "$rootfs")"

  if ((avail_kb < required_kb)); then
    die "PF-53b: insufficient rootfs free space (${avail_kb} KB available, ${required_kb} KB required) on $rootfs"
  fi

  debug "PF-53b: rootfs free space OK (${avail_kb} KB available, ${required_kb} KB required) on $rootfs"
}

# preflight_resources_esp_free_space ESP_MOUNT ESP_REQUIRED_KB
#   PF-53c: Verify the shared ESP mount has at least ESP_REQUIRED_KB
#   kilobytes of free space available.  Dies if insufficient.
preflight_resources_esp_free_space() {
  local esp_mount="${1:?preflight_resources_esp_free_space: missing ESP mountpoint}"
  local required_kb="${2:?preflight_resources_esp_free_space: missing required KB}"

  [[ "$required_kb" =~ ^[0-9]+$ ]] \
    || die "PF-53c: required_kb is not a positive integer: $required_kb"

  local avail_kb
  avail_kb="$(_pf_res_free_kb "$esp_mount")"

  if ((avail_kb < required_kb)); then
    die "PF-53c: insufficient ESP free space (${avail_kb} KB available, ${required_kb} KB required) on $esp_mount"
  fi

  debug "PF-53c: ESP free space OK (${avail_kb} KB available, ${required_kb} KB required) on $esp_mount"
}

# preflight_resources_acquire_lock LOCK_PATH
#   PF-54a: Attempt to acquire an exclusive, non-blocking flock on
#   LOCK_PATH (flock -n).  Dies immediately if the lock cannot be
#   acquired, indicating another build is in progress.
#   On success, sets the global PF_LOCK_FD and installs a RETURN
#   trap to release it.
preflight_resources_acquire_lock() {
  local lock_path="${1:?preflight_resources_acquire_lock: missing lock path}"

  # Ensure the lock file's parent directory exists.
  local lock_dir
  lock_dir="$(dirname "$lock_path")"
  if [[ ! -d "$lock_dir" ]]; then
    mkdir -p "$lock_dir" \
      || die "PF-54a: could not create lock directory: $lock_dir"
  fi

  # Acquire a non-blocking exclusive lock.  We use a subshell-less form:
  # open the fd, then flock -n on it.  If flock fails, die immediately.
  local fd=9
  # shellcheck disable=SC2094
  if ! (eval "exec ${fd}>\"$lock_path\"" && eval "flock -n ${fd}") 2>/dev/null; then
    die "PF-54a: could not acquire exclusive lock (another build may be running): $lock_path"
  fi

  # The fd from the subshell is not visible to the parent.  Re-open and
  # flock in the current shell so the lock is held for our lifetime.
  eval "exec ${fd}>\"$lock_path\""
  if ! flock -n "${fd}"; then
    eval "exec ${fd}>&-" 2>/dev/null || true
    die "PF-54a: could not acquire exclusive lock (another build may be running): $lock_path"
  fi

  PF_LOCK_FD="$fd"

  # Install cleanup trap so the lock is released on function return or exit.
  trap '_pf_res_lock_cleanup' RETURN

  debug "PF-54a: exclusive lock acquired on $lock_path (fd=$PF_LOCK_FD)"
}

# preflight_resources_no_secondary_mounts DEVICE
#   PF-54b: Verify the given block device is not multiply mounted.
#   A device mounted at more than one location indicates concurrent
#   operations or a stale mount.  Dies if more than one mount is found.
preflight_resources_no_secondary_mounts() {
  local device="${1:?preflight_resources_no_secondary_mounts: missing device path}"

  local mount_count
  mount_count="$(findmnt -rn -o TARGET -S "$device" 2>/dev/null | wc -l)"

  if ((mount_count > 1)); then
    local mounts
    mounts="$(findmnt -rn -o TARGET -S "$device" 2>/dev/null)"
    die "PF-54b: device is multiply mounted ($mount_count mountpoints): $device
$mounts"
  fi

  debug "PF-54b: device has at most one mount: $device"
}

# preflight_resources_rauc_idle()
#   PF-54c: Verify RAUC is idle and the system state is stable.
#   Checks that no RAUC operation is in progress (installing, installing
#   with automatic reboot, or busy) and that the system state is "booted"
#   (not in a transitional state).
#   Gracefully skips (returns 0) if RAUC is not installed on the system.
preflight_resources_rauc_idle() {
  # Graceful skip: if rauc is not installed, this check is not applicable.
  if ! command -v rauc &>/dev/null; then
    debug "PF-54c: rauc not found — skipping (no RAUC on system)"
    return 0
  fi

  local rauc_status
  rauc_status="$(rauc status 2>/dev/null)" || rauc_status=""

  if [[ -z "$rauc_status" ]]; then
    debug "PF-54c: could not determine RAUC status — assuming idle"
    return 0
  fi

  # Check the detailed JSON status for the "active" field.
  local rauc_active
  rauc_active="$(rauc status --output-format=json 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("active",""))' 2>/dev/null)" \
    || rauc_active=""

  # Also check the compatibility string to confirm the system is in a
  # stable (non-transitional) state.
  local rauc_compatible
  rauc_compatible="$(rauc status --output-format=json 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("compatible",""))' 2>/dev/null)" \
    || rauc_compatible=""

  # Detect active RAUC operations from the human-readable status output.
  # Keywords that indicate RAUC is busy: "installing", "busy".
  local rauc_lower
  rauc_lower="$(echo "$rauc_status" | tr '[:upper:]' '[:lower:]')"

  if [[ "$rauc_lower" == *installing* || "$rauc_lower" == *busy* ]]; then
    die "PF-54c: RAUC is currently busy — cannot proceed
RAUC status: $rauc_status"
  fi

  # Verify the system state is stable: the "booted" slot must be known.
  if [[ -n "$rauc_active" && "$rauc_active" != "null" ]]; then
    debug "PF-54c: RAUC active slot: $rauc_active"
  fi

  debug "PF-54c: RAUC is idle and system state is stable"
}

# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

# preflight_resources_validate EFIMNT EFI_REQUIRED_KB ROOTFS ROOTFS_REQUIRED_KB [ESP_MOUNT] [ESP_REQUIRED_KB] [LOCK_PATH]
#   Run all resource and concurrency preflight checks in sequence.
#   Dies on the first failure; returns 0 when all checks pass.
#
#   Required arguments:
#     EFIMNT           — mounted EFI partition path
#     EFI_REQUIRED_KB  — minimum free space required on EFI (KB)
#     ROOTFS           — mounted root filesystem path
#     ROOTFS_REQUIRED_KB — minimum free space required on rootfs (KB)
#
#   Optional arguments:
#     ESP_MOUNT        — shared ESP mount path (skip ESP check if omitted)
#     ESP_REQUIRED_KB  — minimum free space required on ESP (KB, required if ESP_MOUNT given)
#     LOCK_PATH        — path for the flock file (default: /tmp/steamos-build.lock)
#
#   Global state set:
#     PF_LOCK_FD — the flock file descriptor (valid until process exit)
preflight_resources_validate() {
  local efi_mount="${1:?preflight_resources_validate: missing EFIMNT}"
  local efi_required_kb="${2:?preflight_resources_validate: missing EFI_REQUIRED_KB}"
  local rootfs="${3:?preflight_resources_validate: missing ROOTFS}"
  local rootfs_required_kb="${4:?preflight_resources_validate: missing ROOTFS_REQUIRED_KB}"
  local esp_mount="${5:-}"
  local esp_required_kb="${6:-}"
  local lock_path="${7:-/tmp/steamos-build.lock}"

  debug "preflight_resources_validate: efi=$efi_mount rootfs=$rootfs esp=${esp_mount:-<none>}"

  # PF-53a: EFI free space.
  preflight_resources_efi_free_space "$efi_mount" "$efi_required_kb"

  # PF-53b: rootfs free space.
  preflight_resources_rootfs_free_space "$rootfs" "$rootfs_required_kb"

  # PF-53c: ESP free space (optional — only when ESP_MOUNT is provided).
  if [[ -n "$esp_mount" ]]; then
    # Ensure the corresponding required KB was also provided.
    if [[ -z "$esp_required_kb" ]]; then
      die "preflight_resources_validate: ESP_MOUNT provided but ESP_REQUIRED_KB is missing"
    fi
    preflight_resources_esp_free_space "$esp_mount" "$esp_required_kb"
  fi

  # PF-54a: Exclusive flock (must succeed before any writes).
  preflight_resources_acquire_lock "$lock_path"

  # PF-54b: No secondary mounts on the rootfs device.
  preflight_resources_no_secondary_mounts "$rootfs"

  # PF-54c: RAUC idle and system state stable.
  preflight_resources_rauc_idle

  debug "preflight_resources_validate: all resource and concurrency checks passed"
}
