#!/bin/bash
#
# steamos-build-installer — lib/optimizations/pci-hardware.sh
# PCI and hardware-related optimizations.
# Handles: pci-realloc
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
#   ITEM - Optimization name (pci-realloc)
#
# Returns 0 on success, 1 on failure.

apply_pci_hardware_optimization() {
  local item="${1:?apply_pci_hardware_optimization: missing item name}"

  case "$item" in
    pci-realloc)
      _apply_pci_realloc
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
    add_kernel_param "pci=realloc=on" || return 1
    if declare -F _persist_kernel_param_live >/dev/null 2>&1; then
      _persist_kernel_param_live "pci=realloc=on" || return 1
    fi
    return 0
  else
    warn "add_kernel_param not available — grub.sh may not be sourced"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Module Verify Entry Point
# ---------------------------------------------------------------------------

verify_pci_hardware_optimization() {
  local item="${1:?verify_pci_hardware_optimization: missing item name}"

  case "$item" in
    pci-realloc) _verify_pci_realloc ;;
    *)
      warn "Unknown pci-hardware optimization: $item"
      return 1
      ;;
  esac
}

_verify_pci_realloc() {
  local root
  root="$(get_root)" || return 1
  [[ -z "$root" ]] && {
    warn "_verify_pci_realloc: get_root returned empty"
    return 1
  }
  if is_live; then
    grep -q 'pci=realloc=on' /proc/cmdline 2>/dev/null
  else
    local grub_steamos="${root}/etc/default/grub-steamos"
    [[ -f "$grub_steamos" ]] && grep -q 'pci=realloc=on' "$grub_steamos"
  fi
}
