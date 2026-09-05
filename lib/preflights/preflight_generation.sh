#!/bin/bash
#
# steamos-build-installer — lib/preflight_generation.sh
# Generation prerequisite validation: ensures all tools, paths, and boot
# artifacts required for GRUB image generation are present and valid in the
# target rootfs before any modification begins.
#
# Source artifacts (EFI binaries, allowlist) are NOT portable — their absence
# must never prevent generation.  PF-24 and PF-25 only warn.
#
# Requires: lib/common.sh (die, debug, warn)
# Do not run it directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/preflight_generation.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _resolve_rootfs_uuid ROOTFS
#   Determine the Btrfs UUID of the filesystem that backs ROOTFS.
#   Uses findmnt to locate the device, then blkid to extract UUID.
#   Prints the UUID string on success; dies on failure.
_resolve_rootfs_uuid() {
  local rootfs="${1:?_resolve_rootfs_uuid: missing rootfs path}"

  local device
  device="$(findmnt -rn -o SOURCE "$rootfs" 2>/dev/null | head -1)" \
    || die "_resolve_rootfs_uuid: findmnt failed for $rootfs"

  [[ -n "$device" ]] \
    || die "_resolve_rootfs_uuid: findmnt returned empty device for $rootfs"

  # Resolve device-mapper / md / LVM symlinks to a real block device.
  local resolved
  resolved="$(realpath "$device" 2>/dev/null)" || resolved="$device"

  local uuid
  uuid="$(blkid -s UUID -o value "$resolved" 2>/dev/null)" || uuid=""

  [[ -n "$uuid" ]] \
    || die "_resolve_rootfs_uuid: blkid returned empty UUID for $resolved"

  echo "$uuid"
}

# _command_available ROOTFS CMD
#   Check whether CMD exists and is executable in the rootfs.
#   First tries a direct path resolution inside $rootfs; if that fails,
#   attempts a chroot probe.  Returns 0 if available, 1 otherwise.
#   Does NOT die — callers decide severity.
_command_available() {
  local rootfs="${1:?_command_available: missing rootfs path}"
  local cmd="${2:?_command_available: missing command name}"

  # Candidate paths to probe inside the rootfs.
  local -a search_paths=(
    "/usr/bin/$cmd"
    "/bin/$cmd"
    "/usr/sbin/$cmd"
    "/sbin/$cmd"
  )

  local candidate
  for candidate in "${search_paths[@]}"; do
    if [[ -x "$rootfs$candidate" ]]; then
      return 0
    fi
  done

  # Chroot probe — ask the rootfs itself whether the command is available.
  if chroot "$rootfs" command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

# _uuid_is_valid FORMAT
#   Return 0 if FORMAT looks like a valid UUID string (hex digits with
#   hyphens), 1 otherwise.  Handles standard (8-4-4-4-12) and short forms.
_uuid_is_valid() {
  local uuid="${1:?_uuid_is_valid: missing uuid}"
  [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# ---------------------------------------------------------------------------
# Preflight checks — independently callable
# ---------------------------------------------------------------------------

# preflight_generation_rootfs_uuid ROOTFS
#   PF-16: Verify the rootfs UUID is obtainable via findmnt + blkid.
#   Dies on failure.
preflight_generation_rootfs_uuid() {
  local rootfs="${1:?preflight_generation_rootfs_uuid: missing rootfs path}"

  local uuid
  uuid="$(_resolve_rootfs_uuid "$rootfs")" \
    || die "PF-16: cannot resolve rootfs UUID via findmnt + blkid: $rootfs"

  [[ -n "$uuid" ]] \
    || die "PF-16: rootfs UUID is empty: $rootfs"

  debug "PF-16: rootfs UUID resolved: $uuid ($rootfs)"
}

# preflight_generation_uuid_mutation_complete ROOTFS [EXPECTED_UUID]
#   PF-17: Verify the resolved UUID is non-empty and has valid format.
#   When EXPECTED_UUID is provided, also verify it matches — confirming
#   that a UUID mutation (e.g. during image cloning) has completed.
#   If EXPECTED_UUID is omitted, only validates format.
#   Dies on failure.
preflight_generation_uuid_mutation_complete() {
  local rootfs="${1:?preflight_generation_uuid_mutation_complete: missing rootfs path}"
  local expected_uuid="${2:-}"

  local uuid
  uuid="$(_resolve_rootfs_uuid "$rootfs")" \
    || die "PF-17: cannot resolve rootfs UUID: $rootfs"

  [[ -n "$uuid" ]] \
    || die "PF-17: rootfs UUID is empty (mutation may not have run): $rootfs"

  if ! _uuid_is_valid "$uuid"; then
    die "PF-17: rootfs UUID has invalid format: '$uuid' ($rootfs)"
  fi

  if [[ -n "$expected_uuid" ]]; then
    if [[ "${uuid,,}" != "${expected_uuid,,}" ]]; then
      die "PF-17: rootfs UUID '$uuid' does not match expected '$expected_uuid' ($rootfs)"
    fi
    debug "PF-17: rootfs UUID matches expected: $uuid ($rootfs)"
  else
    debug "PF-17: rootfs UUID is valid (no expected value to compare): $uuid"
  fi
}

# preflight_generation_grub_mkimage ROOTFS
#   PF-18: Verify grub-mkimage exists and is executable in the rootfs.
#   Dies on failure.
preflight_generation_grub_mkimage() {
  local rootfs="${1:?preflight_generation_grub_mkimage: missing rootfs path}"

  if ! _command_available "$rootfs" "grub-mkimage"; then
    die "PF-18: grub-mkimage not found or not executable in rootfs: $rootfs"
  fi

  debug "PF-18: grub-mkimage is available in rootfs: $rootfs"
}

# preflight_generation_grub_platform_files ROOTFS
#   PF-19: Verify /usr/lib/grub/x86_64-efi/ exists in the rootfs and
#   contains key EFI modules (linux.efi, normal.mod).
#   Dies on failure.
preflight_generation_grub_platform_files() {
  local rootfs="${1:?preflight_generation_grub_platform_files: missing rootfs path}"

  local grub_dir="$rootfs/usr/lib/grub/x86_64-efi"

  if [[ ! -d "$grub_dir" ]]; then
    die "PF-19: GRUB x86_64-efi modules directory not found: $grub_dir"
  fi

  # Check for key modules that grub-mkimage requires.
  # Accept either .mod or .efi variants (distribution-dependent naming).
  local found_linux=0 found_normal=0
  local entry
  for entry in "$grub_dir"/linux*; do
    if [[ -f "$entry" ]]; then
      found_linux=1
      break
    fi
  done

  for entry in "$grub_dir"/normal*; do
    if [[ -f "$entry" ]]; then
      found_normal=1
      break
    fi
  done

  if [[ "$found_linux" -eq 0 ]]; then
    die "PF-19: GRUB linux module not found in $grub_dir"
  fi

  if [[ "$found_normal" -eq 0 ]]; then
    die "PF-19: GRUB normal module not found in $grub_dir"
  fi

  debug "PF-19: GRUB platform files present: $grub_dir"
}

# preflight_generation_update_grub ROOTFS
#   PF-20: Verify update-grub exists and is executable in the rootfs.
#   Dies on failure.
preflight_generation_update_grub() {
  local rootfs="${1:?preflight_generation_update_grub: missing rootfs path}"

  if ! _command_available "$rootfs" "update-grub"; then
    die "PF-20: update-grub not found or not executable in rootfs: $rootfs"
  fi

  debug "PF-20: update-grub is available in rootfs: $rootfs"
}

# preflight_generation_boot_payload ROOTFS
#   PF-21: Verify at least one vmlinuz-* kernel image exists in the rootfs
#   /boot directory and has a matching initramfs-*.img companion.
#   Dies on failure.
preflight_generation_boot_payload() {
  local rootfs="${1:?preflight_generation_boot_payload: missing rootfs path}"

  local boot_dir="$rootfs/boot"

  if [[ ! -d "$boot_dir" ]]; then
    die "PF-21: /boot directory not found in rootfs: $boot_dir"
  fi

  local found_kernel=0
  local vmlinuz
  for vmlinuz in "$boot_dir"/vmlinuz-*; do
    [[ -f "$vmlinuz" ]] || continue
    found_kernel=1

    # Extract the version suffix (everything after vmlinuz-).
    local ver="${vmlinuz##*/vmlinuz-}"
    local initramfs="$boot_dir/initramfs-${ver}.img"

    if [[ ! -f "$initramfs" ]]; then
      die "PF-21: no matching initramfs for $vmlinuz (expected $initramfs)"
    fi

    debug "PF-21: boot payload found: vmlinuz-$ver + initramfs-$ver.img"
    # At least one valid pair is enough.
    return 0
  done

  if [[ "$found_kernel" -eq 0 ]]; then
    die "PF-21: no vmlinuz-* kernel found in $boot_dir"
  fi
}

# preflight_generation_steamos_partsets ROOTFS
#   PF-22: Verify steamos-partsets exists and is executable in the rootfs.
#   Dies on failure.
preflight_generation_steamos_partsets() {
  local rootfs="${1:?preflight_generation_steamos_partsets: missing rootfs path}"

  if ! _command_available "$rootfs" "steamos-partsets"; then
    die "PF-22: steamos-partsets not found or not executable in rootfs: $rootfs"
  fi

  debug "PF-22: steamos-partsets is available in rootfs: $rootfs"
}

# preflight_generation_steamos_bootconf ROOTFS
#   PF-23: Verify steamos-bootconf exists and is executable in the rootfs.
#   Dies on failure.
preflight_generation_steamos_bootconf() {
  local rootfs="${1:?preflight_generation_steamos_bootconf: missing rootfs path}"

  if ! _command_available "$rootfs" "steamos-bootconf"; then
    die "PF-23: steamos-bootconf not found or not executable in rootfs: $rootfs"
  fi

  debug "PF-23: steamos-bootconf is available in rootfs: $rootfs"
}

# preflight_generation_source_artifacts ROOTFS SOURCE_EFI_MOUNT
#   PF-24: Check that a source EFI binary is available at the given mount.
#   This check is advisory — source artifacts are NOT portable and their
#   absence must NOT prevent generation.  Only warns on failure.
preflight_generation_source_artifacts() {
  local rootfs="${1:?preflight_generation_source_artifacts: missing rootfs path}"
  local source_efi="${2:-}"

  if [[ -z "$source_efi" ]]; then
    warn "PF-24: source EFI mount is empty — source artifacts unavailable (non-fatal)"
    return 0
  fi

  if [[ ! -d "$source_efi" ]]; then
    warn "PF-24: source EFI mount directory does not exist: $source_efi (non-fatal)"
    return 0
  fi

  # Check for the typical SteamOS EFI layout.
  if [[ ! -d "$source_efi/EFI" ]]; then
    warn "PF-24: source EFI has no EFI/ directory: $source_efi (non-fatal)"
    return 0
  fi

  debug "PF-24: source EFI artifacts present: $source_efi"
}

# preflight_generation_source_allowlist ROOTFS SOURCE_EFI_MOUNT
#   PF-25: Verify the source EFI does not contain known non-portable paths
#   (grub.cfg, grubx64.efi, partsets/) that should be excluded from copy.
#   This check is advisory — only warns on failure.
preflight_generation_source_allowlist() {
  local rootfs="${1:?preflight_generation_source_allowlist: missing rootfs path}"
  local source_efi="${2:-}"

  if [[ -z "$source_efi" ]]; then
    warn "PF-25: source EFI mount is empty — skipping allowlist check (non-fatal)"
    return 0
  fi

  if [[ ! -d "$source_efi" ]]; then
    warn "PF-25: source EFI mount directory does not exist: $source_efi (non-fatal)"
    return 0
  fi

  # Check for known non-portable source paths that should be excluded from copy.
  local found_non_portable=0

  # grub.cfg — machine-specific boot configuration
  local candidate
  for candidate in \
    "$source_efi/EFI/steamos/grub.cfg" \
    "$source_efi/EFI/BOOT/grub.cfg"; do
    if [[ -f "$candidate" ]]; then
      warn "PF-25: non-portable path found in source EFI (should be excluded from copy): $candidate"
      found_non_portable=1
    fi
  done

  # grubx64.efi — machine-specific EFI binary
  for candidate in \
    "$source_efi/EFI/BOOT/grubx64.efi" \
    "$source_efi/EFI/steamos/grubx64.efi"; do
    if [[ -f "$candidate" ]]; then
      warn "PF-25: non-portable path found in source EFI (should be excluded from copy): $candidate"
      found_non_portable=1
    fi
  done

  # partsets/ directory — machine-specific partition layout
  for candidate in \
    "$source_efi/EFI/steamos/partsets" \
    "$source_efi/partsets"; do
    if [[ -d "$candidate" ]]; then
      warn "PF-25: non-portable path found in source EFI (should be excluded from copy): $candidate"
      found_non_portable=1
    fi
  done

  if [[ "$found_non_portable" -eq 0 ]]; then
    debug "PF-25: no known non-portable paths found in source EFI: $source_efi"
  fi
}

# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

# preflight_generation_validate ROOTFS [SOURCE_EFI_MOUNT] [EXPECTED_UUID]
#   Run all generation preflight checks in sequence.
#
#   Required checks (PF-16 through PF-23) die on failure.
#   Optional checks (PF-24, PF-25) warn and continue.
#
#   Args:
#     ROOTFS          - mounted target root filesystem
#     SOURCE_EFI_MOUNT - (optional) mounted source EFI partition
#     EXPECTED_UUID   - (optional) expected rootfs UUID after mutation
preflight_generation_validate() {
  local rootfs="${1:?preflight_generation_validate: missing rootfs path}"
  local source_efi="${2:-}"
  local expected_uuid="${3:-}"

  debug "preflight_generation_validate: validating $rootfs (source_efi=${source_efi:-<none>}, expected_uuid=${expected_uuid:-<none>})"

  # ── Required checks (die on failure) ───────────────────────────────
  preflight_generation_rootfs_uuid "$rootfs"
  preflight_generation_uuid_mutation_complete "$rootfs" "$expected_uuid"
  preflight_generation_grub_mkimage "$rootfs"
  preflight_generation_grub_platform_files "$rootfs"
  preflight_generation_update_grub "$rootfs"
  preflight_generation_boot_payload "$rootfs"
  preflight_generation_steamos_partsets "$rootfs"
  preflight_generation_steamos_bootconf "$rootfs"

  # ── Optional checks (warn and continue, never die) ─────────────────
  preflight_generation_source_artifacts "$rootfs" "$source_efi"
  preflight_generation_source_allowlist "$rootfs" "$source_efi"

  debug "preflight_generation_validate: all checks passed for $rootfs"
}
