#!/bin/bash
#
# steamos-nvidia-installer — lib/optimizations/video.sh
# Video/GPU related optimizations.
# Handles: unset-libva-driver, gpu-power-limit, resize-bar
#
# Sourced by entry.sh — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/optimizations/video.sh is a library — source it from entry.sh, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Module Entry Point
# ---------------------------------------------------------------------------
# Called by entry.sh to apply a video optimization.
#
# Usage: apply_video_optimization ITEM
#   ITEM - Optimization name (unset-libva-driver, gpu-power-limit, resize-bar)
#
# Returns 0 on success, 1 on failure.

apply_video_optimization() {
  local item="${1:?apply_video_optimization: missing item name}"

  case "$item" in
    unset-libva-driver)
      _apply_unset_libva_driver
      ;;
    gpu-power-limit)
      _apply_gpu_power_limit
      ;;
    resize-bar)
      _apply_resize_bar
      ;;
    *)
      warn "Unknown video optimization: $item"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# unset-libva-driver
# ---------------------------------------------------------------------------
# Remove the Valve-shipped profile.d snippet that forces LIBVA_DRIVER_NAME=radeonsi.
# This allows the browser to auto-detect the correct VA-API driver instead of
# being forced to Radeon.
#
# Context handling:
#   - chroot/rebuild: Remove from target rootfs
#   - live: Remove from running system (takes effect on next login)

_apply_unset_libva_driver() {
  local root
  root="$(get_root)"
  local target="${root}/etc/profile.d/libva.sh"

  if [[ -e "$target" ]]; then
    log "Removing /etc/profile.d/libva.sh (was forcing LIBVA_DRIVER_NAME=radeonsi)"
    if remove_file "/etc/profile.d/libva.sh"; then
      return 0
    else
      warn "Failed to remove /etc/profile.d/libva.sh"
      return 1
    fi
  else
    # File doesn't exist — idempotent success
    log "/etc/profile.d/libva.sh already absent"
    return 0
  fi
}

# ---------------------------------------------------------------------------
# gpu-power-limit
# ---------------------------------------------------------------------------
# Install boot-time hooks to set NVIDIA and AMD discrete GPU power limits
# to their vendor-defined maximums. Each hook is self-contained and
# idempotent — detects hardware at runtime.
#
# Hooks installed:
#   - 20-nvidia-gpu: nvidia-smi power limit + persistence mode
#   - 25-amd-gpu: sysfs power1_cap for discrete AMD GPUs
#
# Context handling:
#   - chroot/rebuild: Install hooks into target rootfs
#   - live: Install hooks and start service immediately

_apply_gpu_power_limit() {
  log "Applying gpu-power-limit optimization"
  install_boot_framework "20-nvidia-gpu" "25-amd-gpu"
}

# ---------------------------------------------------------------------------
# resize-bar
# ---------------------------------------------------------------------------
# Add nvidia.NVreg_EnableResizableBAR=1 to kernel command line.
# Enables Resizable BAR support for NVIDIA GPUs that support it.
#
# Context handling:
#   - chroot/rebuild: Add kernel parameter via grub.sh
#   - live: Add kernel parameter (requires grub update)
#
# Note: add_kernel_param() is provided by grub.sh, sourced by the caller.

_apply_resize_bar() {
  log "Applying resize-bar optimization (nvidia.NVreg_EnableResizableBar=1)"

  if declare -F add_kernel_param >/dev/null 2>&1; then
    add_kernel_param "nvidia.NVreg_EnableResizableBar=1"
    _persist_kernel_param_live "nvidia.NVreg_EnableResizableBar=1"
    return 0
  else
    warn "add_kernel_param not available — grub.sh may not be sourced"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Module Verify Entry Point
# ---------------------------------------------------------------------------

verify_video_optimization() {
  local item="${1:?verify_video_optimization: missing item name}"

  case "$item" in
    unset-libva-driver) _verify_unset_libva_driver ;;
    gpu-power-limit) _verify_gpu_power_limit ;;
    resize-bar) _verify_resize_bar ;;
    *)
      warn "Unknown video optimization: $item"
      return 1
      ;;
  esac
}

_verify_unset_libva_driver() {
  local root
  root="$(get_root)"
  [[ ! -e "${root}/etc/profile.d/libva.sh" ]]
}

_verify_gpu_power_limit() {
  local root
  root="$(get_root)"
  [[ -x "${root}/usr/lib/steam-perf/apply-boot" ]] \
    && [[ -x "${root}/usr/lib/steam-perf/boot.d/20-nvidia-gpu" ]] \
    && [[ -x "${root}/usr/lib/steam-perf/boot.d/25-amd-gpu" ]] \
    && [[ -f "${root}/usr/lib/systemd/system/steam-perf.service" ]]
}

_verify_resize_bar() {
  local root
  root="$(get_root)"
  if is_live; then
    grep -q 'nvidia.NVreg_EnableResizableBAR=1' /proc/cmdline 2>/dev/null
  else
    local grub_steamos="${root}/etc/default/grub-steamos"
    [[ -f "$grub_steamos" ]] && grep -q 'nvidia.NVreg_EnableResizableBAR=1' "$grub_steamos"
  fi
}
