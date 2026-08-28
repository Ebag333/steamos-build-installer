#!/bin/bash
#
# steamos-build-installer — lib/optimizations/pci-hardware.sh
# PCI and hardware-related optimizations.
# Handles: pci-realloc, tb-host-reset, thunderbolt
#
# Sourced by entry.sh — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/optimizations/pci-hardware.sh is a library — source it from entry.sh, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Module Entry Point
# ---------------------------------------------------------------------------
# Called by entry.sh to apply a PCI/hardware optimization.
#
# Usage: apply_pci_hardware_optimization ITEM
#   ITEM - Optimization name (pci-realloc, tb-host-reset, thunderbolt)
#
# Returns 0 on success, 1 on failure.

apply_pci_hardware_optimization() {
  local item="${1:?apply_pci_hardware_optimization: missing item name}"

  case "$item" in
    pci-realloc)
      _apply_pci_realloc
      ;;
    tb-host-reset)
      _apply_tb_host_reset
      ;;
    thunderbolt)
      _apply_thunderbolt
      ;;
    *)
      warn "Unknown pci-hardware optimization: $item"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# pci-realloc
# ---------------------------------------------------------------------------
# Add pci=realloc=on to kernel command line.
# Fixes firmware PCI bridge resource allocation issues.
#
# Context handling:
#   - chroot/rebuild: Add kernel parameter via grub.sh
#   - live: Add kernel parameter (requires grub update)
#
# Note: add_kernel_param() is provided by grub.sh, sourced by the caller.

_apply_pci_realloc() {
  log "Applying pci-realloc optimization (pci=realloc=on)"

  if declare -F add_kernel_param >/dev/null 2>&1; then
    add_kernel_param "pci=realloc=on"
    _persist_kernel_param_live "pci=realloc=on"
    return 0
  else
    warn "add_kernel_param not available — grub.sh may not be sourced"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# tb-host-reset
# ---------------------------------------------------------------------------
# Add thunderbolt.host_reset=0 to kernel command line.
# Improves Thunderbolt/eGPU hotplug stability.
#
# Context handling:
#   - chroot/rebuild: Add kernel parameter via grub.sh
#   - live: Add kernel parameter (requires grub update)

_apply_tb_host_reset() {
  log "Applying tb-host-reset optimization (thunderbolt.host_reset=0)"

  if declare -F add_kernel_param >/dev/null 2>&1; then
    add_kernel_param "thunderbolt.host_reset=0"
    _persist_kernel_param_live "thunderbolt.host_reset=0"
    return 0
  else
    warn "add_kernel_param not available — grub.sh may not be sourced"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# thunderbolt
# ---------------------------------------------------------------------------
# Install Thunderbolt dock support:
#   - PCI rescan udev rule + script (fixes flaky hot-plug)
#   - bolt service (device management + Plasma integration)
#
# Context handling:
#   - chroot/rebuild: Install files into target rootfs
#   - live: Install files and start service immediately

_apply_thunderbolt() {
  local root
  root="$(get_root)"

  log "Applying thunderbolt optimization"

  # Determine source directory
  local configs_dir
  if [[ -n "${SCRIPT_DIR:-}" ]]; then
    configs_dir="$SCRIPT_DIR/lib/configs"
  elif [[ -n "${CUSTOMIZATION_DIR:-}" ]]; then
    configs_dir="$(dirname "$CUSTOMIZATION_DIR")/configs"
  else
    warn "Cannot determine configs source directory"
    return 1
  fi

  # Install files using helper
  install_file "$configs_dir/thunderbolt-rescan.sh" "/usr/local/bin/thunderbolt-rescan.sh" 755
  install_file "$configs_dir/98-thunderbolt-rescan.rules" "/etc/udev/rules.d/98-thunderbolt-rescan.rules"
  enable_service "bolt.service"

  # Bundle source files for self-heal (repatch.sh can restore them)
  local bundle="${root}/usr/lib/steamos-build/thunderbolt"
  mkdir -p "$bundle"
  cp "$configs_dir/thunderbolt-rescan.sh" "$bundle/"
  cp "$configs_dir/98-thunderbolt-rescan.rules" "$bundle/"

  # Trigger udev reload if live
  if is_live; then
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=thunderbolt 2>/dev/null || true
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Module Verify Entry Point
# ---------------------------------------------------------------------------

verify_pci_hardware_optimization() {
  local item="${1:?verify_pci_hardware_optimization: missing item name}"

  case "$item" in
    pci-realloc) _verify_pci_realloc ;;
    tb-host-reset) _verify_tb_host_reset ;;
    thunderbolt) _verify_thunderbolt ;;
    *)
      warn "Unknown pci-hardware optimization: $item"
      return 1
      ;;
  esac
}

_verify_pci_realloc() {
  local root
  root="$(get_root)"
  if is_live; then
    grep -q 'pci=realloc=on' /proc/cmdline 2>/dev/null
  else
    local grub_steamos="${root}/etc/default/grub-steamos"
    [[ -f "$grub_steamos" ]] && grep -q 'pci=realloc=on' "$grub_steamos"
  fi
}

_verify_tb_host_reset() {
  local root
  root="$(get_root)"
  if is_live; then
    grep -q 'thunderbolt.host_reset=0' /proc/cmdline 2>/dev/null
  else
    local grub_steamos="${root}/etc/default/grub-steamos"
    [[ -f "$grub_steamos" ]] && grep -q 'thunderbolt.host_reset=0' "$grub_steamos"
  fi
}

_verify_thunderbolt() {
  local root
  root="$(get_root)"
  [[ -f "${root}/usr/local/bin/thunderbolt-rescan.sh" ]] || return 1
  [[ -f "${root}/etc/udev/rules.d/98-thunderbolt-rescan.rules" ]] || return 1
  [[ -L "${root}/etc/systemd/system/multi-user.target.wants/bolt.service" ]]
}
