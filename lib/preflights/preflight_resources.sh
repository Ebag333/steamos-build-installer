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
# concurrent builds are rejected.  Callers should call
# _pf_res_lock_cleanup explicitly or rely on process exit.
PF_LOCK_FD=""

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _pf_res_free_kb MOUNTPOINT
#   Return the available space in 1K-blocks (KiB) for the filesystem
#   backing MOUNTPOINT, using POSIX-compliant `df -Pk`.
#   NOTE: df -Pk reports 1K-blocks, not decimal kilobytes.
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

# _pf_res_verify_mountpoint MOUNTPOINT
#   Verify the path is a real mountpoint (not just a directory on the host fs).
#   Dies if the path is not a mountpoint.
_pf_res_verify_mountpoint() {
  local mountpoint="${1:?_pf_res_verify_mountpoint: missing mountpoint}"

  if [[ ! -d "$mountpoint" ]]; then
    die "_pf_res_verify_mountpoint: path does not exist: $mountpoint"
  fi

  if ! mountpoint -q "$mountpoint" 2>/dev/null; then
    die "_pf_res_verify_mountpoint: path is not a mountpoint: $mountpoint"
  fi
}

# _pf_res_lock_cleanup
#   Release the flock. Called explicitly by the pipeline cleanup or process exit.
#   Does NOT remove the lock file (persistent lock is intentional).
_pf_res_lock_cleanup() {
  if [[ -n "${PF_LOCK_FD:-}" ]]; then
    # Close the file descriptor. eval is safe here since PF_LOCK_FD is a validated integer.
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
#
#   NOTE: Space requirements are in 1K-blocks (KiB), not decimal KB.
#   Callers must derive requirements from the planned artifact manifest:
#     new staged artifacts + retained old artifacts + temporary output + safety margin
#   For FAT (EFI/ESP), account for cluster allocation overhead.
preflight_resources_efi_free_space() {
  local efi_mount="${1:?preflight_resources_efi_free_space: missing EFI mountpoint}"
  local required_kb="${2:?preflight_resources_efi_free_space: missing required KB}"

  [[ "$required_kb" =~ ^[1-9][0-9]*$ ]] \
    || die "PF-53a: required_kb is not a positive integer: $required_kb"

  _pf_res_verify_mountpoint "$efi_mount"

  local avail_kib
  if ! avail_kib="$(_pf_res_free_kb "$efi_mount")"; then
    die "PF-53a: could not determine available space for $efi_mount"
  fi

  if ((avail_kib < required_kb)); then
    die "PF-53a: insufficient EFI free space (${avail_kib} KiB available, ${required_kb} KiB required) on $efi_mount"
  fi

  debug "PF-53a: EFI free space OK (${avail_kib} KiB available, ${required_kb} KiB required) on $efi_mount"
}

# preflight_resources_rootfs_free_space ROOTFS ROOTFS_REQUIRED_KB
#   PF-53b: Verify the rootfs has at least ROOTFS_REQUIRED_KB kilobytes
#   of free space available.  Dies if insufficient.
#
#   NOTE: Space requirements are in 1K-blocks (KiB), not decimal KB.
#   Callers must derive requirements from the planned artifact manifest:
#     new staged artifacts + retained old artifacts + temporary output + safety margin
preflight_resources_rootfs_free_space() {
  local rootfs="${1:?preflight_resources_rootfs_free_space: missing rootfs mountpoint}"
  local required_kb="${2:?preflight_resources_rootfs_free_space: missing required KB}"

  [[ "$required_kb" =~ ^[1-9][0-9]*$ ]] \
    || die "PF-53b: required_kb is not a positive integer: $required_kb"

  _pf_res_verify_mountpoint "$rootfs"

  local avail_kib
  if ! avail_kib="$(_pf_res_free_kb "$rootfs")"; then
    die "PF-53b: could not determine available space for $rootfs"
  fi

  if ((avail_kib < required_kb)); then
    die "PF-53b: insufficient rootfs free space (${avail_kib} KiB available, ${required_kb} KiB required) on $rootfs"
  fi

  debug "PF-53b: rootfs free space OK (${avail_kib} KiB available, ${required_kb} KiB required) on $rootfs"
}

# preflight_resources_esp_free_space ESP_MOUNT ESP_REQUIRED_KB
#   PF-53c: Verify the shared ESP mount has at least ESP_REQUIRED_KB
#   kilobytes of free space available.  Dies if insufficient.
#
#   NOTE: Space requirements are in 1K-blocks (KiB), not decimal KB.
#   Callers must derive requirements from the planned artifact manifest:
#     new staged artifacts + retained old artifacts + temporary output + safety margin
#   For FAT (ESP), account for cluster allocation overhead.
preflight_resources_esp_free_space() {
  local esp_mount="${1:?preflight_resources_esp_free_space: missing ESP mountpoint}"
  local required_kb="${2:?preflight_resources_esp_free_space: missing required KB}"

  [[ "$required_kb" =~ ^[1-9][0-9]*$ ]] \
    || die "PF-53c: required_kb is not a positive integer: $required_kb"

  _pf_res_verify_mountpoint "$esp_mount"

  local avail_kib
  if ! avail_kib="$(_pf_res_free_kb "$esp_mount")"; then
    die "PF-53c: could not determine available space for $esp_mount"
  fi

  if ((avail_kib < required_kb)); then
    die "PF-53c: insufficient ESP free space (${avail_kib} KiB available, ${required_kb} KiB required) on $esp_mount"
  fi

  debug "PF-53c: ESP free space OK (${avail_kib} KiB available, ${required_kb} KiB required) on $esp_mount"
}

# preflight_resources_acquire_lock [LOCK_PATH]
#   PF-54a: Attempt to acquire an exclusive, non-blocking flock.
#   Uses a fixed, protected path under /run/lock/steamos-build-installer/.
#   The lock is held for the lifetime of the calling process (no RETURN trap).
#   Callers may close PF_LOCK_FD explicitly or rely on process exit.
#
#   LOCK_PATH is optional; defaults to /run/lock/steamos-build-installer/build.lock
#
#   Sets global PF_LOCK_FD on success. Dies on failure.
preflight_resources_acquire_lock() {
  local lock_path="${1:-/run/lock/steamos-build-installer/build.lock}"

  # Ensure the lock directory exists and is root-owned.
  local lock_dir
  lock_dir="$(dirname "$lock_path")"
  if [[ ! -d "$lock_dir" ]]; then
    mkdir -p "$lock_dir" \
      || die "PF-54a: could not create lock directory: $lock_dir"
    chmod 0755 "$lock_dir" 2>/dev/null || true
  fi

  # Use a Bash dynamic file descriptor (no eval, no fixed FD that could collide).
  # Auto-allocate: exec {fd}> opens a new fd and assigns its number.
  local fd
  exec {fd}>"$lock_path" \
    || die "PF-54a: could not open lock file: $lock_path"

  # Attempt non-blocking exclusive flock.
  if ! flock -n "$fd"; then
    exec {fd}>&- 2>/dev/null || true
    die "PF-54a: could not acquire exclusive lock (another build may be running): $lock_path"
  fi

  PF_LOCK_FD="$fd"

  # NO RETURN trap — the lock is held until process exit or explicit release.
  # The caller (pipeline) is responsible for cleanup.

  debug "PF-54a: exclusive lock acquired on $lock_path (fd=$PF_LOCK_FD)"
}

# _pf_res_resolve_device DEVICE
#   Resolve a device path to its canonical form.
#   Returns 0 on success (prints resolved path), 1 on failure.
_pf_res_resolve_device() {
  local device="${1:?_pf_res_resolve_device: missing device path}"

  local resolved
  resolved="$(realpath "$device" 2>/dev/null)" \
    || return 1

  [[ -n "$resolved" ]] \
    || return 1

  echo "$resolved"
}

# preflight_resources_no_secondary_mounts DEVICE EXPECTED_MOUNTPOINT
#   PF-54b: Verify the given block device is mounted at exactly the expected
#   location and not multiply mounted. A device mounted at unexpected locations
#   indicates concurrent operations, bind mounts, or stale mounts.
#   Dies if the mount topology doesn't match expectations.
preflight_resources_no_secondary_mounts() {
  local device="${1:?preflight_resources_no_secondary_mounts: missing device path}"
  local expected_mount="${2:?preflight_resources_no_secondary_mounts: missing expected mountpoint}"

  local canonical_device
  if ! canonical_device="$(_pf_res_resolve_device "$device")"; then
    die "PF-54b: could not resolve device: $device"
  fi

  # Find ALL mountpoints for this device.
  local mounts
  mounts="$(findmnt -rn -o TARGET -S "$canonical_device" 2>/dev/null)" || mounts=""

  if [[ -z "$mounts" ]]; then
    # Device has no mounts -- this could be valid (unmounted device) or a findmnt failure.
    # If the caller expects it to be mounted, this is a problem.
    debug "PF-54b: device has no mounts: $canonical_device"
    return 0
  fi

  local mount_count
  mount_count="$(echo "$mounts" | wc -l)"

  if ((mount_count > 1)); then
    die "PF-54b: device is multiply mounted ($mount_count mountpoints): $canonical_device
$mounts"
  fi

  # Verify the single mount is at the expected location.
  local actual_mount
  actual_mount="$(echo "$mounts" | head -1)"

  if [[ "$actual_mount" != "$expected_mount" ]]; then
    die "PF-54b: device is mounted at unexpected location ($actual_mount, expected $expected_mount): $canonical_device"
  fi

  debug "PF-54b: device mount topology verified: $canonical_device -> $expected_mount"
}

# preflight_resources_rauc_idle [SCENARIO]
#   PF-54c: Verify RAUC is idle and the system state is stable.
#
#   SCENARIO determines behavior when RAUC is unavailable:
#     "build"      -- RAUC not applicable; skip gracefully
#     "flashless"  -- RAUC must be present and readable; failure is fatal
#     "recovery"   -- RAUC must be present and readable; failure is fatal
#     "live"       -- RAUC must be present and readable; failure is fatal
#     "" (default) -- RAUC not applicable; skip gracefully (backward compat)
#
#   When RAUC is present, requires:
#     - rauc status succeeds (D-Bus accessible)
#     - Operation state is "idle" (no install in progress)
#     - Booted slot is known
preflight_resources_rauc_idle() {
  local scenario="${1:-}"

  # Graceful skip for build scenarios where RAUC is not installed.
  if ! command -v rauc &>/dev/null; then
    case "$scenario" in
      flashless|recovery|live)
        die "PF-54c: rauc is required for '$scenario' scenario but not found on system"
        ;;
      *)
        debug "PF-54c: rauc not found -- skipping (no RAUC on system)"
        return 0
        ;;
    esac
  fi

  # Capture RAUC status -- failure is NOT acceptable when RAUC is installed.
  local rauc_status
  if ! rauc_status="$(rauc status 2>/dev/null)"; then
    case "$scenario" in
      flashless|recovery|live)
        die "PF-54c: rauc status failed (D-Bus unavailable or rauc error) -- cannot verify system state for '$scenario' scenario"
        ;;
      *)
        warn "PF-54c: could not determine RAUC status -- proceeding with caution"
        return 0
        ;;
    esac
  fi

  if [[ -z "$rauc_status" ]]; then
    case "$scenario" in
      flashless|recovery|live)
        die "PF-54c: rauc status returned empty -- cannot verify system state for '$scenario' scenario"
        ;;
      *)
        warn "PF-54c: RAUC status is empty -- proceeding with caution"
        return 0
        ;;
    esac
  fi

  # Parse JSON status for detailed state (one snapshot, not multiple calls).
  local rauc_json
  rauc_json="$(rauc status --output-format=json 2>/dev/null)" || rauc_json=""

  if [[ -n "$rauc_json" ]]; then
    # Extract operation state from JSON.
    local rauc_op
    rauc_op="$(echo "$rauc_json" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("operation",""))' 2>/dev/null)" \
      || rauc_op=""

    # Check for active operations.
    case "$rauc_op" in
      installing|installing-with-automatic-reboot|busy)
        die "PF-54c: RAUC has active operation ($rauc_op) -- cannot proceed"
        ;;
      idle|"") ;;
      *) debug "PF-54c: RAUC operation state: $rauc_op" ;;
    esac

    # Verify booted slot is known.
    local rauc_booted
    rauc_booted="$(echo "$rauc_json" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("booted",d.get("active","")))' 2>/dev/null)" \
      || rauc_booted=""

    if [[ -n "$rauc_booted" && "$rauc_booted" != "null" ]]; then
      debug "PF-54c: RAUC booted slot: $rauc_booted"
    else
      warn "PF-54c: RAUC booted slot is unknown"
    fi
  fi

  # Fallback: check human-readable output for obvious busy indicators.
  local rauc_lower
  rauc_lower="$(echo "$rauc_status" | tr '[:upper:]' '[:lower:]')"

  if [[ "$rauc_lower" == *installing* || "$rauc_lower" == *busy* ]]; then
    die "PF-54c: RAUC is currently busy -- cannot proceed
RAUC status: $rauc_status"
  fi

  debug "PF-54c: RAUC is idle and system state is stable"
}

# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

# preflight_resources_validate EFIMNT EFI_REQUIRED_KB ROOTFS ROOTFS_REQUIRED_KB [ESP_MOUNT] [ESP_REQUIRED_KB] [LOCK_PATH] [SCENARIO]
#   Run all resource and concurrency preflight checks in sequence.
#   Dies on the first failure; returns 0 when all checks pass.
#
#   Required arguments:
#     EFIMNT           -- mounted EFI partition path
#     EFI_REQUIRED_KB  -- minimum free space required on EFI (KB)
#     ROOTFS           -- mounted root filesystem path
#     ROOTFS_REQUIRED_KB -- minimum free space required on rootfs (KB)
#
#   Optional arguments:
#     ESP_MOUNT        -- shared ESP mount path (skip ESP check if omitted)
#     ESP_REQUIRED_KB  -- minimum free space required on ESP (KB, required if ESP_MOUNT given)
#     LOCK_PATH        -- path for the flock file (default: /run/lock/steamos-build-installer/build.lock)
#     SCENARIO         -- build scenario name for RAUC behavior (default: "")
#
#   Global state set:
#     PF_LOCK_FD -- the flock file descriptor (valid until process exit)
preflight_resources_validate() {
  local efi_mount="${1:?preflight_resources_validate: missing EFIMNT}"
  local efi_required_kb="${2:?preflight_resources_validate: missing EFI_REQUIRED_KB}"
  local rootfs="${3:?preflight_resources_validate: missing ROOTFS}"
  local rootfs_required_kb="${4:?preflight_resources_validate: missing ROOTFS_REQUIRED_KB}"
  local esp_mount="${5:-}"
  local esp_required_kb="${6:-}"
  local lock_path="${7:-/run/lock/steamos-build-installer/build.lock}"
  local scenario="${8:-}"

  debug "preflight_resources_validate: efi=$efi_mount rootfs=$rootfs esp=${esp_mount:-<none>} scenario=${scenario:-<none>}"

  # PF-54a: Exclusive flock — acquired FIRST before any stateful checks.
  preflight_resources_acquire_lock "$lock_path"

  # PF-53a: EFI free space.
  preflight_resources_efi_free_space "$efi_mount" "$efi_required_kb"

  # PF-53b: rootfs free space.
  preflight_resources_rootfs_free_space "$rootfs" "$rootfs_required_kb"

  # PF-53c: ESP free space (optional -- only when ESP_MOUNT is provided).
  if [[ -n "$esp_mount" ]]; then
    # Ensure the corresponding required KB was also provided.
    if [[ -z "$esp_required_kb" ]]; then
      die "preflight_resources_validate: ESP_MOUNT provided but ESP_REQUIRED_KB is missing"
    fi
    preflight_resources_esp_free_space "$esp_mount" "$esp_required_kb"
  fi

  # PF-54b: No secondary mounts on the rootfs device.
  # Resolve the rootfs device from its mountpoint.
  local rootfs_device
  rootfs_device="$(findmnt -nro SOURCE -M "$rootfs" 2>/dev/null | head -1)" || rootfs_device=""
  if [[ -z "$rootfs_device" ]]; then
    die "PF-54b: could not determine device for rootfs: $rootfs"
  fi

  preflight_resources_no_secondary_mounts "$rootfs_device" "$rootfs"

  # PF-54c: RAUC idle and system state stable.
  preflight_resources_rauc_idle "$scenario"

  debug "preflight_resources_validate: all resource and concurrency checks passed"
}
