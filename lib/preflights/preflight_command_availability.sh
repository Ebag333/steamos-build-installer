#!/bin/bash
#
# steamos-build-installer — lib/preflight_command_availability.sh
# Command availability validation: ensures the required CLI tools, SteamOS
# GRUB modules, and boot payload (kernel/initramfs pair) are present in the
# target rootfs before any modification begins.
#
# Self-contained — does NOT source preflight_generation.sh or any other
# preflight library.  Only requires lib/common.sh for die/debug.
#
# Requires: lib/common.sh (die, debug)
# Do not run it directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/preflight_command_availability.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _pf_ca_command_available ROOTFS CMD
#   Check whether CMD exists and is executable in the rootfs.
#   First tries direct path resolution inside $rootfs; if that fails,
#   attempts a chroot probe.  Returns 0 if available, 1 otherwise.
#   Does NOT die — callers decide severity.
_pf_ca_command_available() {
  local rootfs="${1:?_pf_ca_command_available: missing rootfs path}"
  local cmd="${2:?_pf_ca_command_available: missing command name}"

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

# _pf_ca_grub_module_exists ROOTFS MODULE
#   Check whether a GRUB module (e.g. steamenv.mod) exists in the
#   standard GRUB module directories inside the rootfs.
#   Searches both /usr/lib/grub and /usr/share/grub for the module.
#   Returns 0 if found, 1 otherwise.
_pf_ca_grub_module_exists() {
  local rootfs="${1:?_pf_ca_grub_module_exists: missing rootfs path}"
  local module="${2:?_pf_ca_grub_module_exists: missing module name}"

  local -a search_dirs=(
    "$rootfs/usr/lib/grub"
    "$rootfs/usr/share/grub"
  )

  local dir
  for dir in "${search_dirs[@]}"; do
    [[ -d "$dir" ]] || continue

    # Search recursively for the module file.
    if find "$dir" -name "$module" -type f 2>/dev/null | head -1 | grep -q .; then
      return 0
    fi
  done

  return 1
}

# ---------------------------------------------------------------------------
# Preflight checks — independently callable
# ---------------------------------------------------------------------------

# preflight_command_availability_required_commands ROOTFS
#   PF-50: Verify that grub-mkimage, update-grub, steamos-partsets,
#   and steamos-bootconf all exist and are executable in the rootfs.
#   Aggregates all missing commands into a single die message.
preflight_command_availability_required_commands() {
  local rootfs="${1:?preflight_command_availability_required_commands: missing rootfs path}"

  local -a required_commands=(
    grub-mkimage
    update-grub
    steamos-partsets
    steamos-bootconf
  )

  local -a missing=()
  local cmd

  for cmd in "${required_commands[@]}"; do
    if ! _pf_ca_command_available "$rootfs" "$cmd"; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "PF-50: required commands missing or not executable in rootfs ($rootfs): ${missing[*]}"
  fi

  debug "PF-50: all required commands available in rootfs: $rootfs"
}

# preflight_command_availability_steamos_grub_support ROOTFS
#   PF-51: Verify that SteamOS GRUB modules exist in the rootfs.
#   Accepts either steamenv.mod or steamenv_boot.mod (distribution-dependent).
preflight_command_availability_steamos_grub_support() {
  local rootfs="${1:?preflight_command_availability_steamos_grub_support: missing rootfs path}"

  local found=0

  if _pf_ca_grub_module_exists "$rootfs" "steamenv.mod"; then
    debug "PF-51: found steamenv.mod in rootfs: $rootfs"
    found=1
  fi

  if _pf_ca_grub_module_exists "$rootfs" "steamenv_boot.mod"; then
    debug "PF-51: found steamenv_boot.mod in rootfs: $rootfs"
    found=1
  fi

  if [[ "$found" -eq 0 ]]; then
    die "PF-51: no SteamOS GRUB modules found (expected steamenv.mod or steamenv_boot.mod): $rootfs"
  fi

  debug "PF-51: SteamOS GRUB support present in rootfs: $rootfs"
}

# preflight_command_availability_boot_payload ROOTFS
#   PF-52: Verify at least one vmlinuz-* kernel image exists in the
#   rootfs /boot directory and has a matching initramfs-* companion.
#   Dies on failure.
preflight_command_availability_boot_payload() {
  local rootfs="${1:?preflight_command_availability_boot_payload: missing rootfs path}"

  local boot_dir="$rootfs/boot"

  if [[ ! -d "$boot_dir" ]]; then
    die "PF-52: /boot directory not found in rootfs: $boot_dir"
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
      die "PF-52: no matching initramfs for $vmlinuz (expected $initramfs)"
    fi

    debug "PF-52: boot payload found: vmlinuz-$ver + initramfs-$ver.img"
    # At least one valid pair is enough.
    return 0
  done

  if [[ "$found_kernel" -eq 0 ]]; then
    die "PF-52: no vmlinuz-* kernel found in $boot_dir"
  fi
}

# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

# preflight_command_availability_validate ROOTFS
#   Run all command-availability preflight checks in sequence.
#   Dies on the first failure.
#
#   Checks:
#     PF-50  Required commands (grub-mkimage, update-grub, steamos-partsets, steamos-bootconf)
#     PF-51  SteamOS GRUB modules (steamenv.mod or steamenv_boot.mod)
#     PF-52  Boot payload (vmlinuz + initramfs pair)
#
#   Args:
#     ROOTFS — mounted target root filesystem
preflight_command_availability_validate() {
  local rootfs="${1:?preflight_command_availability_validate: missing rootfs path}"

  debug "preflight_command_availability_validate: validating $rootfs"

  # PF-50: Required commands present in rootfs.
  preflight_command_availability_required_commands "$rootfs"

  # PF-51: SteamOS GRUB modules present in rootfs.
  preflight_command_availability_steamos_grub_support "$rootfs"

  # PF-52: Boot payload (kernel + initramfs) present in rootfs.
  preflight_command_availability_boot_payload "$rootfs"

  debug "preflight_command_availability_validate: all checks passed for $rootfs"
}
