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

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/preflight_esp.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Source preflight_efi.sh to reuse its internal helpers.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=preflight_efi.sh
source "${SCRIPT_DIR}/preflight_efi.sh"

# ---------------------------------------------------------------------------
# Preflight checks — independently callable
# ---------------------------------------------------------------------------

# preflight_esp_matches_partuuid ESP_DEVICE EXPECTED_PARTUUID
#   PF-37: Verify the shared ESP's PARTUUID matches the expected value
#   (case-insensitive comparison).  Dies on mismatch or if PARTUUID
#   is unavailable for either device.
preflight_esp_matches_partuuid() {
  local device="${1:?preflight_esp_matches_partuuid: missing device path}"
  local expected="${2:?preflight_esp_matches_partuuid: missing expected PARTUUID}"

  local canonical
  canonical="$(_canonicalize_efi_device "$device")"

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

  debug "PF-37: ESP PARTUUID matches expected: $actual for $canonical"
}

# preflight_esp_is_fat_and_writable ESP_MOUNT ESP_DEVICE
#   PF-38: Verify the shared ESP has a FAT filesystem (blkid probe) and
#   is mounted at ESP_MOUNT with write access.  The writable check uses
#   a temporary-file test: a file is created and removed.  Dies on any
#   failure.
preflight_esp_is_fat_and_writable() {
  local mountpoint="${1:?preflight_esp_is_fat_and_writable: missing ESP mountpoint}"
  local device="${2:?preflight_esp_is_fat_and_writable: missing device path}"

  # --- FAT filesystem check (blkid probe, no mount required) ---
  local canonical
  canonical="$(_canonicalize_efi_device "$device")"

  local fstype
  fstype="$(blkid -s TYPE -o value "$canonical" 2>/dev/null)" || fstype=""

  case "$fstype" in
    vfat | fat | fat32)
      debug "PF-38: ESP filesystem is FAT ($fstype): $canonical"
      ;;
    *)
      die "PF-38: ESP is not FAT (detected: ${fstype:-<unknown>}): $canonical"
      ;;
  esac

  # --- Mounted check ---
  if ! mountpoint -q "$mountpoint" 2>/dev/null; then
    die "PF-38: ESP is not mounted at $mountpoint"
  fi

  # --- Writable check (temporary-file write test) ---
  local test_file
  test_file="$(mktemp "$mountpoint/.preflight-esp-writable-XXXXXX" 2>/dev/null)" \
    || die "PF-38: ESP filesystem is not writable (cannot create file in $mountpoint): $canonical"

  rm -f "$test_file" 2>/dev/null \
    || die "PF-38: ESP filesystem is not writable (cannot remove test file): $canonical"

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
  canonical_esp="$(_canonicalize_efi_device "$esp_device")"
  canonical_efi="$(_canonicalize_efi_device "$efi_device")"

  local esp_mm efi_mm
  esp_mm="$(_efi_dev_major_minor "$canonical_esp")"
  efi_mm="$(_efi_dev_major_minor "$canonical_efi")"

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
#     PF-37  PARTUUID matches expected (case-insensitive)
#     PF-38  FAT filesystem, mounted, writable
#     PF-39  ESP and EFI are different block devices
#   Dies on the first failure; returns 0 when all checks pass.
preflight_esp_validate() {
  local esp_mount="${1:?preflight_esp_validate: missing ESP mountpoint}"
  local esp_device="${2:?preflight_esp_validate: missing ESP device path}"
  local efi_device="${3:?preflight_esp_validate: missing EFI device path}"
  local expected_partuuid="${4:?preflight_esp_validate: missing expected PARTUUID}"

  debug "preflight_esp_validate: validating shared ESP (mount=$esp_mount device=$esp_device efi=$efi_device)"

  # PF-37: PARTUUID matches expected.
  preflight_esp_matches_partuuid "$esp_device" "$expected_partuuid"

  # PF-38: FAT filesystem, mounted, writable.
  preflight_esp_is_fat_and_writable "$esp_mount" "$esp_device"

  # PF-39: ESP and EFI are different block devices.
  preflight_esp_distinct_from_efi "$esp_device" "$efi_device"

  debug "preflight_esp_validate: all shared ESP checks passed"
}
