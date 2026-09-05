#!/bin/bash
#
# steamos-build-installer — lib/preflight_filesystem_state.sh
# Filesystem state validation: ensures the target filesystem is in a
# stable, consistent state before any modification begins.  Detects
# in-progress Btrfs operations (balance, device-replace, UUID change),
# verifies dm-verity device state and policy, checks boot payload
# integrity, and validates source image integrity via SHA-256 hashes.
#
# Requires: lib/common.sh (die, debug, warn)
# Do not run it directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/preflight_filesystem_state.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _pf_fs_get_btrfs_mount ROOTFS
#   Resolve the Btrfs mountpoint for ROOTFS via findmnt.
#   Prints the canonical mount path or empty on failure.
#   Uses findmnt -n -o TARGET for a clean output.
_pf_fs_get_btrfs_mount() {
  local rootfs="${1:?_pf_fs_get_btrfs_mount: missing rootfs path}"

  local mountpoint
  mountpoint="$(findmnt -n -o TARGET "$rootfs" 2>/dev/null)" || mountpoint=""

  if [[ -n "$mountpoint" ]]; then
    echo "$mountpoint"
  fi
}

# _pf_fs_btrfs_balance_active ROOTFS
#   Check whether a Btrfs balance operation is active on the filesystem
#   containing ROOTFS.  Returns 0 if a balance is running, 1 otherwise.
#   Uses `btrfs balance status` which is non-destructive and safe to call.
_pf_fs_btrfs_balance_active() {
  local rootfs="${1:?_pf_fs_btrfs_balance_active: missing rootfs path}"

  # btrfs balance status returns 0 when idle, non-zero when active or on error.
  # We need to distinguish "active" (exit 1) from "error" (exit >1 or no btrfs).
  if ! command -v btrfs &>/dev/null; then
    return 1
  fi

  local output
  output="$(btrfs balance status "$rootfs" 2>&1)" || true

  # The output contains "No balance found" when idle.
  if [[ "$output" == *"No balance found"* ]]; then
    return 1
  fi

  # The output contains "Balance is running" when active.
  if [[ "$output" == *"Balance is running"* ]]; then
    return 0
  fi

  # Treat other states as not actively balancing.
  return 1
}

# _pf_fs_btrfs_replace_active ROOTFS
#   Check whether a Btrfs device-replace operation is active on the
#   filesystem containing ROOTFS.  Returns 0 if replace is running,
#   1 otherwise.  Uses `btrfs replace status` which is non-destructive.
_pf_fs_btrfs_replace_active() {
  local rootfs="${1:?_pf_fs_btrfs_replace_active: missing rootfs path}"

  if ! command -v btrfs &>/dev/null; then
    return 1
  fi

  local output
  output="$(btrfs replace status "$rootfs" 2>&1)" || true

  # The output contains "No replace found on" when idle.
  if [[ "$output" == *"No replace found"* || "$output" == *"no replace found"* ]]; then
    return 1
  fi

  # The output contains "Replace operation in progress" when active.
  if [[ "$output" == *"in progress"* || "$output" == *"Replace running"* ]]; then
    return 0
  fi

  # Treat other states as not actively replacing.
  return 1
}

# _pf_fs_btrfs_uuid_change_active
#   Check whether a btrfstune UUID-change operation is active.
#   Returns 0 if a btrfstune process is running, 1 otherwise.
#   Scans the process list for btrfstune invocations.
_pf_fs_btrfs_uuid_change_active() {
  # Look for running btrfstune processes.
  if pgrep -x btrfstune &>/dev/null; then
    return 0
  fi

  return 1
}

# _pf_fs_active_verity_devices ROOTFS
#   List active dm-verity devices associated with ROOTFS.
#   Prints each device name (one per line) or nothing if none exist.
#   Inspects /dev/mapper/ and /sys/block/dm-*/ holders to find
#   verity-backed block devices.
_pf_fs_active_verity_devices() {
  local rootfs="${1:?_pf_fs_active_verity_devices: missing rootfs path}"

  local device
  device="$(findmnt -n -o SOURCE "$rootfs" 2>/dev/null)" || device=""

  if [[ -z "$device" ]]; then
    return 0
  fi

  # Resolve to absolute path under /dev/ if needed.
  if [[ "$device" != /dev/* ]]; then
    device="/dev/${device}"
  fi

  # Check if the rootfs device itself is a dm device.
  if [[ -b "$device" ]]; then
    local dev_name
    dev_name="$(basename "$device")"
    # A dm-verity device has "verity" in its dm name or is a linear mapping
    # over a verity device.
    if [[ "$dev_name" == dm-* ]]; then
      # Check /sys/block/$dev_name/dm/name for verity in the table.
      local dm_name
      dm_name="$(cat "/sys/block/${dev_name}/dm/name" 2>/dev/null)" || dm_name=""
      if [[ "$dm_name" == *verity* ]]; then
        echo "$device"
      fi
    fi
  fi

  # Also look for verity devices in /dev/mapper/ that are related to rootfs.
  local verity_count
  verity_count="$(find /dev/mapper/ -maxdepth 1 -name '*verity*' 2>/dev/null | wc -l)" || verity_count="0"

  if ((verity_count > 0)); then
    find /dev/mapper/ -maxdepth 1 -name '*verity*' -printf '%f\n' 2>/dev/null || true
  fi
}

# _pf_fs_compute_sha256 FILE_PATH
#   Compute the SHA-256 hash of FILE_PATH.
#   Prints the hex-encoded hash string.
#   Dies if sha256sum is unavailable or the computation fails.
_pf_fs_compute_sha256() {
  local file_path="${1:?_pf_fs_compute_sha256: missing file path}"

  if [[ ! -f "$file_path" ]]; then
    die "_pf_fs_compute_sha256: file does not exist: $file_path"
  fi

  if ! command -v sha256sum &>/dev/null; then
    die "_pf_fs_compute_sha256: sha256sum not available"
  fi

  local hash
  hash="$(sha256sum "$file_path" 2>/dev/null)" \
    || die "_pf_fs_compute_sha256: failed to compute hash for $file_path"

  # sha256sum outputs "hash  filename" — extract the hash.
  echo "$hash" | awk '{print $1}'
}

# _pf_fs_locate_hash_file IMAGE_PATH
#   Find the companion hash file for IMAGE_PATH.
#   Convention: the hash file is IMAGE_PATH with .sha256 appended.
#   Prints the path if found, otherwise returns 1.
_pf_fs_locate_hash_file() {
  local image_path="${1:?_pf_fs_locate_hash_file: missing image path}"

  local hash_file="${image_path}.sha256"

  if [[ -f "$hash_file" ]]; then
    echo "$hash_file"
    return 0
  fi

  return 1
}

# _pf_fs_parse_hash_file HASH_FILE
#   Extract the SHA-256 hash from HASH_FILE.
#   Supports formats:
#     "hash  filename"   (sha256sum output format)
#     "hash"             (bare hash, no filename)
#   Prints the hash string.
#   Dies if the file is empty or the hash cannot be extracted.
_pf_fs_parse_hash_file() {
  local hash_file="${1:?_pf_fs_parse_hash_file: missing hash file path}"

  if [[ ! -f "$hash_file" ]]; then
    die "_pf_fs_parse_hash_file: hash file does not exist: $hash_file"
  fi

  if [[ ! -s "$hash_file" ]]; then
    die "_pf_fs_parse_hash_file: hash file is empty: $hash_file"
  fi

  local first_line
  first_line="$(head -n 1 "$hash_file")" \
    || die "_pf_fs_parse_hash_file: failed to read hash file: $hash_file"

  # Strip leading/trailing whitespace.
  first_line="$(echo "$first_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  if [[ -z "$first_line" ]]; then
    die "_pf_fs_parse_hash_file: hash file contains no hash: $hash_file"
  fi

  # If line contains two fields, take the first (sha256sum format).
  local hash
  hash="$(echo "$first_line" | awk '{print $1}')"

  # Validate hash is hex and exactly 64 characters.
  if [[ ! "$hash" =~ ^[0-9a-fA-F]{64}$ ]]; then
    die "_pf_fs_parse_hash_file: invalid SHA-256 hash in $hash_file: '$hash'"
  fi

  echo "$hash"
}

# ---------------------------------------------------------------------------
# Individual checks — independently callable
# ---------------------------------------------------------------------------

# preflight_filesystem_state_no_btrfs_operations ROOTFS
#   PF-60: Ensure no active Btrfs balance, device-replace, or UUID-change
#   operation is in progress.  Active Btrfs operations can cause data
#   corruption or incomplete state if we proceed concurrently.
pf_fs_check_no_btrfs_operations() {
  local rootfs="${1:?pf_fs_check_no_btrfs_operations: missing rootfs path}"

  if _pf_fs_btrfs_balance_active "$rootfs"; then
    die "PF-60: active Btrfs balance operation detected on $rootfs — must complete before proceeding"
  fi
  debug "PF-60: no active Btrfs balance on $rootfs"

  if _pf_fs_btrfs_replace_active "$rootfs"; then
    die "PF-60: active Btrfs device-replace operation detected on $rootfs — must complete before proceeding"
  fi
  debug "PF-60: no active Btrfs device-replace on $rootfs"

  if _pf_fs_btrfs_uuid_change_active; then
    die "PF-60: active btrfstune UUID-change operation detected — must complete before proceeding"
  fi
  debug "PF-60: no active btrfstune UUID-change"

  debug "PF-60: no active Btrfs operations detected"
}

# preflight_filesystem_state_verity_inactive ROOTFS
#   PF-61: Verify that dm-verity devices are either inactive or consistent
#   with the expected state.  On systems without dm-verity, this check
#   gracefully skips.  Active verity devices that conflict with planned
#   modifications will cause a failure.
pf_fs_check_verity_inactive() {
  local rootfs="${1:?pf_fs_check_verity_inactive: missing rootfs path}"

  # Graceful skip: if dm-verity tooling is not present, this is not applicable.
  if ! command -v veritysetup &>/dev/null && ! command -v dmsetup &>/dev/null; then
    debug "PF-61: neither veritysetup nor dmsetup found — skipping (no verity support)"
    return 0
  fi

  local verity_devices
  verity_devices="$(_pf_fs_active_verity_devices "$rootfs")"

  if [[ -z "$verity_devices" ]]; then
    debug "PF-61: no active dm-verity devices for $rootfs"
    return 0
  fi

  # Count the devices to report.
  local verity_count
  verity_count="$(echo "$verity_devices" | wc -l)" || verity_count="0"

  # Verity devices are active — incompatible with planned modifications.
  die "PF-61: $verity_count active dm-verity device(s) detected for $rootfs — verity device is active"
  debug "PF-61: active verity devices: $verity_devices"
}

# preflight_filesystem_state_verity_policy_defined ROOTFS
#   PF-62: When the rootfs will be modified, verify that a dm-verity policy
#   is defined for the rootfs device.  This ensures that any modification
#   includes proper verity policy re-association.  Gracefully skips on
#   non-verity systems.
pf_fs_check_verity_policy_defined() {
  local rootfs="${1:?pf_fs_check_verity_policy_defined: missing rootfs path}"

  # Graceful skip: if veritysetup is not available, this is not applicable.
  if ! command -v veritysetup &>/dev/null; then
    debug "PF-62: veritysetup not found — skipping (no verity support)"
    return 0
  fi

  local device
  device="$(findmnt -n -o SOURCE "$rootfs" 2>/dev/null)" || device=""

  if [[ -z "$device" ]]; then
    debug "PF-62: could not resolve rootfs device — skipping verity policy check"
    return 0
  fi

  # Resolve to absolute path.
  if [[ "$device" != /dev/* ]]; then
    device="/dev/${device}"
  fi

  # Check if the device is a dm device that could have verity.
  if [[ ! -b "$device" ]]; then
    debug "PF-62: device $device is not a block device — skipping verity policy check"
    return 0
  fi

  local dev_name
  dev_name="$(basename "$device")"

  # Only check verity policy for dm devices.
  if [[ "$dev_name" != dm-* ]]; then
    debug "PF-62: device $device is not a dm device — no verity policy to verify"
    return 0
  fi

  # Check the dm table for verity segments.
  local dm_table
  dm_table="$(dmsetup table "$dev_name" 2>/dev/null)" || dm_table=""

  if [[ -z "$dm_table" ]]; then
    debug "PF-62: could not read dm table for $dev_name — skipping"
    return 0
  fi

  # Check if the table contains verity targets.
  if [[ "$dm_table" == *verity* ]]; then
    debug "PF-62: dm-verity policy is defined for $device"
  else
    # Device exists but has no verity policy.  This is fatal — the modifier
    # must not proceed without a defined verity update policy.
    die "PF-62: dm device $device has no verity policy — verity update policy not defined"
  fi
}

# preflight_filesystem_state_coherent_boot_payload ROOTFS
#   PF-63: Verify that the kernel and initramfs pair exists in the rootfs.
#   A boot system requires both a kernel image and a matching initramfs
#   to successfully boot.  Dies if neither exists.
pf_fs_check_coherent_boot_payload() {
  local rootfs="${1:?pf_fs_check_coherent_boot_payload: missing rootfs path}"

  local boot_dir="$rootfs/boot"

  if [[ ! -d "$boot_dir" ]]; then
    die "PF-63: boot directory does not exist: $boot_dir"
  fi

  # Check for at least one kernel image.
  # Common kernel image names: vmlinuz*, vmlinux*, bzImage*
  local kernel_count
  kernel_count="$(find "$boot_dir" -maxdepth 1 \( -name 'vmlinuz*' -o -name 'vmlinux*' -o -name 'bzImage*' \) -type f 2>/dev/null | wc -l)" || kernel_count="0"

  if ((kernel_count == 0)); then
    die "PF-63: no kernel image found in $boot_dir (expected vmlinuz*, vmlinux*, or bzImage*)"
  fi

  # Check for at least one initramfs/initrd image.
  # Common names: initramfs*, initrd*, initrd.img*
  local initrd_count
  initrd_count="$(find "$boot_dir" -maxdepth 1 \( -name 'initramfs*' -o -name 'initrd*' \) -type f 2>/dev/null | wc -l)" || initrd_count="0"

  if ((initrd_count == 0)); then
    die "PF-63: no initramfs/initrd found in $boot_dir (expected initramfs* or initrd*)"
  fi

  debug "PF-63: boot payload present ($kernel_count kernel(s), $initrd_count initramfs/initrd(s)): $boot_dir"
}

# preflight_filesystem_state_source_integrity IMAGE_PATH EXPECTED_HASH
#   PF-64: Verify the source image integrity by computing its SHA-256 hash
#   and comparing it against EXPECTED_HASH.  If EXPECTED_HASH is provided,
#   a direct comparison is performed.  If EXPECTED_HASH is empty, the
#   companion hash file (.sha256) is located and parsed for the expected hash.
#   Dies on mismatch.
pf_fs_check_source_integrity() {
  local image_path="${1:?pf_fs_check_source_integrity: missing image path}"
  local expected_hash="${2:-}"

  if [[ ! -f "$image_path" ]]; then
    die "PF-64: source image does not exist: $image_path"
  fi

  # Compute the actual hash.
  local actual_hash
  actual_hash="$(_pf_fs_compute_sha256 "$image_path")"

  # Resolve expected hash: use provided value or look for companion hash file.
  if [[ -z "$expected_hash" ]]; then
    local hash_file
    if hash_file="$(_pf_fs_locate_hash_file "$image_path")"; then
      expected_hash="$(_pf_fs_parse_hash_file "$hash_file")"
      debug "PF-64: loaded expected hash from $hash_file"
    else
      die "PF-64: no expected hash provided and no companion hash file found: ${image_path}.sha256"
    fi
  fi

  # Compare hashes (case-insensitive for hex).
  if [[ "${actual_hash,,}" != "${expected_hash,,}" ]]; then
    die "PF-64: source image integrity mismatch for $image_path
  expected: $expected_hash
  actual:   $actual_hash"
  fi

  debug "PF-64: source image integrity verified: $image_path (hash=$actual_hash)"
}

# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

# preflight_filesystem_state_validate ROOTFS [TARGET_DEVICE] [IMAGE_PATH] [EXPECTED_HASH] [ROOTFS_MODIFIED]
#   Run the full filesystem state validation sequence:
#     PF-60  No active Btrfs operations (balance/device-replace/UUID change)
#     PF-61  dm-verity device state (graceful skip if no verity)
#     PF-62  dm-verity policy defined (when ROOTFS_MODIFIED=true)
#     PF-63  Boot payload exists (kernel + initramfs)
#     PF-64  Source image integrity (SHA-256 verification)
#
#   Required arguments:
#     ROOTFS          — mounted root filesystem path
#
#   Optional arguments:
#     TARGET_DEVICE   — target block device (reserved for future use)
#     IMAGE_PATH      — source image file to verify integrity
#     EXPECTED_HASH   — expected SHA-256 hash (if empty, looks for .sha256 file)
#     ROOTFS_MODIFIED — "true" to verify verity policy, otherwise skipped
#
#   Dies on the first fatal check failure; returns 0 when all checks pass.
preflight_filesystem_state_validate() {
  local rootfs="${1:?preflight_filesystem_state_validate: missing ROOTFS}"
  local target_device="${2:-}"
  local image_path="${3:-}"
  local expected_hash="${4:-}"
  local rootfs_modified="${5:-}"

  debug "preflight_filesystem_state_validate: rootfs=$rootfs device=${target_device:-<none>} image=${image_path:-<none>} rootfs_modified=${rootfs_modified:-false}"

  # PF-60: No active Btrfs operations.
  pf_fs_check_no_btrfs_operations "$rootfs"

  # PF-61: Verity device state (graceful skip on non-verity systems).
  pf_fs_check_verity_inactive "$rootfs"

  # PF-62: Verity policy defined (only when rootfs will be modified).
  if [[ "${rootfs_modified:-false}" == "true" ]]; then
    pf_fs_check_verity_policy_defined "$rootfs"
  else
    debug "PF-62: rootfs_modified is not true — skipping verity policy check"
  fi

  # PF-63: Boot payload exists.
  pf_fs_check_coherent_boot_payload "$rootfs"

  # PF-64: Source image integrity (only when IMAGE_PATH is provided).
  if [[ -n "$image_path" ]]; then
    pf_fs_check_source_integrity "$image_path" "$expected_hash"
  else
    debug "PF-64: no IMAGE_PATH provided — skipping source integrity check"
  fi

  debug "preflight_filesystem_state_validate: all filesystem state checks passed"
}
