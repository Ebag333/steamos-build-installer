#!/bin/bash
#
# steamos-build-installer — lib/preflight_esp.sh
# Shared ESP validation: ensures the shared ESP partition is a valid FAT
# filesystem, is mounted and writable, belongs to the expected PARTUUID,
# and is a different block device from the per-slot EFI partition.
# Called by the build pipeline before any shared-ESP writes begin.
#
# Requires: lib/common.sh (die, debug)
#           lib/preflight_efi.sh (_canonicalize_efi_device, _efi_dev_major_minor)
# Do not run it directly.
#
# Contract: EXPECTED_PARTUUID must be sourced from independently validated
# GPT or topology state (e.g., the shared partition discovered during
# topology enumeration), NOT from the same possibly-stale partset file
# being replaced. Callers must ensure provenance before calling this module.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/preflight_esp.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Source preflight_efi.sh for _canonicalize_efi_device and _efi_dev_major_minor.
# TODO: these should move to a shared device-identity library to reduce coupling.
_PF_ESP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=preflight_efi.sh
source "${_PF_ESP_DIR}/preflight_efi.sh"
unset _PF_ESP_DIR

# ---------------------------------------------------------------------------
# Preflight checks — independently callable
# ---------------------------------------------------------------------------

# preflight_esp_matches_partuuid ESP_DEVICE EXPECTED_PARTUUID
#   PF-37: Verify the shared ESP's PARTUUID matches the expected value
#   (case-insensitive comparison).  The expected PARTUUID must come from
#   independently validated GPT/topology state (e.g., the discovered
#   shared-partition topology), not from a possibly stale partset file.
#   Dies on mismatch or if PARTUUID is unavailable for either device.
#
#   Future enhancements could also validate:
#   - Expected PARTLABEL
#   - Expected parent disk
#   - Expected GPT partition type GUID
#   - Distinctness from rootfs, VAR, and per-slot EFI devices
preflight_esp_matches_partuuid() {
  local device="${1:?preflight_esp_matches_partuuid: missing device path}"
  local expected="${2:?preflight_esp_matches_partuuid: missing expected PARTUUID}"

  local canonical
  canonical="$(_canonicalize_efi_device "$device" 2>/dev/null)" || true
  if [[ -z "$canonical" ]]; then
    die "could not canonicalize device: $device"
  fi

  local actual
  actual="$(blkid -s PARTUUID -o value "$canonical" 2>/dev/null)" || actual=""

  if [[ -z "$actual" ]]; then
    die "PF-37: ESP PARTUUID is unavailable for $canonical"
  fi

  if [[ -z "$expected" ]]; then
    die "PF-37: expected PARTUUID is empty for comparison"
  fi

  if [[ "${actual,,}" != "${expected,,}" ]]; then
    die "PF-37: ESP PARTUUID mismatch (actual: $actual, expected: $expected) for $canonical"
  fi

  # After the PARTUUID match succeeds, verify uniqueness.
  local all_matches
  all_matches="$(blkid -t "PARTUUID=${expected}" -o device 2>/dev/null)" || all_matches=""

  # Count unique canonical devices (not just paths — same device can appear
  # as /dev/sda1 and /dev/disk/...).
  local unique_count=0
  local seen_mm=""
  local match_dev
  for match_dev in $all_matches; do
    local match_canonical
    match_canonical="$(_canonicalize_efi_device "$match_dev" 2>/dev/null)" || continue
    local match_mm
    match_mm="$(_efi_dev_major_minor "$match_canonical" 2>/dev/null)" || continue
    if [[ "$match_mm" != "$seen_mm" ]]; then
      seen_mm="$match_mm"
      unique_count=$((unique_count + 1))
    fi
  done

  if [[ "$unique_count" -gt 1 ]]; then
    die "PF-37: PARTUUID $expected resolves to $unique_count distinct block devices — expected exactly one"
  fi

  debug "PF-37: PARTUUID $expected resolves uniquely to $canonical ($actual)"
}

# preflight_esp_is_fat_and_writable ESP_MOUNT ESP_DEVICE
#   PF-38: Verify the shared ESP is mounted at ESP_DEVICE's mountpoint,
#   has a FAT filesystem, is writable, and is not a bind-mounted
#   subdirectory.  Validates MAJ:MIN match, FSTYPE, FSROOT, and rw
#   option via findmnt; then performs a temporary-file write test.
#   Dies on any failure.
preflight_esp_is_fat_and_writable() {
  local mountpoint="${1:?preflight_esp_is_fat_and_writable: missing ESP mountpoint}"
  local device="${2:?preflight_esp_is_fat_and_writable: missing device path}"

  # 1. Canonicalize device (safe pattern)
  local canonical
  canonical="$(_canonicalize_efi_device "$device" 2>/dev/null)" || true
  if [[ -z "$canonical" ]]; then
    die "could not canonicalize device: $device"
  fi

  # 2. Check mountpoint exists
  if ! mountpoint -q "$mountpoint" 2>/dev/null; then
    die "PF-38: ESP is not mounted at $mountpoint"
  fi

  # 3. Verify MAJ:MIN match between mount and device
  local mounted_mm
  mounted_mm="$(findmnt -nro MAJ:MIN -M "$mountpoint" 2>/dev/null)" || mounted_mm=""
  if [[ -z "$mounted_mm" ]]; then
    die "PF-38: could not determine backing device for ESP mountpoint $mountpoint"
  fi

  local expected_mm
  expected_mm="$(_efi_dev_major_minor "$canonical" 2>/dev/null)" || true
  if [[ -z "$expected_mm" ]]; then
    die "PF-38: could not determine major:minor for expected ESP device $canonical"
  fi

  if [[ "$mounted_mm" != "$expected_mm" ]]; then
    die "PF-38: ESP mountpoint $mountpoint is backed by device with MAJ:MIN $mounted_mm, but expected $canonical ($expected_mm)"
  fi

  # 4. Verify mounted filesystem properties via findmnt
  local mounted_fstype mounted_opts mounted_fsroot
  mounted_fstype="$(findmnt -nro FSTYPE -M "$mountpoint" 2>/dev/null)" || mounted_fstype=""
  mounted_opts="$(findmnt -nro OPTIONS -M "$mountpoint" 2>/dev/null)" || mounted_opts=""
  mounted_fsroot="$(findmnt -nro FSROOT -M "$mountpoint" 2>/dev/null)" || mounted_fsroot=""

  case "$mounted_fstype" in
    vfat | fat | fat32) ;;
    *) die "PF-38: ESP mountpoint $mountpoint has unexpected filesystem type: ${mounted_fstype:-<unknown>} (expected FAT)" ;;
  esac

  # 5. Verify FSROOT=/
  if [[ "$mounted_fsroot" != "/" ]]; then
    die "PF-38: ESP mountpoint $mountpoint has FSROOT='$mounted_fsroot' — expected '/' (possible bind-mounted subdirectory)"
  fi

  # 6. Verify rw option
  if [[ ",$mounted_opts," != *",rw,"* && "$mounted_opts" != "rw" ]]; then
    die "PF-38: ESP mountpoint $mountpoint is not read-write (options: $mounted_opts)"
  fi

  # 7. Write test — write + remove in subshell for guaranteed cleanup
  if ! ( test_file="$(mktemp "$mountpoint/.preflight-esp-writable-XXXXXX")" \
    && rm -f "$test_file" ) 2>/dev/null; then
    die "PF-38: ESP filesystem is not writable at $mountpoint: $canonical"
  fi

  # 8. Debug success message
  debug "PF-38: ESP is FAT and writable: $mountpoint ($canonical)"
}

# preflight_esp_distinct_from_efi ESP_DEVICE EFI_DEVICE
#   PF-39: Verify the shared ESP and the per-slot EFI partition are
#   different block devices by comparing their major:minor numbers.
#   Dies if they resolve to the same device.
preflight_esp_distinct_from_efi() {
  local esp_device="${1:?preflight_esp_distinct_from_efi: missing ESP device path}"
  local efi_device="${2:?preflight_esp_distinct_from_efi: missing EFI device path}"

  local canonical_esp canonical_efi
  canonical_esp="$(_canonicalize_efi_device "$esp_device" 2>/dev/null)" || true
  if [[ -z "$canonical_esp" ]]; then
    die "could not canonicalize device: $esp_device"
  fi
  canonical_efi="$(_canonicalize_efi_device "$efi_device" 2>/dev/null)" || true
  if [[ -z "$canonical_efi" ]]; then
    die "could not canonicalize device: $efi_device"
  fi

  local esp_mm efi_mm
  esp_mm="$(_efi_dev_major_minor "$canonical_esp" 2>/dev/null)" || true
  if [[ -z "$esp_mm" ]]; then
    die "could not determine major:minor for: $canonical_esp"
  fi
  efi_mm="$(_efi_dev_major_minor "$canonical_efi" 2>/dev/null)" || true
  if [[ -z "$efi_mm" ]]; then
    die "could not determine major:minor for: $canonical_efi"
  fi

  if [[ "$esp_mm" == "$efi_mm" ]]; then
    die "PF-39: ESP and EFI are the same block device ($canonical_esp, major:minor $esp_mm)"
  fi

  debug "PF-39: ESP and EFI are distinct devices (ESP=$canonical_esp/$esp_mm, EFI=$canonical_efi/$efi_mm)"
}

# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

# preflight_esp_validate ESP_MOUNT ESP_DEVICE EFI_DEVICE EXPECTED_PARTUUID
#   Run the full shared ESP validation sequence:
#     PF-39  ESP and EFI are different block devices
#     PF-37  PARTUUID matches expected (case-insensitive), unique
#     PF-38  FAT filesystem, mounted at ESP_MOUNT, backed by ESP_DEVICE,
#            writable, FSROOT=/, read-write
#   Dies on the first failure; returns 0 when all checks pass.
#
#   ESP_DEVICE and EFI_DEVICE must be independently validated block devices.
#   EXPECTED_PARTUUID must come from independently verified GPT/topology state.
preflight_esp_validate() {
  local esp_mount="${1:?preflight_esp_validate: missing ESP mountpoint}"
  local esp_device="${2:?preflight_esp_validate: missing ESP device path}"
  local efi_device="${3:?preflight_esp_validate: missing EFI device path}"
  local expected_partuuid="${4:?preflight_esp_validate: missing expected PARTUUID}"

  debug "preflight_esp_validate: validating shared ESP (mount=$esp_mount device=$esp_device efi=$efi_device)"

  # PF-39: ESP and EFI are different block devices — check EARLY, before any writes.
  preflight_esp_distinct_from_efi "$esp_device" "$efi_device"

  # PF-37: PARTUUID matches expected.
  preflight_esp_matches_partuuid "$esp_device" "$expected_partuuid"

  # PF-38: FAT filesystem, mounted, writable — write probe happens LAST.
  preflight_esp_is_fat_and_writable "$esp_mount" "$esp_device"

  debug "preflight_esp_validate: all shared ESP checks passed"
}
