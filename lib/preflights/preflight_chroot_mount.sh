#!/bin/bash
# steamos-build-installer — lib/preflight_chroot_mount.sh
# Chroot mount wiring validation: ensures the chroot's /efi and /esp
# mount points are backed by the correct block devices.
# Validates device identity via major:minor comparison, not path names.
# Validates mount properties (FSTYPE, FSROOT, rw) not just device identity.
# Called by the build pipeline after chroot mounts are set up.
# Requires: lib/common.sh (die, debug)
#           lib/preflight_efi.sh (_canonicalize_efi_device, _efi_dev_major_minor)

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/preflight_chroot_mount.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

_PF_CHROOT_MOUNT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=preflight_efi.sh
source "${_PF_CHROOT_MOUNT_DIR}/preflight_efi.sh"
unset _PF_CHROOT_MOUNT_DIR

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _pf_chroot_validate_mount CHROOT_ROOT MOUNTPOINT EXPECTED_DEVICE LABEL
#                                          EXPECTED_FSTYPE REQUIRE_RW REQUIRE_FSROOT
#   Comprehensive mount validation for a single mountpoint inside a chroot.
#   Checks:
#     - mountpoint exists (mountpoint -q)
#     - MAJ:MIN matches expected device
#     - FSTYPE matches EXPECTED_FSTYPE (if non-empty)
#     - OPTIONS contain "rw" (if REQUIRE_RW is true)
#     - FSROOT matches REQUIRE_FSROOT (if non-empty)
#   Dies on any failure. Returns 0 on success.
#   Sets global variables for caller use:
#     _PF_MOUNT_ACTUAL_MM, _PF_MOUNT_ACTUAL_FSTYPE, _PF_MOUNT_ACTUAL_OPTS, _PF_MOUNT_ACTUAL_FSROOT
_pf_chroot_validate_mount() {
  local chroot_root="${1:?_pf_chroot_validate_mount: missing chroot root}"
  local mountpoint="${2:?_pf_chroot_validate_mount: missing mountpoint}"
  local expected_device="${3:?_pf_chroot_validate_mount: missing expected device}"
  local label="${4:?_pf_chroot_validate_mount: missing label}"
  local expected_fstype="${5:-}"
  local require_rw="${6:-false}"
  local require_fsroot="${7:-}"

  local full_path="${chroot_root}${mountpoint}"

  # 1. Check mountpoint exists
  if ! mountpoint -q "$full_path" 2>/dev/null; then
    die "PF: $label ($mountpoint) is not mounted under $chroot_root"
  fi

  # 2. Get mount properties via findmnt (single call, no realpath)
  local findmnt_out
  findmnt_out="$(findmnt -nro MAJ:MIN,FSTYPE,OPTIONS,FSROOT -M "$full_path" 2>/dev/null)" \
    || die "PF: $label ($mountpoint): findmnt failed for $full_path"
  if [[ -z "$findmnt_out" ]]; then
    die "PF: $label ($mountpoint): findmnt returned empty for $full_path"
  fi

  # Parse findmnt output (space-separated fields)
  local actual_mm actual_fstype actual_opts actual_fsroot
  read -r actual_mm actual_fstype actual_opts actual_fsroot <<<"$findmnt_out"

  if [[ -z "$actual_mm" ]]; then
    die "PF: $label ($mountpoint): could not determine MAJ:MIN for $full_path"
  fi

  # 3. Get expected device's MAJ:MIN
  local canonical_expected
  canonical_expected="$(_canonicalize_efi_device "$expected_device" 2>/dev/null)" || true
  if [[ -z "$canonical_expected" ]]; then
    die "PF: $label: failed to canonicalize expected device '$expected_device'"
  fi

  local expected_mm
  expected_mm="$(_efi_dev_major_minor "$canonical_expected" 2>/dev/null)" || true
  if [[ -z "$expected_mm" ]]; then
    die "PF: $label: could not determine MAJ:MIN for expected device '$canonical_expected'"
  fi

  # 4. Compare MAJ:MIN
  if [[ "$actual_mm" != "$expected_mm" ]]; then
    die "PF: $label ($mountpoint): device mismatch — expected $canonical_expected ($expected_mm) but found $actual_mm"
  fi

  # 5. Compare FSTYPE if specified
  if [[ -n "$expected_fstype" && "$actual_fstype" != "$expected_fstype" ]]; then
    die "PF: $label ($mountpoint): filesystem type mismatch — expected $expected_fstype but found $actual_fstype"
  fi

  # 6. Check rw if required
  if [[ "$require_rw" == "true" ]]; then
    if [[ ",$actual_opts," != *",rw,"* && "$actual_opts" != "rw" ]]; then
      die "PF: $label ($mountpoint): mount is not read-write (options: $actual_opts)"
    fi
  fi

  # 7. Check FSROOT if specified
  if [[ -n "$require_fsroot" && "$actual_fsroot" != "$require_fsroot" ]]; then
    die "PF: $label ($mountpoint): FSROOT mismatch — expected '$require_fsroot' but found '$actual_fsroot'"
  fi

  # Store results for caller if needed
  _PF_MOUNT_ACTUAL_MM="$actual_mm"
  _PF_MOUNT_ACTUAL_FSTYPE="$actual_fstype"
  _PF_MOUNT_ACTUAL_OPTS="$actual_opts"
  _PF_MOUNT_ACTUAL_FSROOT="$actual_fsroot"

  debug "PF: $label ($mountpoint) — device=$canonical_expected ($actual_mm) fstype=$actual_fstype opts=$actual_opts fsroot=$actual_fsroot"
}

# _pf_chroot_check_pseudo_fs CHROOT_ROOT SUBPATH LABEL
#   Verify that a pseudo-filesystem (proc, sys, dev, etc.) is mounted
#   at the expected location under the chroot.
_pf_chroot_check_pseudo_fs() {
  local chroot_root="${1:?_pf_chroot_check_pseudo_fs: missing chroot root}"
  local subpath="${2:?_pf_chroot_check_pseudo_fs: missing subpath}"
  local label="${3:-$subpath}"

  local full_path="${chroot_root}${subpath}"

  if ! mountpoint -q "$full_path" 2>/dev/null; then
    die "PF: $label ($subpath) is not mounted under $chroot_root"
  fi

  debug "PF: $label ($subpath) is mounted"
}

# ---------------------------------------------------------------------------
# Preflight checks — independently callable
# ---------------------------------------------------------------------------

# preflight_chroot_mount_rootfs_wired CHROOT_ROOT EXPECTED_ROOTFS_DEVICE
#   PF-49c: Verify that $CHROOT_ROOT itself is backed by the expected rootfs device.
preflight_chroot_mount_rootfs_wired() {
  local chroot_root="${1:?preflight_chroot_mount_rootfs_wired: missing chroot root}"
  local expected_rootfs="${2:?preflight_chroot_mount_rootfs_wired: missing expected rootfs device}"

  # CHROOT_ROOT must itself be a mountpoint
  if ! mountpoint -q "$chroot_root" 2>/dev/null; then
    die "PF-49c: chroot root $chroot_root is not a mountpoint"
  fi

  # Get rootfs mount properties
  local findmnt_out
  findmnt_out="$(findmnt -nro MAJ:MIN -M "$chroot_root" 2>/dev/null)" \
    || die "PF-49c: findmnt failed for chroot root $chroot_root"
  if [[ -z "$findmnt_out" ]]; then
    die "PF-49c: findmnt returned empty for chroot root $chroot_root"
  fi

  local actual_mm
  actual_mm="$findmnt_out"

  # Get expected rootfs device MAJ:MIN
  local canonical_expected
  canonical_expected="$(_canonicalize_efi_device "$expected_rootfs" 2>/dev/null)" || true
  if [[ -z "$canonical_expected" ]]; then
    die "PF-49c: failed to canonicalize expected rootfs device '$expected_rootfs'"
  fi

  local expected_mm
  expected_mm="$(_efi_dev_major_minor "$canonical_expected" 2>/dev/null)" || true
  if [[ -z "$expected_mm" ]]; then
    die "PF-49c: could not determine MAJ:MIN for expected rootfs device '$canonical_expected'"
  fi

  if [[ "$actual_mm" != "$expected_mm" ]]; then
    die "PF-49c: chroot rootfs device mismatch — expected $canonical_expected ($expected_mm) but found $actual_mm"
  fi

  debug "PF-49c: chroot rootfs wiring OK — $canonical_expected ($actual_mm)"
}

# preflight_chroot_mount_efi_wired CHROOT_ROOT EXPECTED_EFI_DEVICE
#   PF-49a: Verify that /efi inside the chroot is backed by the expected EFI device.
#   Requires: FAT type, read-write, FSROOT=/
preflight_chroot_mount_efi_wired() {
  local chroot_root="${1:?preflight_chroot_mount_efi_wired: missing chroot root}"
  local expected_efi="${2:?preflight_chroot_mount_efi_wired: missing expected EFI device}"

  _pf_chroot_validate_mount "$chroot_root" "/efi" "$expected_efi" "PF-49a" "vfat" "true" "/"
}

# preflight_chroot_mount_esp_wired CHROOT_ROOT EXPECTED_ESP_DEVICE
#   PF-49b: Verify that /esp inside the chroot is backed by the expected ESP device.
#   Requires: FAT type, read-write, FSROOT=/
#   If /esp is not mounted, this is a hard fail (ESP was expected).
preflight_chroot_mount_esp_wired() {
  local chroot_root="${1:?preflight_chroot_mount_esp_wired: missing chroot root}"
  local expected_esp="${2:?preflight_chroot_mount_esp_wired: missing expected ESP device}"

  _pf_chroot_validate_mount "$chroot_root" "/esp" "$expected_esp" "PF-49b" "vfat" "true" "/"
}

# preflight_chroot_mount_pseudo_fs CHROOT_ROOT
#   PF-49d: Verify that required pseudo-filesystems are mounted under the chroot.
preflight_chroot_mount_pseudo_fs() {
  local chroot_root="${1:?preflight_chroot_mount_pseudo_fs: missing chroot root}"

  _pf_chroot_check_pseudo_fs "$chroot_root" "/proc" "proc"
  _pf_chroot_check_pseudo_fs "$chroot_root" "/sys" "sysfs"
  _pf_chroot_check_pseudo_fs "$chroot_root" "/dev" "devtmpfs"
  _pf_chroot_check_pseudo_fs "$chroot_root" "/dev/pts" "devpts"

  debug "PF-49d: pseudo-filesystem checks passed"
}

# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

# preflight_chroot_mount_validate CHROOT_ROOT EXPECTED_ROOTFS_DEVICE EXPECTED_EFI_DEVICE [EXPECTED_ESP_DEVICE]
#   Master preflight for chroot mount wiring.
#   - Canonicalizes CHROOT_ROOT and rejects non-absolute or non-existent paths.
#   - PF-49c: $CHROOT_ROOT must be mounted and backed by EXPECTED_ROOTFS_DEVICE.
#   - PF-49a: /efi must be mounted and backed by the expected EFI device (FAT, rw, FSROOT=/).
#   - PF-49b: /esp must be mounted and backed by the expected ESP device (FAT, rw, FSROOT=/)
#              if EXPECTED_ESP_DEVICE is provided; otherwise skipped.
#   - EFI device and ESP device must be different (different MAJ:MIN).
#   - PF-49d: required pseudo-filesystems must be mounted.
preflight_chroot_mount_validate() {
  local chroot_root="${1:?preflight_chroot_mount_validate: missing chroot root}"
  local expected_rootfs="${2:?preflight_chroot_mount_validate: missing expected rootfs device}"
  local expected_efi="${3:?preflight_chroot_mount_validate: missing expected EFI device}"
  local expected_esp="${4:-}"

  # Canonicalize chroot root — must be absolute and exist
  chroot_root="$(realpath -e "$chroot_root" 2>/dev/null)" \
    || die "preflight_chroot_mount_validate: cannot canonicalize chroot root '$1' (must be an absolute, existing path)"
  if [[ "$chroot_root" != /* ]]; then
    die "preflight_chroot_mount_validate: chroot root must be absolute, got '$chroot_root'"
  fi

  debug "preflight_chroot_mount_validate: validating chroot mounts (root=$chroot_root rootfs=$expected_rootfs efi=$expected_efi esp=${expected_esp:-<none>})"

  # PF-49c: rootfs wiring check (required).
  preflight_chroot_mount_rootfs_wired "$chroot_root" "$expected_rootfs"

  # PF-49a: /efi wiring check (required).
  preflight_chroot_mount_efi_wired "$chroot_root" "$expected_efi"

  # Track EFI major:minor for separation check
  local efi_mm="$_PF_MOUNT_ACTUAL_MM"

  # PF-49b: /esp wiring check (optional, skipped if not provided).
  if [[ -n "$expected_esp" ]]; then
    preflight_chroot_mount_esp_wired "$chroot_root" "$expected_esp"

    # PF-50: EFI and ESP must be different devices
    local esp_mm="$_PF_MOUNT_ACTUAL_MM"
    if [[ "$efi_mm" == "$esp_mm" ]]; then
      die "preflight_chroot_mount_validate: EFI and ESP appear to be the same device ($efi_mm) — they must be separate block devices"
    fi
    debug "preflight_chroot_mount_validate: EFI ($efi_mm) and ESP ($esp_mm) are separate devices — OK"
  else
    debug "preflight_chroot_mount_validate: no expected ESP device provided — skipping PF-49b"
  fi

  # PF-49d: pseudo-filesystem checks
  preflight_chroot_mount_pseudo_fs "$chroot_root"

  debug "preflight_chroot_mount_validate: all chroot mount checks passed"
}
