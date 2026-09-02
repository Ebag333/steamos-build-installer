#!/bin/bash
#
# steamos-build-installer — lib/optimizations/cpu-performance.sh
# CPU and scheduler performance optimizations.
# Handles: cpu-performance, scx-lavd, vm-tunables
#
# Sourced by entry.sh — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/optimizations/cpu-performance.sh is a library — source it from entry.sh, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Module Entry Point
# ---------------------------------------------------------------------------
# Called by entry.sh to apply a CPU performance optimization.
#
# Usage: apply_cpu_performance_optimization ITEM
#   ITEM - Optimization name (cpu-performance, scx-lavd, vm-tunables)
#
# Returns 0 on success, 1 on failure.

apply_cpu_performance_optimization() {
  local item="${1:?apply_cpu_performance_optimization: missing item name}"

  case "$item" in
    cpu-performance)
      _apply_cpu_performance
      ;;
    scx-lavd)
      _apply_scx_lavd
      ;;
    vm-tunables)
      _apply_vm_tunables
      ;;
    *)
      warn "Unknown cpu-performance optimization: $item"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# cpu-performance
# ---------------------------------------------------------------------------
# Install boot-time hook to set CPU governor and energy performance preference
# to "performance" mode on every boot.
#
# Hook installed:
#   - 30-cpu: Sets governor + EPP to performance, enables CPU boost
#
# Context handling:
#   - chroot/rebuild: Install hook into target rootfs
#   - live: Install hook and start service immediately

_apply_cpu_performance() {
  log "Applying cpu-performance optimization"
  install_boot_framework "30-cpu"
}

# ---------------------------------------------------------------------------
# scx-lavd
# ---------------------------------------------------------------------------
# Enable scx_lavd scheduler in autopilot mode for frametime consistency.
# Requires scx-scheds package providing /usr/bin/scx_lavd.
#
# Context handling:
#   - chroot/rebuild: Install config and enable service in target rootfs
#   - live: Install config and enable service immediately

_apply_scx_lavd() {
  local root
  root="$(get_root)"

  # Check if scx_lavd is available
  if [[ ! -x "${root}/usr/bin/scx_lavd" ]]; then
    warn "scx-lavd selected but /usr/bin/scx_lavd not found — skipping"
    return 1
  fi

  log "Configuring scx_lavd scheduler (autopilot) via scx_loader"

  # Determine source directory
  local config_src
  if [[ -n "${SCRIPT_DIR:-}" ]]; then
    config_src="$SCRIPT_DIR/lib/configs/scx_loader_config.toml"
  elif [[ -n "${CUSTOMIZATION_DIR:-}" ]]; then
    config_src="$(dirname "$CUSTOMIZATION_DIR")/configs/scx_loader_config.toml"
  else
    warn "Cannot determine scx_loader config source"
    return 1
  fi

  # Install config file
  if ! install_file "$config_src" "/etc/scx_loader/config.toml"; then
    return 1
  fi

  # Enable scx.service
  if ! enable_service "scx.service"; then
    warn "Failed to enable scx.service (non-fatal)"
  fi

  # Live mode: reload and restart immediately
  if is_live; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart scx.service 2>/dev/null \
      || warn "Failed to start scx.service (will activate on next boot)"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# vm-tunables
# ---------------------------------------------------------------------------
# Tune vm.swappiness for the target's swap configuration.
# Detection uses the target's zram generator config (not the build host's).
#
# Context handling:
#   - chroot/rebuild: Install config into target rootfs
#   - live: Install config and apply immediately

_apply_vm_tunables() {
  local root
  root="$(get_root)"

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

  # Detect if target has zram
  local has_zram=0
  if is_live; then
    # Live: check actual runtime state
    [[ -e /sys/block/zram0 ]] && has_zram=1
  else
    # Build/rebuild: check target's generator config
    if [[ -e "${root}/usr/lib/systemd/zram-generator.conf" ]] \
      || [[ -e "${root}/etc/systemd/zram-generator.conf" ]] \
      || [[ -e "${root}/usr/lib/systemd/zram-generator.conf.d" ]] \
      || [[ -e "${root}/etc/systemd/zram-generator.conf.d" ]]; then
      has_zram=1
    fi
  fi

  # Read target's current swappiness (fall back to kernel default 60)
  local target_swappiness
  target_swappiness="$(cat "${root}/proc/sys/vm/swappiness" 2>/dev/null || echo 60)"

  # Apply appropriate swappiness config
  if ((has_zram)) && ((target_swappiness < 100)); then
    log "Setting vm.swappiness=180 (zram present, was $target_swappiness)"
    if ! install_file "$configs_dir/swappiness-zram.conf" "/etc/sysctl.d/99-vm-swappiness.conf"; then
      return 1
    fi
  elif ((!has_zram)) && ((target_swappiness > 10)); then
    log "Setting vm.swappiness=10 (no zram, was $target_swappiness)"
    if ! install_file "$configs_dir/swappiness-disk.conf" "/etc/sysctl.d/99-vm-swappiness.conf"; then
      return 1
    fi
  else
    log "vm.swappiness already appropriate ($target_swappiness, zram=$has_zram) — skipping"
    return 0
  fi

  # Live mode: apply immediately
  if is_live; then
    local target_val
    ((has_zram)) && target_val=180 || target_val=10
    sysctl -q -w "vm.swappiness=$target_val" 2>/dev/null \
      || warn "Failed to apply swappiness live (will take effect on next boot)"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Module Verify Entry Point
# ---------------------------------------------------------------------------

verify_cpu_performance_optimization() {
  local item="${1:?verify_cpu_performance_optimization: missing item name}"

  case "$item" in
    cpu-performance) _verify_cpu_performance ;;
    scx-lavd) _verify_scx_lavd ;;
    vm-tunables) _verify_vm_tunables ;;
    *)
      warn "Unknown cpu-performance optimization: $item"
      return 1
      ;;
  esac
}

_verify_cpu_performance() {
  local root
  root="$(get_root)"
  [[ -x "${root}/usr/lib/steam-perf/boot.d/30-cpu" ]] \
    && [[ -f "${root}/usr/lib/systemd/system/steam-perf.service" ]]
}

_verify_scx_lavd() {
  local root
  root="$(get_root)"
  [[ -f "${root}/etc/scx_loader/config.toml" ]] || return 1
  if is_live; then
    systemctl is-enabled scx.service &>/dev/null
  else
    [[ -L "${root}/etc/systemd/system/multi-user.target.wants/scx.service" ]]
  fi
}

_verify_vm_tunables() {
  local root
  root="$(get_root)"
  [[ -f "${root}/etc/sysctl.d/99-vm-swappiness.conf" ]]
}
