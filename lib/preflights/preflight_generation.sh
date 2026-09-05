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

# _pf_gen_resolve_rootfs_device ROOTFS
#   Resolve the block device backing a Btrfs rootfs mount.
#   Verifies ROOTFS is an exact mountpoint, extracts the mount source,
#   strips any Btrfs subvolume suffix, and validates the device.
#   Prints the clean block device path on success; dies on failure.
_pf_gen_resolve_rootfs_device() {
  local rootfs="${1:?_pf_gen_resolve_rootfs_device: missing rootfs path}"

  if ! mountpoint -q "$rootfs" 2>/dev/null; then
    die "_pf_gen_resolve_rootfs_device: $rootfs is not a mountpoint"
  fi

  local source
  source="$(findmnt -nro SOURCE -M "$rootfs" 2>/dev/null)" || source=""
  if [[ -z "$source" ]]; then
    die "_pf_gen_resolve_rootfs_device: cannot determine mount source for $rootfs"
  fi

  # Strip Btrfs subvolume suffix: /dev/device[/subvolume] → /dev/device
  source="${source%%[*}"

  if [[ ! -b "$source" ]]; then
    die "_pf_gen_resolve_rootfs_device: $source is not a block device (resolved from $rootfs)"
  fi

  local fstype
  fstype="$(findmnt -nro FSTYPE -M "$rootfs" 2>/dev/null)" || fstype=""
  if [[ "$fstype" != "btrfs" ]]; then
    die "_pf_gen_resolve_rootfs_device: $rootfs has filesystem type '$fstype' — expected 'btrfs'"
  fi

  echo "$source"
}

# _pf_gen_get_uuid_from_device DEVICE
#   Determine the UUID of a block device via blkid.
#   Prints the UUID string on success; dies on failure.
_pf_gen_get_uuid_from_device() {
  local device="${1:?_pf_gen_get_uuid_from_device: missing device}"
  local uuid
  uuid="$(blkid -s UUID -o value "$device" 2>/dev/null)" || uuid=""
  if [[ -z "$uuid" ]]; then
    die "_pf_gen_get_uuid_from_device: cannot determine UUID for $device"
  fi
  echo "$uuid"
}

# TODO: This duplicates preflight_command_availability.sh. Keep one canonical
# implementation to avoid drift between validators.

# _pf_gen_command_available ROOTFS CMD
#   Check whether CMD exists and is executable in the rootfs.
#   First tries a direct path resolution inside $rootfs; if that fails,
#   attempts a chroot probe.  Returns 0 if available, 1 otherwise.
#   Does NOT die — callers decide severity.
_pf_gen_command_available() {
  local rootfs="${1:?_pf_gen_command_available: missing rootfs path}"
  local cmd="${2:?_pf_gen_command_available: missing command name}"

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
  # Use /bin/sh -c to properly invoke command (a shell builtin) via chroot,
  # which requires an explicit shell interpreter.
  if chroot "$rootfs" /bin/sh -c 'command -v "$1" >/dev/null 2>&1' sh "$cmd"; then
    return 0
  fi

  return 1
}

# _pf_gen_uuid_is_valid FORMAT
#   Return 0 if FORMAT looks like a valid UUID string (hex digits with
#   hyphens in standard 8-4-4-4-12 form), 1 otherwise.
_pf_gen_uuid_is_valid() {
  local uuid="${1:?_pf_gen_uuid_is_valid: missing uuid}"
  [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# ---------------------------------------------------------------------------
# Source artifact allowlist
# ---------------------------------------------------------------------------

# Static artifacts that may be copied from source EFI directory.
# These are deployment-independent and safe to preserve across updates.
_PF_GEN_ALLOWED_STATIC_ARTIFACTS=(
  "EFI/BOOT/BOOTX64.EFI"
  "EFI/SteamOS/"
)

# ---------------------------------------------------------------------------
# Preflight checks — independently callable
# ---------------------------------------------------------------------------

# preflight_generation_rootfs_uuid ROOTFS
#   PF-16: Verify the rootfs UUID is obtainable via findmnt + blkid.
#   Dies on failure.
preflight_generation_rootfs_uuid() {
  local rootfs="${1:?preflight_generation_rootfs_uuid: missing rootfs path}"

  # Resolve rootfs device (shared)
  local rootfs_device
  rootfs_device="$(_pf_gen_resolve_rootfs_device "$rootfs" 2>/dev/null)" || true
  if [[ -z "$rootfs_device" ]]; then
    die "PF-16: cannot resolve rootfs device for $rootfs"
  fi

  # Get UUID
  local current_uuid
  current_uuid="$(_pf_gen_get_uuid_from_device "$rootfs_device" 2>/dev/null)" || true
  if [[ -z "$current_uuid" ]]; then
    die "PF-16: cannot determine UUID for rootfs device $rootfs_device"
  fi

  debug "PF-16: rootfs UUID resolved: $current_uuid ($rootfs)"
}

# preflight_generation_uuid_mutation_complete ROOTFS [EXPECTED_UUID]
#   PF-17: Verify the resolved UUID is non-empty, has valid format,
#   is unique among all visible Btrfs filesystems, and (when
#   EXPECTED_UUID is provided) matches it — confirming that a UUID
#   mutation (e.g. during image cloning) has completed.
#   Dies on failure.
preflight_generation_uuid_mutation_complete() {
  local rootfs="${1:?preflight_generation_uuid_mutation_complete: missing rootfs path}"
  local expected_uuid="${2:-}"

  # Resolve rootfs device (shared helper)
  local rootfs_device
  rootfs_device="$(_pf_gen_resolve_rootfs_device "$rootfs" 2>/dev/null)" || true
  if [[ -z "$rootfs_device" ]]; then
    die "PF-17: cannot resolve rootfs device for $rootfs"
  fi

  # Get current UUID
  local current_uuid
  current_uuid="$(_pf_gen_get_uuid_from_device "$rootfs_device" 2>/dev/null)" || true
  if [[ -z "$current_uuid" ]]; then
    die "PF-17: cannot determine UUID for rootfs device $rootfs_device"
  fi

  # Validate UUID format
  if ! _pf_gen_uuid_is_valid "$current_uuid"; then
    die "PF-17: rootfs UUID '$current_uuid' is not a valid UUID"
  fi

  # If EXPECTED_UUID provided, verify it matches
  if [[ -n "$expected_uuid" ]]; then
    if [[ "${current_uuid,,}" != "${expected_uuid,,}" ]]; then
      die "PF-17: rootfs UUID mismatch — current: $current_uuid, expected: $expected_uuid"
    fi
    debug "PF-17: rootfs UUID matches expected: $current_uuid"
  fi

  # Verify UUID is unique among visible Btrfs filesystems
  # (detects clone artifacts or stale state)
  local duplicate_count=0
  local dev
  for dev in /dev/sd* /dev/nvme* /dev/mapper/*; do
    [[ -b "$dev" ]] || continue
    local dev_uuid
    dev_uuid="$(blkid -s UUID -o value "$dev" 2>/dev/null)" || continue
    [[ -z "$dev_uuid" ]] && continue
    # Skip non-Btrfs devices
    local dev_fstype
    dev_fstype="$(blkid -s TYPE -o value "$dev" 2>/dev/null)" || continue
    [[ "$dev_fstype" != "btrfs" ]] && continue
    # Skip the rootfs device itself
    [[ "$dev" == "$rootfs_device" ]] && continue
    if [[ "${dev_uuid,,}" == "${current_uuid,,}" ]]; then
      duplicate_count=$((duplicate_count + 1))
      debug "PF-17: duplicate UUID found on $dev"
    fi
  done

  if [[ "$duplicate_count" -gt 0 ]]; then
    die "PF-17: rootfs UUID $current_uuid is not unique — found on $duplicate_count other Btrfs device(s)"
  fi

  debug "PF-17: rootfs UUID is $current_uuid (unique, valid)"
}

# preflight_generation_grub_mkimage ROOTFS
#   PF-18: Verify grub-mkimage exists and is executable in the rootfs.
#   Dies on failure.
preflight_generation_grub_mkimage() {
  local rootfs="${1:?preflight_generation_grub_mkimage: missing rootfs path}"

  if ! _pf_gen_command_available "$rootfs" "grub-mkimage"; then
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

  # Check for exact required GRUB modules that grub-mkimage needs for a
  # functional SteamOS boot.  Use exact filenames instead of broad globs
  # (e.g. linux*, normal*) to avoid matching irrelevant files.
  local -a required_modules=(
    linux
    normal
    part_gpt
    search
    configfile
    steamenv
  )

  local mod
  for mod in "${required_modules[@]}"; do
    if [[ ! -f "${grub_dir}/${mod}.mod" ]]; then
      die "PF-19: required GRUB module ${mod}.mod not found in $grub_dir"
    fi
  done

  debug "PF-19: GRUB platform files present: $grub_dir"
}

# preflight_generation_update_grub ROOTFS
#   PF-20: Verify update-grub exists and is executable in the rootfs.
#   Dies on failure.
preflight_generation_update_grub() {
  local rootfs="${1:?preflight_generation_update_grub: missing rootfs path}"

  if ! _pf_gen_command_available "$rootfs" "update-grub"; then
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

  # --- Try to find the default/selected kernel first --------------------
  local default_kernel=""
  if [[ -L "${rootfs}/boot/vmlinuz" ]]; then
    local link_target
    link_target="$(readlink -f "${rootfs}/boot/vmlinuz" 2>/dev/null)" || true
    if [[ -n "$link_target" && "$link_target" == "${rootfs}"/* && -f "$link_target" ]]; then
      default_kernel="$link_target"
      debug "PF-21: default kernel symlink resolved: $default_kernel"
    else
      debug "PF-21: /boot/vmlinuz symlink is broken or escapes rootfs — will scan all kernels"
    fi
  fi

  # --- Build candidate list: default kernel first, then all vmlinuz-* ---
  local -a kernels_to_check=()

  if [[ -n "$default_kernel" ]]; then
    kernels_to_check=("$default_kernel")
  else
    for k in "${rootfs}"/boot/vmlinuz-*; do
      [[ -f "$k" ]] && kernels_to_check+=("$k")
    done
  fi

  if [[ ${#kernels_to_check[@]} -eq 0 ]]; then
    die "PF-21: no vmlinuz-* kernel found in $boot_dir"
  fi

  # --- Validate until we find one valid pair ----------------------------
  local valid_pair_found=false
  local kernel
  for kernel in "${kernels_to_check[@]}"; do
    # Check kernel is a regular file (not a broken symlink).
    if [[ ! -f "$kernel" ]]; then
      debug "PF-21: skipping $kernel (not a regular file)"
      continue
    fi

    # If the kernel is a symlink, ensure it resolves inside the rootfs.
    if [[ -L "$kernel" ]]; then
      local resolved
      resolved="$(readlink -f "$kernel" 2>/dev/null)" || true
      if [[ -z "$resolved" || "$resolved" != "${rootfs}"/* ]]; then
        debug "PF-21: skipping $kernel (symlink resolves outside rootfs)"
        continue
      fi
    fi

    # Extract the version suffix (everything after vmlinuz-).
    local version="${kernel##*/vmlinuz-}"
    local initramfs="${rootfs}/boot/initramfs-${version}.img"

    # Check initramfs exists.
    if [[ ! -f "$initramfs" ]]; then
      debug "PF-21: kernel $kernel has no matching initramfs $initramfs"
      continue
    fi

    # Check both are non-empty.
    if [[ ! -s "$kernel" || ! -s "$initramfs" ]]; then
      debug "PF-21: kernel or initramfs is empty"
      continue
    fi

    valid_pair_found=true
    debug "PF-21: found valid kernel/initramfs pair: $kernel + $initramfs"
    break
  done

  if [[ "$valid_pair_found" != "true" ]]; then
    die "PF-21: no valid kernel/initramfs pair found in ${rootfs}/boot/"
  fi
}

# preflight_generation_steamos_partsets ROOTFS
#   PF-22: Verify steamos-partsets exists and is executable in the rootfs.
#   Dies on failure.
preflight_generation_steamos_partsets() {
  local rootfs="${1:?preflight_generation_steamos_partsets: missing rootfs path}"

  if ! _pf_gen_command_available "$rootfs" "steamos-partsets"; then
    die "PF-22: steamos-partsets not found or not executable in rootfs: $rootfs"
  fi

  debug "PF-22: steamos-partsets is available in rootfs: $rootfs"
}

# preflight_generation_steamos_bootconf ROOTFS
#   PF-23: Verify steamos-bootconf exists and is executable in the rootfs.
#   Dies on failure.
preflight_generation_steamos_bootconf() {
  local rootfs="${1:?preflight_generation_steamos_bootconf: missing rootfs path}"

  if ! _pf_gen_command_available "$rootfs" "steamos-bootconf"; then
    die "PF-23: steamos-bootconf not found or not executable in rootfs: $rootfs"
  fi

  debug "PF-23: steamos-bootconf is available in rootfs: $rootfs"
}

# preflight_generation_source_artifacts SOURCE_EFI_MOUNT
#   PF-24: Check that a source EFI binary is available at the given mount.
#   This check is advisory — source artifacts are NOT portable and their
#   absence must NOT prevent generation.  Only warns on failure.
#
#   Note: ROOTFS was previously accepted as the first parameter but never
#   used.  It has been removed from the signature for clarity.
preflight_generation_source_artifacts() {
  local source_efi="${1:-}"

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

  # Verify the EFI directory is not empty — an empty EFI directory is useless.
  if ! ls -A "$source_efi/EFI" >/dev/null 2>&1 || [[ -z "$(ls -A "$source_efi/EFI" 2>/dev/null)" ]]; then
    warn "PF-24: source EFI directory exists but is empty: $source_efi/EFI (non-fatal)"
    return 0
  fi

  # Required artifacts
  local required_artifacts=(
    "EFI/BOOT/BOOTX64.EFI"
    "EFI/SteamOS/grub.cfg"
    "EFI/SteamOS/grubx64.efi"
  )

  for artifact in "${required_artifacts[@]}"; do
    if [[ ! -e "${source_efi}/${artifact}" ]]; then
      warn "PF-24: required source artifact missing: ${artifact} (non-fatal)"
      return 0
    fi
  done

  # List files that should not be blindly copied (deployment-specific)
  local nonportable_patterns=(
    "*/grub.cfg"        # Generated per-deployment
    "*/grubx64.efi"     # Contains rootfs UUID
    "*/partsets/*"      # Device-specific
  )

  # Check for files matching non-portable patterns
  for pattern in "${nonportable_patterns[@]}"; do
    local matches
    matches="$(find "$source_efi" -path "$source_efi/$pattern" -type f 2>/dev/null)" || true
    if [[ -n "$matches" ]]; then
      debug "PF-24: source contains non-portable artifacts (will not be copied):"
      while IFS= read -r match; do
        debug "  $match"
      done <<< "$matches"
    fi
  done

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
      debug "PF-25: non-portable path found in source EFI (will not be copied): $candidate"
      found_non_portable=1
    fi
  done

  # grubx64.efi — machine-specific EFI binary
  for candidate in \
    "$source_efi/EFI/BOOT/grubx64.efi" \
    "$source_efi/EFI/steamos/grubx64.efi"; do
    if [[ -f "$candidate" ]]; then
      debug "PF-25: non-portable path found in source EFI (will not be copied): $candidate"
      found_non_portable=1
    fi
  done

  # partsets/ directory — machine-specific partition layout
  for candidate in \
    "$source_efi/SteamOS/partsets"; do
    if [[ -d "$candidate" ]]; then
      debug "PF-25: non-portable path found in source EFI (will not be copied): $candidate"
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

# preflight_generation_tool_available ROOTFS TOOL [REASON]
#   PF-18: Verify TOOL exists and is executable in the rootfs chroot.
#   REASON is an optional human-readable description of why the tool is
#   needed, included in the error message for easier debugging.
#   Dies on failure.
preflight_generation_tool_available() {
  local rootfs="${1:?preflight_generation_tool_available: missing rootfs path}"
  local tool="${2:?preflight_generation_tool_available: missing tool name}"
  local reason="${3:-}"

  local reason_msg=""
  if [[ -n "$reason" ]]; then
    reason_msg=" ($reason)"
  fi

  if ! _pf_gen_command_available "$rootfs" "$tool"; then
    die "PF-18: required tool '$tool' is not available in chroot $rootfs${reason_msg}"
  fi

  debug "PF-18: tool '$tool' is available in chroot $rootfs"
}

# preflight_generation_validate ROOTFS SOURCE_EFI_DIR EXPECTED_UUID
#                              GENERATE_BINARY GENERATE_CONFIG GENERATE_PARTSETS GENERATE_BOOTCONF
#   Master preflight for generation prerequisites.
#
#   Generation plan flags (true/false):
#     GENERATE_BINARY    - true if grub-mkimage must succeed (new UUID, new binary needed)
#     GENERATE_CONFIG    - true if update-grub must succeed (new UUID or kernel, config regeneration needed)
#     GENERATE_PARTSETS  - true if steamos-partsets must run
#     GENERATE_BOOTCONF  - true if steamos-bootconf must run
#
#   Tool availability checks are only performed for tools that will actually be used.
#
#   Args:
#     ROOTFS              - mounted target root filesystem
#     SOURCE_EFI_DIR      - (optional) mounted source EFI partition
#     EXPECTED_UUID       - (optional) expected rootfs UUID after mutation
#     GENERATE_BINARY     - (optional, default false) whether binary generation is needed
#     GENERATE_CONFIG     - (optional, default false) whether config generation is needed
#     GENERATE_PARTSETS   - (optional, default false) whether partsets generation is needed
#     GENERATE_BOOTCONF   - (optional, default false) whether bootconf generation is needed
preflight_generation_validate() {
  local rootfs="${1:?preflight_generation_validate: missing rootfs path}"
  local source_efi_dir="${2:-}"
  local expected_uuid="${3:-}"
  local generate_binary="${4:-false}"
  local generate_config="${5:-false}"
  local generate_partsets="${6:-false}"
  local generate_bootconf="${7:-false}"

  debug "preflight_generation_validate: root=$rootfs source=${source_efi_dir:-<none>} uuid=${expected_uuid:-<none>} binary=$generate_binary config=$generate_config partsets=$generate_partsets bootconf=$generate_bootconf"

  # PF-16: Rootfs UUID is valid (always required for Btrfs rootfs validation)
  preflight_generation_rootfs_uuid "$rootfs"

  # PF-17: UUID mutation completed (when expected UUID is provided)
  if [[ -n "$expected_uuid" ]]; then
    preflight_generation_uuid_mutation_complete "$rootfs" "$expected_uuid"
  fi

  # PF-18: Required tools available — only check tools that will be used
  if [[ "$generate_binary" == "true" ]]; then
    preflight_generation_tool_available "$rootfs" "grub-mkimage" "required for binary generation"
  fi
  if [[ "$generate_config" == "true" ]]; then
    preflight_generation_tool_available "$rootfs" "update-grub" "required for config generation"
  fi
  if [[ "$generate_partsets" == "true" ]]; then
    preflight_generation_tool_available "$rootfs" "steamos-partsets" "required for partset generation"
  fi
  if [[ "$generate_bootconf" == "true" ]]; then
    preflight_generation_tool_available "$rootfs" "steamos-bootconf" "required for bootconf generation"
  fi

  # PF-19: GRUB modules present (when binary generation is needed)
  if [[ "$generate_binary" == "true" ]]; then
    preflight_generation_grub_platform_files "$rootfs"
  fi

  # PF-20/21: Boot payload valid (when config generation is needed)
  if [[ "$generate_config" == "true" ]]; then
    preflight_generation_boot_payload "$rootfs"
  fi

  # PF-22: GRUB directory structure (when binary generation is needed)
  if [[ "$generate_binary" == "true" ]]; then
    preflight_generation_steamos_partsets "$rootfs"
  fi

  # PF-23: GRUB environment (when config generation is needed)
  if [[ "$generate_config" == "true" ]]; then
    preflight_generation_steamos_bootconf "$rootfs"
  fi

  # PF-24/25: Source EFI artifacts (only when source is provided)
  if [[ -n "$source_efi_dir" ]]; then
    preflight_generation_source_artifacts "$source_efi_dir"
    preflight_generation_source_allowlist "$rootfs" "$source_efi_dir"
  fi

  debug "preflight_generation_validate: all generation prerequisites satisfied"
}
