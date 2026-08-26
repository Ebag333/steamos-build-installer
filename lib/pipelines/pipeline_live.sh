#!/bin/bash
#
# steamos-nvidia-installer — lib/pipelines/pipeline_live.sh
# Live (post-install) workflow pipeline definition.
# Defines the phases for configuring a running SteamOS system.
#
# Sourced by post-install.sh — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/pipelines/pipeline_live.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Pipeline Definition
# ---------------------------------------------------------------------------

register_live_pipeline() {
  define_pipeline \
    "validate" \
    "prepare" \
    "configure" \
    "verify"

  register_phase "validate" "phase_live_validate" "Validate target system"
  register_phase "prepare" "phase_live_prepare" "Prepare system for changes"
  register_phase "configure" "phase_live_configure" "Apply configuration changes"
  register_phase "verify" "phase_live_verify" "Verify and cleanup"
}

# ---------------------------------------------------------------------------
# Phase Implementations
# ---------------------------------------------------------------------------

# Phase: Validate target system
phase_live_validate() {
  # Check if running as root
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    warn "Live configuration requires root privileges"
    return 1
  fi

  # Validate target root
  if [[ -n "${config_root:-}" && "$config_root" != "/" ]]; then
    # Offline target
    if [[ ! -d "$config_root" ]]; then
      warn "Target root not found: $config_root"
      return 1
    fi
    if [[ ! -f "$config_root/etc/os-release" ]]; then
      warn "Target doesn't look like a rootfs: $config_root"
      return 1
    fi
  fi

  return 0
}

# Phase: Prepare system for changes
phase_live_prepare() {
  # Make rootfs writable if needed
  if [[ "${config_root:-}" == "/" ]]; then
    # Live system
    if command -v steamos-readonly >/dev/null 2>&1; then
      log "Disabling SteamOS read-only mode"
      steamos-readonly disable || true
    fi
  else
    # Offline target
    if [[ -d "$config_root" ]]; then
      ensure_rootfs_writable "$config_root"
    fi
  fi

  return 0
}

# Phase: Apply configuration changes
phase_live_configure() {
  local root="${config_root:-/}"

  # Apply selected actions
  local action
  for action in ${SELECTED_ACTIONS:-}; do
    case "$action" in
      thunderbolt)
        _apply_live_thunderbolt "$root"
        ;;
      desktop)
        configure_desktop_session "$root" "desktop"
        ;;
      gamemode)
        _apply_live_gamemode "$root"
        ;;
      disable-autologin)
        _apply_live_disable_autologin "$root"
        ;;
      scx-lavd)
        _apply_live_scx_lavd "$root"
        ;;
      vm-tunables)
        _apply_live_vm_tunables "$root"
        ;;
      cpu-performance)
        _apply_live_cpu_performance "$root"
        ;;
      gpu-power-limit)
        _apply_live_gpu_power_limit "$root"
        ;;
      initramfs)
        _apply_live_initramfs "$root"
        ;;
      keyring)
        init_pacman_keyring "$root" "both"
        ;;
      password)
        _apply_live_password
        ;;
      lockscreen)
        _apply_live_lockscreen
        ;;
      cleanup)
        _apply_live_cleanup "$root"
        ;;
      *)
        warn "Unknown action: $action"
        ;;
    esac
  done

  # Run custom script
  run_custom_script "$root"

  # Persist project files to /home for later re-run
  ensure_project_persisted

  return 0
}

# Phase: Verify and cleanup
phase_live_verify() {
  local root="${config_root:-/}"

  # Regenerate initramfs if offline target
  if [[ "$root" != "/" ]]; then
    _regenerate_initramfs "$root"
  fi

  # Restore readonly mode
  if command -v steamos-readonly >/dev/null 2>&1; then
    log "Re-enabling SteamOS read-only mode"
    steamos-readonly enable || true
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Live Action Helpers
# ---------------------------------------------------------------------------

_apply_live_thunderbolt() {
  local root="$1"
  apply_optimization_for_item "thunderbolt" "live" "$root"
}

_apply_live_gamemode() {
  local root="$1"
  log "Configuring gamemode"

  # Add user to gamemode group
  if chroot "$root" getent group gamemode >/dev/null 2>&1; then
    chroot "$root" usermod -aG gamemode deck 2>/dev/null \
      || warn "Failed to add deck to gamemode group"
  fi

  # Enable gamemoded service
  mkdir -p "$root/etc/systemd/user/graphical-session.target.wants"
  ln -sf /usr/lib/systemd/user/gamemoded.service \
    "$root/etc/systemd/user/graphical-session.target.wants/gamemoded.service"

  return 0
}

_apply_live_disable_autologin() {
  local root="$1"
  local sddm_conf="$root/etc/sddm.conf.d/steamos.conf"

  if [[ -f "$sddm_conf" ]]; then
    if grep -q '^Relogin=true' "$sddm_conf"; then
      log "Disabling automatic login"
      sed -i 's/^Relogin=true/Relogin=false/' "$sddm_conf"
    fi
  fi

  return 0
}

_apply_live_scx_lavd() {
  local root="$1"
  log "Configuring scx_lavd scheduler"

  # Install config
  mkdir -p "$root/etc/scx_loader"
  cp "$SCRIPT_DIR/lib/configs/scx_loader_config.toml" "$root/etc/scx_loader/config.toml"

  # Enable service
  mkdir -p "$root/etc/systemd/system/multi-user.target.wants"
  ln -sf /usr/lib/systemd/system/scx.service \
    "$root/etc/systemd/system/multi-user.target.wants/scx.service"

  return 0
}

_apply_live_vm_tunables() {
  local root="$1"
  log "Configuring vm.swappiness"

  # Detect zram
  local has_zram=0
  if [[ -e "$root/usr/lib/systemd/zram-generator.conf" ]] \
    || [[ -e "$root/etc/systemd/zram-generator.conf" ]]; then
    has_zram=1
  fi

  # Apply appropriate swappiness
  if ((has_zram)); then
    cp "$SCRIPT_DIR/lib/configs/swappiness-zram.conf" "$root/etc/sysctl.d/99-vm-swappiness.conf"
  else
    cp "$SCRIPT_DIR/lib/configs/swappiness-disk.conf" "$root/etc/sysctl.d/99-vm-swappiness.conf"
  fi

  return 0
}

_apply_live_cpu_performance() {
  local root="$1"
  log "Installing CPU performance hooks"

  # Install boot framework
  local boot_src="$SCRIPT_DIR/lib/configs/boot"
  local boot_dst="$root/usr/lib/steam-perf"

  mkdir -p "$boot_dst/boot.d"
  cp "$boot_src/apply-boot" "$boot_dst/apply-boot"
  chmod 755 "$boot_dst/apply-boot"
  cp "$boot_src/30-cpu" "$boot_dst/boot.d/30-cpu"
  chmod 755 "$boot_dst/boot.d/30-cpu"

  mkdir -p "$root/etc/steam-perf"
  cp "$boot_src/config.conf" "$root/etc/steam-perf/config.conf"

  mkdir -p "$root/usr/lib/systemd/system" "$root/etc/systemd/system/multi-user.target.wants"
  cp "$boot_src/steam-perf.service" "$root/usr/lib/systemd/system/steam-perf.service"
  ln -sf /usr/lib/systemd/system/steam-perf.service \
    "$root/etc/systemd/system/multi-user.target.wants/steam-perf.service"

  return 0
}

_apply_live_gpu_power_limit() {
  local root="$1"
  log "Installing GPU power limit hooks"

  # Install boot framework
  local boot_src="$SCRIPT_DIR/lib/configs/boot"
  local boot_dst="$root/usr/lib/steam-perf"

  mkdir -p "$boot_dst/boot.d"
  cp "$boot_src/apply-boot" "$boot_dst/apply-boot"
  chmod 755 "$boot_dst/apply-boot"
  cp "$boot_src/20-nvidia-gpu" "$boot_dst/boot.d/20-nvidia-gpu"
  chmod 755 "$boot_dst/boot.d/20-nvidia-gpu"
  cp "$boot_src/25-amd-gpu" "$boot_dst/boot.d/25-amd-gpu"
  chmod 755 "$boot_dst/boot.d/25-amd-gpu"

  mkdir -p "$root/etc/steam-perf"
  cp "$boot_src/config.conf" "$root/etc/steam-perf/config.conf"

  mkdir -p "$root/usr/lib/systemd/system" "$root/etc/systemd/system/multi-user.target.wants"
  cp "$boot_src/steam-perf.service" "$root/usr/lib/systemd/system/steam-perf.service"
  ln -sf /usr/lib/systemd/system/steam-perf.service \
    "$root/etc/systemd/system/multi-user.target.wants/steam-perf.service"

  return 0
}

_apply_live_initramfs() {
  local root="$1"
  log "Configuring initramfs"

  # Use initramfs module
  if declare -F apply_initramfs >/dev/null 2>&1; then
    apply_initramfs "$root" "$(uname -r)"
  else
    warn "initramfs module not loaded"
    return 1
  fi

  return 0
}

_apply_live_password() {
  log "Setting user password"
  passwd deck
  return 0
}

_apply_live_lockscreen() {
  log "Enabling lock screen"
  # KDE lock screen settings
  local kscreenlockerrc="/home/deck/.config/kscreenlockerrc"
  if [[ -f "$kscreenlockerrc" ]]; then
    sed -i 's/^Autolock=.*/Autolock=true/' "$kscreenlockerrc"
    sed -i 's/^LockOnResume=.*/LockOnResume=true/' "$kscreenlockerrc"
  fi
  return 0
}

_apply_live_cleanup() {
  local root="$1"
  log "Cleaning up"

  # Clean pacman cache
  if [[ "$root" == "/" ]]; then
    pacman -Sc --noconfirm 2>/dev/null || true
  else
    chroot "$root" pacman -Sc --noconfirm 2>/dev/null || true
  fi

  # Clean temp files
  rm -rf /tmp/* 2>/dev/null || true

  # Clean journal
  journalctl --vacuum-time=7d 2>/dev/null || true

  return 0
}

_regenerate_initramfs() {
  local root="$1"
  log "Regenerating initramfs"

  if [[ -x "$root/usr/bin/dracut" ]]; then
    chroot "$root" dracut -f 2>/dev/null || warn "dracut failed"
  elif [[ -x "$root/usr/bin/mkinitcpio" ]]; then
    chroot "$root" mkinitcpio -P 2>/dev/null || warn "mkinitcpio failed"
  else
    warn "No initramfs tool found"
  fi

  return 0
}
