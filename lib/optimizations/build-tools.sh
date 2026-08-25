#!/bin/bash
#
# steamos-nvidia-installer — lib/optimizations/build-tools.sh
# Build-time optimizations and configuration flags.
# Handles: trim-cuda, fix-keyring, skip-sigcheck, debug-boot
#
# Sourced by entry.sh — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/optimizations/build-tools.sh is a library — source it from entry.sh, not run directly." >&2
  exit 1
fi

# Set default values for build flags
# These are read by overlay.sh, common.sh, grub.sh, etc.
: "${TRIM_CUDA:=0}"
: "${FIX_KEYRING:=0}"
: "${SKIP_SIG:=0}"
: "${DEBUG_BOOT:=0}"

# ---------------------------------------------------------------------------
# Module Entry Point
# ---------------------------------------------------------------------------
# Called by entry.sh to apply a build-tools optimization.
#
# Usage: apply_build_tools_optimization ITEM
#   ITEM - Optimization name (trim-cuda, fix-keyring, skip-sigcheck, debug-boot)
#
# Returns 0 on success, 1 on failure.
#
# Note: These optimizations set flags that are read by other parts of the
# build system (overlay.sh, common.sh, grub.sh). They don't apply changes
# directly like other optimization modules.

apply_build_tools_optimization() {
  local item="${1:?apply_build_tools_optimization: missing item name}"

  case "$item" in
    trim-cuda)
      _apply_trim_cuda
      ;;
    fix-keyring)
      _apply_fix_keyring
      ;;
    skip-sigcheck)
      _apply_skip_sigcheck
      ;;
    debug-boot)
      _apply_debug_boot
      ;;
    *)
      warn "Unknown build-tools optimization: $item"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# trim-cuda
# ---------------------------------------------------------------------------
# Remove CUDA/OpenCL/NVVM/OptiX libraries (~350 MB savings).
# Not needed for gaming, but required for AI models.
#
# Context handling:
#   - Sets TRIM_CUDA=1 flag for compute_payload() in common.sh
#   - Only applies during build (not rebuild/live)

_apply_trim_cuda() {
  log "Enabling CUDA/OpenCL/NVVM/OptiX library trimming"
  export TRIM_CUDA=1
  return 0
}

# ---------------------------------------------------------------------------
# fix-keyring
# ---------------------------------------------------------------------------
# Force-initialize Arch + holo pacman keyrings.
# Useful when the frozen image keyring is too old or missing packager keys.
#
# Context handling:
#   - Sets FIX_KEYRING=1 flag for overlay.sh
#   - Only applies during build (not rebuild/live)

_apply_fix_keyring() {
  log "Enabling force keyring initialization"
  export FIX_KEYRING=1
  return 0
}

# ---------------------------------------------------------------------------
# skip-sigcheck
# ---------------------------------------------------------------------------
# Disable pacman signature verification in build chroot.
# Useful for testing or when keyring is problematic.
#
# Context handling:
#   - Sets SKIP_SIG=1 flag for overlay.sh and install-hw-libs.sh
#   - Only applies during build (not rebuild/live)

_apply_skip_sigcheck() {
  log "Disabling pacman signature verification"
  export SKIP_SIG=1
  return 0
}

# ---------------------------------------------------------------------------
# debug-boot
# ---------------------------------------------------------------------------
# Add rd.debug rd.log=all to kernel command line.
# Enables verbose initramfs logging for boot debugging.
#
# Context handling:
#   - Sets DEBUG_BOOT=1 flag for grub.sh
#   - Only applies during build (not rebuild/live)

_apply_debug_boot() {
  log "Enabling debug boot logging (rd.debug rd.log=all)"
  export DEBUG_BOOT=1
  return 0
}

# ---------------------------------------------------------------------------
# Module Verify Entry Point
# ---------------------------------------------------------------------------
# Build-tools verify checks the in-process flag state.
# Valid during build; for post-build verification, use filesystem checks.

verify_build_tools_optimization() {
  local item="${1:?verify_build_tools_optimization: missing item name}"

  case "$item" in
    trim-cuda) [[ "${TRIM_CUDA:-0}" == "1" ]] ;;
    fix-keyring) [[ "${FIX_KEYRING:-0}" == "1" ]] ;;
    skip-sigcheck) [[ "${SKIP_SIG:-0}" == "1" ]] ;;
    debug-boot) [[ "${DEBUG_BOOT:-0}" == "1" ]] ;;
    *)
      warn "Unknown build-tools optimization: $item"
      return 1
      ;;
  esac
}
