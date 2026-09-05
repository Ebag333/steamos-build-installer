#!/bin/bash
#
# steamos-build-installer — lib/preflight_efi.sh
# EFI device validation: ensures the target EFI partition is a valid FAT block
# device, belongs to the correct slot, and is safe to mount and write.
# Supports two ownership modes: temporary (function validates and mounts but
# does NOT install cleanup traps — the caller owns the lifecycle) and
# existing (function reuses an already-mounted path).
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

# _pf_efi_canonicalize_device EFI_DEVICE
#   Resolve the EFI device path via `realpath` so symlinks such as
#   /dev/disk/by-partsets/... are resolved to their canonical form.
#   Dies if the input is empty or cannot be resolved.
_pf_efi_canonicalize_device() {
  local device="${1:?_pf_efi_canonicalize_device: missing device path}"

  local resolved
  resolved="$(realpath "$device" 2>/dev/null)" \
    || die "_pf_efi_canonicalize_device: failed to resolve '$device'"

  [[ -n "$resolved" ]] \
    || die "_pf_efi_canonicalize_device: resolved path is empty for '$device'"

  echo "$resolved"
}

# Backward-compatible alias — other libraries source this file and call
# the old name.  Remove once all callers have been migrated.
_canonicalize_efi_device() { _pf_efi_canonicalize_device "$@"; }

# _pf_efi_device_major_minor DEVICE
#   Return the major:minor number pair for a block device using `stat`.
#   Dies if the device is not a block device or stat fails.
_pf_efi_device_major_minor() {
  local device="${1:?_pf_efi_device_major_minor: missing device path}"

  [[ -b "$device" ]] \
    || die "_pf_efi_device_major_minor: not a block device: $device"

  local dev_t
  dev_t="$(stat -c '%t:%T' "$device" 2>/dev/null)" \
    || die "_pf_efi_device_major_minor: stat failed for '$device'"

  # stat prints hex; convert to decimal for reliable comparison.
  local major_hex minor_hex major_dec minor_dec
  major_hex="${dev_t%%:*}"
  minor_hex="${dev_t##*:}"
  major_dec="$((16#${major_hex}))"
  minor_dec="$((16#${minor_hex}))"

  echo "${major_dec}:${minor_dec}"
}

# Backward-compatible alias — other libraries source this file and call
# the old name.  Remove once all callers have been migrated.
_efi_dev_major_minor() { _pf_efi_device_major_minor "$@"; }

# _pf_efi_mount_cleanup MOUNTPOINT
#   Cleanup function for traps.  Unmounts the given mountpoint and removes
#   the directory if it was created by this library.
#   Reports failure when lazy unmount is needed (files may not be flushed).
_pf_efi_mount_cleanup() {
  local mountpoint="${1:?_pf_efi_mount_cleanup: missing mountpoint}"

  if ! mountpoint -q "$mountpoint" 2>/dev/null; then
    return 0 # Already unmounted
  fi

  if umount "$mountpoint" 2>/dev/null; then
    debug "_pf_efi_mount_cleanup: successfully unmounted $mountpoint"
  else
    warn "_pf_efi_mount_cleanup: normal unmount failed for $mountpoint, attempting lazy unmount"
    if umount -l "$mountpoint" 2>/dev/null; then
      warn "_pf_efi_mount_cleanup: lazy unmount performed for $mountpoint -- flush and reference release not guaranteed"
    else
      warn "_pf_efi_mount_cleanup: FAILED to unmount $mountpoint (even lazy unmount failed)"
      return 1
    fi
  fi

  # Only remove directories we created (preflight-efi-* pattern).
  if [[ "$mountpoint" == /tmp/preflight-efi-* ]]; then
    rmdir "$mountpoint" 2>/dev/null || true
  fi

  return 0
}

# Backward-compatible alias — other libraries source this file and call
# the old name.  Remove once all callers have been migrated.
_efi_mount_cleanup() { _pf_efi_mount_cleanup "$@"; }

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

# preflight_efi_matches_slot EFI_DEVICE SLOT_LABEL [EXPECTED_DEVICE]
#   PF-08: Verify the EFI device belongs to the target slot by comparing
#   major:minor of the resolved device against the expected device.
#   Identity is exclusively determined by major:minor — PARTUUID fallback
#   is intentionally omitted because matching PARTUUID with differing
#   major:minor signals a cloned/duplicate device, which is rejected.
#   When a duplicate PARTUUID is found across visible devices, the check
#   fails to prevent ambiguous identity.
#   An optional third argument EXPECTED_DEVICE bypasses the
#   /dev/disk/by-partsets lookup (for build fixtures where partsets may
#   not exist).
preflight_efi_matches_slot() {
  local device="${1:?preflight_efi_matches_slot: missing device path}"
  local slot="${2:?preflight_efi_matches_slot: missing slot label}"
  local expected_dev="${3:-}"

  case "$slot" in
    A | B) ;;
    *) die "PF-08: invalid slot label: $slot" ;;
  esac

  # Resolve symlinks to get the canonical device.
  local canonical
  if ! canonical="$(_pf_efi_canonicalize_device "$device")"; then
    die "PF-08: could not resolve EFI device: $device"
  fi

  # Use explicit expected device if provided, otherwise resolve via partsets.
  if [[ -z "$expected_dev" ]]; then
    expected_dev="$(readlink -f "/dev/disk/by-partsets/$slot/efi" 2>/dev/null)" \
      || die "PF-08: cannot resolve expected EFI device for slot $slot (no expected device provided)"
  fi

  if [[ ! -b "$expected_dev" ]]; then
    die "PF-08: expected EFI device for slot $slot is not a block device: $expected_dev"
  fi

  # Compare by major:minor — this is the authoritative identity check.
  local actual_mm expected_mm
  if ! actual_mm="$(_pf_efi_device_major_minor "$canonical")"; then
    die "PF-08: could not determine device identity for $canonical"
  fi
  if ! expected_mm="$(_pf_efi_device_major_minor "$expected_dev")"; then
    die "PF-08: could not determine device identity for $expected_dev"
  fi

  if [[ "$actual_mm" != "$expected_mm" ]]; then
    die "PF-08: EFI device does not belong to target slot $slot (major:minor $actual_mm != $expected_mm)"
  fi

  # Cross-check: enumerate all devices with this PARTUUID and ensure
  # exactly one exists (the expected device). Detect cloned/duplicate devices.
  local partuuid
  partuuid="$(blkid -s PARTUUID -o value "$canonical" 2>/dev/null)" || partuuid=""
  if [[ -n "$partuuid" ]]; then
    local match_count=0
    local dev
    for dev in /dev/sd? /dev/nvme?n?p? /dev/mmcblk?p?; do
      [[ -b "$dev" ]] || continue
      local dev_uuid
      dev_uuid="$(blkid -s PARTUUID -o value "$dev" 2>/dev/null)" || continue
      if [[ "${dev_uuid,,}" == "${partuuid,,}" ]]; then
        match_count=$((match_count + 1))
      fi
    done
    if [[ "$match_count" -gt 1 ]]; then
      die "PF-08: ambiguous duplicate device — $match_count devices share PARTUUID $partuuid (expected exactly 1)"
    fi
  fi

  debug "PF-08: EFI device matches slot $slot (major:minor $actual_mm)"
}

# preflight_efi_mountpoint_safe EFIMNT
#   PF-09: For temporary mount mode, verify the mountpoint is safe to use.
#   - Rejects symlinks (mountpoint must be a real directory).
#   - Creates the directory if it does not exist (single-level, not -p).
#   - Verifies the directory is readable.
#   - Rejects if already a mountpoint (prevents stacking).
#   - Rejects if the directory is not empty (prevents hiding files).
preflight_efi_mountpoint_safe() {
  local mountpoint="${1:?preflight_efi_mountpoint_safe: missing mountpoint}"

  # Reject symlinks -- mountpoint must be a real directory.
  if [[ -L "$mountpoint" ]]; then
    die "PF-09: EFI mountpoint is a symlink (must be a real directory): $mountpoint"
  fi

  if [[ ! -d "$mountpoint" ]]; then
    # Create the directory (single level, not -p to avoid unsafe parent creation).
    mkdir "$mountpoint" \
      || die "PF-09: could not create EFI mountpoint directory: $mountpoint"
    debug "PF-09: created EFI mountpoint directory: $mountpoint"
  fi

  # Verify it's readable.
  if [[ ! -r "$mountpoint" ]]; then
    die "PF-09: EFI mountpoint is not readable: $mountpoint"
  fi

  # Verify not already a mountpoint.
  if mountpoint -q "$mountpoint" 2>/dev/null; then
    die "PF-09: refusing to stack or hide files with EFI mount (already a mountpoint): $mountpoint"
  fi

  # Clean up stale test files left behind by a previous interrupted
  # preflight_efi_accepts_writes run before checking emptiness.
  local stale
  for stale in "$mountpoint"/.preflight-writable-*; do
    [[ -e "$stale" ]] || continue # glob matched nothing
    debug "PF-09: removing stale preflight test file: $stale"
    rm -f "$stale" 2>/dev/null \
      || die "PF-09: cannot remove stale preflight test file: $stale"
  done

  # Verify empty.
  if [[ -n "$(ls -A "$mountpoint" 2>/dev/null)" ]]; then
    die "PF-09: refusing to stack or hide files with EFI mount (directory not empty): $mountpoint"
  fi

  debug "PF-09: EFI mountpoint is safe: $mountpoint"
}

# preflight_efi_not_mounted_elsewhere EFI_DEVICE
#   PF-10: For temporary mount mode, verify the device is not already mounted.
#   Uses MAJ:MIN comparison via /proc/self/mountinfo to reliably detect mounts
#   even for device aliases, device-mapper paths, and bind mounts.
#   This prevents accidentally operating on a device that is in use.
preflight_efi_not_mounted_elsewhere() {
  local device="${1:?preflight_efi_not_mounted_elsewhere: missing device path}"

  local canonical
  if ! canonical="$(_pf_efi_canonicalize_device "$device")"; then
    die "PF-10: could not resolve EFI device: $device"
  fi
  [[ -n "$canonical" ]] || die "PF-10: empty canonical device for: $device"

  local dev_mm
  if ! dev_mm="$(_pf_efi_device_major_minor "$canonical")"; then
    die "PF-10: could not determine device identity: $canonical"
  fi
  [[ -n "$dev_mm" ]] || die "PF-10: empty device identity for: $canonical"

  # Check if ANY mount point has this device's major:minor.
  # We cannot rely on findmnt -S (source-string match) because the device
  # may have been mounted through a different alias (e.g. /dev/sda1 vs
  # /dev/disk/by-uuid/...).  Instead, parse /proc/self/mountinfo directly
  # and compare MAJ:MIN (field 3) against the canonical device's identity.
  local mounted_mm
  mounted_mm="$(awk -v target="$dev_mm" '$3 == target { print $3; found=1; exit } END { if (!found) exit 1 }' /proc/self/mountinfo 2>/dev/null)" || mounted_mm=""

  if [[ -n "$mounted_mm" ]]; then
    die "PF-10: EFI device is already mounted: $canonical (major:minor $mounted_mm)"
  fi

  debug "PF-10: EFI device is not mounted elsewhere: $canonical (major:minor $dev_mm)"
}

# preflight_efi_existing_mount_correct EFIMNT EFI_DEVICE
#   PF-11: For existing mount mode, fully validate the existing mount:
#   - Verifies the path is actually a mountpoint (mountpoint -q).
#   - Retrieves MAJ:MIN, FSTYPE, and FSROOT via findmnt.
#   - Requires FSTYPE to be FAT (vfat/fat/fat32).
#   - Requires FSROOT to be / (prevents subdirectory bind mounts).
#   - Verifies the backing device's major:minor matches the expected device.
preflight_efi_existing_mount_correct() {
  local mountpoint="${1:?preflight_efi_existing_mount_correct: missing mountpoint}"
  local device="${2:?preflight_efi_existing_mount_correct: missing device path}"

  # Verify it's actually a mountpoint.
  if ! mountpoint -q "$mountpoint" 2>/dev/null; then
    die "PF-11: path is not a mountpoint: $mountpoint"
  fi

  # Get mount properties via findmnt.
  local mount_mm mount_fstype mount_fsroot
  mount_mm="$(findmnt -nro MAJ:MIN -M "$mountpoint" 2>/dev/null | head -1)" || mount_mm=""
  mount_fstype="$(findmnt -nro FSTYPE -M "$mountpoint" 2>/dev/null | head -1)" || mount_fstype=""
  mount_fsroot="$(findmnt -nro FSROOT -M "$mountpoint" 2>/dev/null | head -1)" || mount_fsroot=""

  if [[ -z "$mount_mm" ]]; then
    die "PF-11: cannot determine backing device for EFI mount: $mountpoint"
  fi

  # Validate FSTYPE.
  case "$mount_fstype" in
    vfat | fat | fat32) ;;
    *) die "PF-11: EFI mount has unexpected filesystem type ($mount_fstype): $mountpoint" ;;
  esac

  # Validate FSROOT is / (not a subdirectory bind mount).
  if [[ "$mount_fsroot" != "/" ]]; then
    die "PF-11: EFI mount has non-root FSROOT ($mount_fsroot) — possible subdirectory bind mount: $mountpoint"
  fi

  # Validate device identity by major:minor.
  local canonical_dev dev_mm
  if ! canonical_dev="$(_pf_efi_canonicalize_device "$device")"; then
    die "PF-11: could not resolve EFI device: $device"
  fi
  [[ -n "$canonical_dev" ]] || die "PF-11: empty canonical device for: $device"

  if ! dev_mm="$(_pf_efi_device_major_minor "$canonical_dev")"; then
    die "PF-11: could not determine device identity: $canonical_dev"
  fi
  [[ -n "$dev_mm" ]] || die "PF-11: empty device identity for: $canonical_dev"

  if [[ "$mount_mm" != "$dev_mm" ]]; then
    die "PF-11: EFI mount does not match target device (mount major:minor=$mount_mm, device major:minor=$dev_mm)"
  fi

  debug "PF-11: EFI existing mount is correct (major:minor $mount_mm, fstype=$mount_fstype, fsroot=$mount_fsroot)"
}

# preflight_efi_existing_mount_writable EFIMNT
#   PF-12: For existing mount mode, verify the mount is writable.
#   - Requires mount options to be available.
#   - Rejects 'ro' (read-only) flag.
#   - Requires explicit 'rw' flag present (not just absence of 'ro').
preflight_efi_existing_mount_writable() {
  local mountpoint="${1:?preflight_efi_existing_mount_writable: missing mountpoint}"

  local mount_opts
  mount_opts="$(findmnt -nro OPTIONS "$mountpoint" 2>/dev/null)" || mount_opts=""

  if [[ -z "$mount_opts" ]]; then
    die "PF-12: cannot determine mount options for EFI mount: $mountpoint"
  fi

  # Check for explicit 'ro' (read-only).
  if [[ ",$mount_opts," =~ ,ro, || "$mount_opts" == ro || "$mount_opts" =~ ^ro, || "$mount_opts" =~ ,ro$ ]]; then
    die "PF-12: EFI mount is not writable (mounted read-only): $mountpoint"
  fi

  # Verify 'rw' is explicitly present (not just absence of 'ro').
  if ! [[ ",$mount_opts," =~ ,rw, || "$mount_opts" == rw || "$mount_opts" =~ ^rw, || "$mount_opts" =~ ,rw$ ]]; then
    die "PF-12: EFI mount options do not include 'rw' flag: $mountpoint (options: $mount_opts)"
  fi

  debug "PF-12: EFI existing mount is writable (options: $mount_opts)"
}

# preflight_efi_mountable EFI_DEVICE EFIMNT
#   PF-13: Mount the EFI device at the given mountpoint.  Dies if mount
#   fails.  This function does NOT install any cleanup trap -- the mount
#   lifecycle is owned by the caller (outer transaction).
#   The mountpoint directory must already exist (created by PF-09 or the caller).
preflight_efi_mountable() {
  local device="${1:?preflight_efi_mountable: missing device path}"
  local mountpoint="${2:?preflight_efi_mountable: missing mountpoint}"

  # Directory should already exist (created by PF-09 or the caller).
  if [[ ! -d "$mountpoint" ]]; then
    die "PF-13: EFI mountpoint does not exist: $mountpoint"
  fi

  if ! mount -o rw "$device" "$mountpoint" 2>/dev/null; then
    die "PF-13: could not mount EFI device (corrupt or unsupported filesystem): $device -> $mountpoint"
  fi

  debug "PF-13: EFI device mounted: $device -> $mountpoint"
}

# preflight_efi_reject_corrupt EFI_DEVICE
#   PF-14: Verify the device's partition metadata is consistent with a valid
#   FAT EFI partition using blkid.  Does NOT mount the device (PF-13 will
#   handle the actual mount and catch mount-time corruption).
#   Does NOT require SEC_TYPE — real SteamOS EFI partitions may not report
#   it.
preflight_efi_reject_corrupt() {
  local device="${1:?preflight_efi_reject_corrupt: missing device path}"

  # Validate partition metadata is consistent with a valid FAT EFI partition.
  # Real SteamOS partitions may not report SEC_TYPE — do NOT require it.

  local fstype
  fstype="$(blkid -s TYPE -o value "$device" 2>/dev/null)" || fstype=""
  case "$fstype" in
    vfat | fat | fat32) ;;
    *) die "PF-14: EFI partition has unexpected filesystem type (${fstype:-<unknown>}): $device" ;;
  esac

  # PARTUUID should be present for a real partition.
  local partuuid
  partuuid="$(blkid -s PARTUUID -o value "$device" 2>/dev/null)" || partuuid=""
  if [[ -z "$partuuid" ]]; then
    die "PF-14: EFI partition has no PARTUUID (may be corrupt or not a real partition): $device"
  fi

  debug "PF-14: EFI partition metadata is valid (TYPE=$fstype, PARTUUID=$partuuid): $device"
}

# preflight_efi_accepts_writes EFI_DEVICE EFIMNT
#   PF-15: Verify the mounted EFI filesystem accepts writes by creating
#   and removing a temporary file.
#   A RETURN trap ensures the test file is removed on all exit paths,
#   including interruptions between mktemp and the explicit rm.
preflight_efi_accepts_writes() {
  local device="${1:?preflight_efi_accepts_writes: missing device path}"
  local mountpoint="${2:?preflight_efi_accepts_writes: missing mountpoint}"

  local test_file
  test_file="$(mktemp "$mountpoint/.preflight-writable-XXXXXX" 2>/dev/null)" \
    || die "PF-15: EFI filesystem is not writable (cannot create file in $mountpoint): $device"

  # Guarantee cleanup on any exit path (RETURN, ERR, signal).
  trap 'rm -f "$test_file" 2>/dev/null' RETURN

  rm -f "$test_file" 2>/dev/null \
    || die "PF-15: EFI filesystem is not writable (cannot remove test file): $device"

  debug "PF-15: EFI filesystem accepts writes: $mountpoint"
}

# ---------------------------------------------------------------------------
# Orchestrators
# ---------------------------------------------------------------------------

# preflight_efi_validate_temporary EFI_DEVICE EFIMNT SLOT_LABEL [EXPECTED_DEVICE]
#   Validate the EFI device for temporary mount mode.
#   Mounts the device at EFIMNT and verifies it is writable.  Does NOT
#   install any RETURN trap for cleanup — the caller (outer transaction)
#   owns the mount lifecycle and must unmount when done.
#   An optional fourth argument EXPECTED_DEVICE skips the /dev/disk/by-partsets
#   lookup in the slot identity check (used in build fixtures where partsets
#   may not exist).
preflight_efi_validate_temporary() {
  local device="${1:?preflight_efi_validate_temporary: missing device path}"
  local mountpoint="${2:?preflight_efi_validate_temporary: missing mountpoint}"
  local slot="${3:?preflight_efi_validate_temporary: missing slot label}"
  local expected_dev="${4:-}"

  debug "preflight_efi_validate_temporary: validating $device for slot $slot"

  # PF-06: Block device check.
  preflight_efi_is_block_device "$device"

  # PF-07: FAT filesystem check.
  preflight_efi_filesystem_is_fat "$device"

  # PF-08: Slot identity check.
  if [[ -n "$expected_dev" ]]; then
    preflight_efi_matches_slot "$device" "$slot" "$expected_dev"
  else
    preflight_efi_matches_slot "$device" "$slot"
  fi

  # PF-09: Mountpoint safety check.
  preflight_efi_mountpoint_safe "$mountpoint"

  # PF-10: Device not already mounted.
  preflight_efi_not_mounted_elsewhere "$device"

  # PF-14: Reject corrupt partition (metadata probe — no mount).
  preflight_efi_reject_corrupt "$device"

  # PF-13: Mount the device.
  preflight_efi_mountable "$device" "$mountpoint"

  # PF-15: Write test.
  preflight_efi_accepts_writes "$device" "$mountpoint"

  debug "preflight_efi_validate_temporary: all checks passed for $device"
}

# preflight_efi_validate_existing EFIMNT EFI_DEVICE SLOT_LABEL [EXPECTED_DEVICE]
#   Validate an existing EFI mount for reuse.
#   Verifies the mount is backed by the correct device and is writable.
#   An optional fourth argument EXPECTED_DEVICE skips the
#   /dev/disk/by-partsets lookup in the slot identity check.
preflight_efi_validate_existing() {
  local mountpoint="${1:?preflight_efi_validate_existing: missing mountpoint}"
  local device="${2:?preflight_efi_validate_existing: missing device path}"
  local slot="${3:?preflight_efi_validate_existing: missing slot label}"
  local expected_dev="${4:-}"

  debug "preflight_efi_validate_existing: validating existing mount $mountpoint for device $device (slot $slot)"

  # PF-06: Block device check.
  preflight_efi_is_block_device "$device"

  # PF-07: FAT filesystem check.
  preflight_efi_filesystem_is_fat "$device"

  # PF-08: Slot identity check.
  if [[ -n "$expected_dev" ]]; then
    preflight_efi_matches_slot "$device" "$slot" "$expected_dev"
  else
    preflight_efi_matches_slot "$device" "$slot"
  fi

  # PF-11: Existing mount is backed by the correct device.
  preflight_efi_existing_mount_correct "$mountpoint" "$device"

  # PF-12: Existing mount is writable.
  preflight_efi_existing_mount_writable "$mountpoint"

  # PF-15: Write test under existing mount.
  preflight_efi_accepts_writes "$device" "$mountpoint"

  debug "preflight_efi_validate_existing: all checks passed for $mountpoint ($device)"
}
