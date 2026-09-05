#!/bin/bash
#
# steamos-build-installer — lib/preflight_efi.sh
# EFI device validation: ensures the target EFI partition is a valid FAT block
# device, belongs to the correct slot, and is safe to mount and write.
# Supports two ownership modes: temporary (function creates a private mount)
# and existing (function reuses an already-mounted path).
# Called by the unified EFI state application mechanism.
#
# Requires: lib/common.sh (die, debug)
# Do not run it directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/preflight_efi.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _canonicalize_efi_device EFI_DEVICE
#   Resolve the EFI device path via `realpath` so symlinks such as
#   /dev/disk/by-partsets/... are resolved to their canonical form.
#   Dies if the input is empty or cannot be resolved.
_canonicalize_efi_device() {
  local device="${1:?_canonicalize_efi_device: missing device path}"

  local resolved
  resolved="$(realpath "$device" 2>/dev/null)" \
    || die "_canonicalize_efi_device: failed to resolve '$device'"

  [[ -n "$resolved" ]] \
    || die "_canonicalize_efi_device: resolved path is empty for '$device'"

  echo "$resolved"
}

# _efi_dev_major_minor DEVICE
#   Return the major:minor number pair for a block device using `stat`.
#   Dies if the device is not a block device or stat fails.
_efi_dev_major_minor() {
  local device="${1:?_efi_dev_major_minor: missing device path}"

  [[ -b "$device" ]] \
    || die "_efi_dev_major_minor: not a block device: $device"

  local dev_t
  dev_t="$(stat -c '%t:%T' "$device" 2>/dev/null)" \
    || die "_efi_dev_major_minor: stat failed for '$device'"

  # stat prints hex; convert to decimal for reliable comparison.
  local major_hex minor_hex major_dec minor_dec
  major_hex="${dev_t%%:*}"
  minor_hex="${dev_t##*:}"
  major_dec="$((16#${major_hex}))"
  minor_dec="$((16#${minor_hex}))"

  echo "${major_dec}:${minor_dec}"
}

# _efi_mount_cleanup MOUNTPOINT
#   Cleanup function for traps.  Unmounts the given mountpoint and removes
#   the directory if it was created by this library.
_efi_mount_cleanup() {
  local mountpoint="${1:?_efi_mount_cleanup: missing mountpoint}"

  if mountpoint -q "$mountpoint" 2>/dev/null; then
    umount "$mountpoint" 2>/dev/null || umount -l "$mountpoint" 2>/dev/null
  fi

  # Only remove directories we created (preflight-efi-* pattern).
  if [[ "$mountpoint" == /tmp/preflight-efi-* ]]; then
    rmdir "$mountpoint" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Preflight checks — independently callable
# ---------------------------------------------------------------------------

# preflight_efi_is_block_device EFI_DEVICE
#   PF-06: Verify the EFI device is a block device.
preflight_efi_is_block_device() {
  local device="${1:?preflight_efi_is_block_device: missing device path}"

  if [[ ! -b "$device" ]]; then
    die "PF-06: EFI target is not a block device: $device"
  fi

  debug "PF-06: EFI device is a block device: $device"
}

# preflight_efi_filesystem_is_fat EFI_DEVICE
#   PF-07: Verify the EFI device's filesystem type is FAT (vfat/fat/fat32).
#   Uses blkid to query TYPE; treats a successful mount + write test as
#   authoritative, but this early check catches obvious mismatches.
preflight_efi_filesystem_is_fat() {
  local device="${1:?preflight_efi_filesystem_is_fat: missing device path}"

  local fstype
  fstype="$(blkid -s TYPE -o value "$device" 2>/dev/null)" || fstype=""

  case "$fstype" in
    vfat | fat | fat32)
      debug "PF-07: EFI filesystem is FAT ($fstype): $device"
      ;;
    *)
      die "PF-07: EFI target is not FAT (detected: ${fstype:-<unknown>}): $device"
      ;;
  esac
}

# preflight_efi_matches_slot EFI_DEVICE SLOT_LABEL
#   PF-08: Verify the EFI device belongs to the target slot by comparing
#   PARTUUID case-insensitively against the expected device identity.
#   Comparison is done by major:minor of the resolved device, or by
#   PARTUUID if the device cannot be stat'd (e.g. already removed).
preflight_efi_matches_slot() {
  local device="${1:?preflight_efi_matches_slot: missing device path}"
  local slot="${2:?preflight_efi_matches_slot: missing slot label}"

  case "$slot" in
    A | B) ;;
    *) die "PF-08: invalid slot label: $slot" ;;
  esac

  # Resolve symlinks to get the canonical device.
  local canonical
  canonical="$(_canonicalize_efi_device "$device")"

  # Resolve the expected device via the partset symlink.
  local expected_dev
  expected_dev="$(readlink -f "/dev/disk/by-partsets/$slot/efi" 2>/dev/null)" \
    || die "PF-08: cannot resolve expected EFI device for slot $slot"

  if [[ ! -b "$expected_dev" ]]; then
    die "PF-08: expected EFI device for slot $slot is not a block device: $expected_dev"
  fi

  # Compare by major:minor (device identity), not by pathname.
  local actual_mm expected_mm
  actual_mm="$(_efi_dev_major_minor "$canonical")"
  expected_mm="$(_efi_dev_major_minor "$expected_dev")"

  if [[ "$actual_mm" != "$expected_mm" ]]; then
    # Fallback: compare PARTUUIDs case-insensitively.
    local actual_partuuid expected_partuuid
    actual_partuuid="$(blkid -s PARTUUID -o value "$canonical" 2>/dev/null)" || actual_partuuid=""
    expected_partuuid="$(blkid -s PARTUUID -o value "$expected_dev" 2>/dev/null)" || expected_partuuid=""

    if [[ -z "$actual_partuuid" || -z "$expected_partuuid" ]]; then
      die "PF-08: EFI device does not belong to target slot $slot (major:minor $actual_mm != $expected_mm; PARTUUID unavailable)"
    fi

    if [[ "${actual_partuuid,,}" != "${expected_partuuid,,}" ]]; then
      die "PF-08: EFI device does not belong to target slot $slot (PARTUUID $actual_partuuid != $expected_partuuid)"
    fi
  fi

  debug "PF-08: EFI device matches slot $slot (major:minor $actual_mm)"
}

# preflight_efi_mountpoint_safe EFIMNT
#   PF-09: For temporary mount mode, verify the mountpoint is not already
#   mounted and is empty.  Prevents stacking mounts or hiding files.
preflight_efi_mountpoint_safe() {
  local mountpoint="${1:?preflight_efi_mountpoint_safe: missing mountpoint}"

  if mountpoint -q "$mountpoint" 2>/dev/null; then
    die "PF-09: refusing to stack or hide files with EFI mount (already a mountpoint): $mountpoint"
  fi

  if [[ -d "$mountpoint" ]] && [[ -n "$(ls -A "$mountpoint" 2>/dev/null)" ]]; then
    die "PF-09: refusing to stack or hide files with EFI mount (directory not empty): $mountpoint"
  fi

  debug "PF-09: EFI mountpoint is safe: $mountpoint"
}

# preflight_efi_not_mounted_elsewhere EFI_DEVICE
#   PF-10: For temporary mount mode, verify the device is not already mounted.
#   This prevents accidentally operating on a device that is in use.
preflight_efi_not_mounted_elsewhere() {
  local device="${1:?preflight_efi_not_mounted_elsewhere: missing device path}"

  local canonical
  canonical="$(_canonicalize_efi_device "$device")"

  local mounts
  mounts="$(findmnt -rn -S "$canonical" 2>/dev/null)" || mounts=""

  if [[ -n "$mounts" ]]; then
    die "PF-10: EFI device is already mounted: $canonical"
  fi

  debug "PF-10: EFI device is not mounted elsewhere: $canonical"
}

# preflight_efi_existing_mount_correct EFIMNT EFI_DEVICE
#   PF-11: For existing mount mode, verify the backing device of the
#   existing mount matches the expected EFI device by major:minor.
preflight_efi_existing_mount_correct() {
  local mountpoint="${1:?preflight_efi_existing_mount_correct: missing mountpoint}"
  local device="${2:?preflight_efi_existing_mount_correct: missing device path}"

  local canonical_dev
  canonical_dev="$(_canonicalize_efi_device "$device")"

  # Find the device backing the existing mount.
  local backing_dev
  backing_dev="$(findmnt -rn -o SOURCE "$mountpoint" 2>/dev/null | head -1)" || backing_dev=""

  if [[ -z "$backing_dev" ]]; then
    die "PF-11: cannot determine backing device for EFI mount: $mountpoint"
  fi

  # Resolve the backing device to its canonical form.
  local canonical_backing
  canonical_backing="$(realpath "$backing_dev" 2>/dev/null)" || canonical_backing="$backing_dev"

  # Compare by major:minor.
  local mount_mm dev_mm
  mount_mm="$(_efi_dev_major_minor "$canonical_backing")"
  dev_mm="$(_efi_dev_major_minor "$canonical_dev")"

  if [[ "$mount_mm" != "$dev_mm" ]]; then
    die "PF-11: EFI mount does not match target device (mount=$canonical_backing major:minor=$mount_mm, device=$canonical_dev major:minor=$dev_mm)"
  fi

  debug "PF-11: EFI existing mount matches target device (major:minor $mount_mm)"
}

# preflight_efi_existing_mount_writable EFIMNT
#   PF-12: For existing mount mode, verify the mount is writable.
#   Checks mount options for 'ro' flag via findmnt.
preflight_efi_existing_mount_writable() {
  local mountpoint="${1:?preflight_efi_existing_mount_writable: missing mountpoint}"

  local mount_opts
  mount_opts="$(findmnt -rn -o OPTIONS "$mountpoint" 2>/dev/null)" || mount_opts=""

  if [[ -n "$mount_opts" ]]; then
    # Match 'ro' as a standalone comma-separated mount option (not a substring
    # like 'rootfs' or 'proc').
    if [[ ",$mount_opts," =~ ,ro, || "$mount_opts" == ro || "$mount_opts" =~ ^ro, || "$mount_opts" =~ ,ro$ ]]; then
      die "PF-12: EFI mount is not writable (mounted read-only): $mountpoint"
    fi
  fi

  debug "PF-12: EFI existing mount is writable: $mountpoint"
}

# preflight_efi_mountable EFI_DEVICE EFIMNT
#   PF-13: Mount the EFI device at the given mountpoint.  Dies if mount fails.
#   The caller (preflight_efi_validate_temporary) is responsible for installing
#   the RETURN trap so that cleanup lasts until the orchestrator returns.
preflight_efi_mountable() {
  local device="${1:?preflight_efi_mountable: missing device path}"
  local mountpoint="${2:?preflight_efi_mountable: missing mountpoint}"

  # Ensure the mountpoint directory exists.
  if [[ ! -d "$mountpoint" ]]; then
    mkdir -p "$mountpoint" \
      || die "PF-13: could not create EFI mountpoint: $mountpoint"
  fi

  if ! mount -o rw "$device" "$mountpoint" 2>/dev/null; then
    die "PF-13: could not mount EFI device (corrupt or unsupported filesystem): $device -> $mountpoint"
  fi

  debug "PF-13: EFI device mounted: $device -> $mountpoint"
}

# preflight_efi_reject_corrupt EFI_DEVICE EFIMNT
#   PF-14: Verify the device's partition metadata is consistent with a valid
#   FAT EFI partition using blkid.  Does NOT mount the device (PF-13 will
#   handle the actual mount and catch mount-time corruption).
preflight_efi_reject_corrupt() {
  local device="${1:?preflight_efi_reject_corrupt: missing device path}"
  local mountpoint="${2:?preflight_efi_reject_corrupt: missing mountpoint}"

  # Verify SEC_TYPE is consistent with a genuine EFI System Partition.
  # A corrupt or non-ESP partition may report TYPE=vfat but lack the
  # correct SEC_TYPE, or blkid may fail entirely.
  local sec_type
  sec_type="$(blkid -s SEC_TYPE -o value "$device" 2>/dev/null)" || sec_type=""

  if [[ -z "$sec_type" ]]; then
    die "PF-14: EFI partition metadata is corrupt or missing (SEC_TYPE empty): $device"
  fi

  case "$sec_type" in
    msfat | fat12 | fat16 | fat32)
      debug "PF-14: EFI partition metadata is valid (SEC_TYPE=$sec_type): $device"
      ;;
    *)
      die "PF-14: EFI partition metadata is corrupt or invalid (SEC_TYPE=$sec_type): $device"
      ;;
  esac
}

# preflight_efi_accepts_writes EFI_DEVICE EFIMNT
#   PF-15: Verify the mounted EFI filesystem accepts writes by creating
#   and removing a temporary file.
preflight_efi_accepts_writes() {
  local device="${1:?preflight_efi_accepts_writes: missing device path}"
  local mountpoint="${2:?preflight_efi_accepts_writes: missing mountpoint}"

  local test_file
  test_file="$(mktemp "$mountpoint/.preflight-writable-XXXXXX" 2>/dev/null)" \
    || die "PF-15: EFI filesystem is not writable (cannot create file in $mountpoint): $device"

  rm -f "$test_file" 2>/dev/null \
    || die "PF-15: EFI filesystem is not writable (cannot remove test file): $device"

  debug "PF-15: EFI filesystem accepts writes: $mountpoint"
}

# ---------------------------------------------------------------------------
# Orchestrators
# ---------------------------------------------------------------------------

# preflight_efi_validate_temporary EFI_DEVICE EFIMNT SLOT_LABEL
#   Validate the EFI device for temporary mount mode.
#   Creates and owns a private mount at EFIMNT.  The RETURN trap for
#   cleanup is installed here (the orchestrator) so it fires when this
#   function returns — not when the mountable helper returns.
#   Caller must unset the RETURN trap after successful use.
preflight_efi_validate_temporary() {
  local device="${1:?preflight_efi_validate_temporary: missing device path}"
  local mountpoint="${2:?preflight_efi_validate_temporary: missing mountpoint}"
  local slot="${3:?preflight_efi_validate_temporary: missing slot label}"

  debug "preflight_efi_validate_temporary: validating $device for slot $slot"

  # PF-06: Block device check.
  preflight_efi_is_block_device "$device"

  # PF-07: FAT filesystem check.
  preflight_efi_filesystem_is_fat "$device"

  # PF-08: Slot identity check.
  preflight_efi_matches_slot "$device" "$slot"

  # PF-09: Mountpoint safety check.
  preflight_efi_mountpoint_safe "$mountpoint"

  # PF-10: Device not already mounted.
  preflight_efi_not_mounted_elsewhere "$device"

  # PF-14: Reject corrupt partition (metadata probe — no mount).
  preflight_efi_reject_corrupt "$device" "$mountpoint"

  # PF-13: Mount the device.
  preflight_efi_mountable "$device" "$mountpoint"

  # Install RETURN trap here in the orchestrator so cleanup persists
  # until this function returns (covering the write test below).
  trap "_efi_mount_cleanup '$mountpoint'" RETURN

  # PF-15: Write test.
  preflight_efi_accepts_writes "$device" "$mountpoint"

  debug "preflight_efi_validate_temporary: all checks passed for $device"
}

# preflight_efi_validate_existing EFIMNT EFI_DEVICE SLOT_LABEL
#   Validate an existing EFI mount for reuse.
#   Verifies the mount is backed by the correct device and is writable.
preflight_efi_validate_existing() {
  local mountpoint="${1:?preflight_efi_validate_existing: missing mountpoint}"
  local device="${2:?preflight_efi_validate_existing: missing device path}"
  local slot="${3:?preflight_efi_validate_existing: missing slot label}"

  debug "preflight_efi_validate_existing: validating existing mount $mountpoint for device $device (slot $slot)"

  # PF-06: Block device check.
  preflight_efi_is_block_device "$device"

  # PF-07: FAT filesystem check.
  preflight_efi_filesystem_is_fat "$device"

  # PF-08: Slot identity check.
  preflight_efi_matches_slot "$device" "$slot"

  # PF-11: Existing mount is backed by the correct device.
  preflight_efi_existing_mount_correct "$mountpoint" "$device"

  # PF-12: Existing mount is writable.
  preflight_efi_existing_mount_writable "$mountpoint"

  # PF-15: Write test under existing mount.
  preflight_efi_accepts_writes "$device" "$mountpoint"

  debug "preflight_efi_validate_existing: all checks passed for $mountpoint ($device)"
}
