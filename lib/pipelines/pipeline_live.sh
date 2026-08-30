#!/bin/bash
#
# steamos-build-installer — lib/pipelines/pipeline_live.sh
# Live workflow pipeline definition.
# Defines the phases for configuring a running SteamOS system.
#
# Sourced by the pipeline dispatcher — do not run directly.

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
  if [[ -z "${config_root:-}" || "${config_root:-}" == "/" ]]; then
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
      resize)
        resize_rootfs
        ;;
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
        sddm_disable_autologin "$root"
        ;;
      scx-lavd)
        apply_optimization_for_item "scx-lavd" "live" "$root"
        ;;
      vm-tunables)
        apply_optimization_for_item "vm-tunables" "live" "$root"
        ;;
      cpu-performance)
        apply_optimization_for_item "cpu-performance" "live" "$root"
        ;;
      gpu-power-limit)
        apply_optimization_for_item "gpu-power-limit" "live" "$root"
        ;;
      initramfs)
        _apply_live_initramfs "$root"
        ;;
      logitech-hid)
        _apply_live_logitech_hid "$root"
        ;;
      keyring)
        init_pacman_keyring "$root" "both"
        ;;
      password)
        set_user_password
        ;;
      cleanup)
        cleanup_disk_space "$root"
        ;;
      *)
        warn "Unknown action: $action"
        ;;
    esac
  done

  # Run custom script
  run_custom_script "$root"

  # Install flatpak packages and ensure staging service
  step "Installing flatpak packages"
  install_flatpak_packages "$root"
  ensure_flatpak_service "$root"

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

  # Restore readonly mode (only if we disabled it for the live system)
  if [[ -z "${config_root:-}" || "${config_root:-}" == "/" ]]; then
    if command -v steamos-readonly >/dev/null 2>&1; then
      log "Re-enabling SteamOS read-only mode"
      steamos-readonly enable || true
    fi
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

_apply_live_logitech_hid() {
  local root="$1"
  log "Building Logitech HID modules"

  local recipe_dir="$SCRIPT_DIR/lib/configs/build_recipes/logitech-hid"
  if [[ ! -d "$recipe_dir" ]]; then
    warn "logitech-hid recipe not found"
    return 1
  fi

  local _install_cmd=""
  _install_cmd="$(sed -n 's/^INSTALL_CMD=//p' "$recipe_dir/recipe.conf" 2>/dev/null | tr -d '"' | head -1)"
  if [[ -z "$_install_cmd" ]]; then
    warn "No INSTALL_CMD in logitech-hid recipe"
    return 1
  fi

  local _install_args=""
  _install_args="$(sed -n 's/^INSTALL_ARGS=//p' "$recipe_dir/recipe.conf" 2>/dev/null | tr -d '"' | head -1)"

  local _script_name
  _script_name="$(basename "$_install_cmd")"

  # Copy recipe sources to build dir
  local build_dir="/tmp/logitech-hid-build"
  rm -rf "$build_dir"
  mkdir -p "$build_dir"
  if [[ -d "$recipe_dir/sources" ]]; then
    cp -a "$recipe_dir/sources/." "$build_dir/"
  fi

  if [[ ! -f "$build_dir/$_script_name" ]]; then
    warn "Install script not found: $_script_name"
    rm -rf "$build_dir"
    return 1
  fi

  chmod +x "$build_dir/$_script_name"

  # Run the build script
  if bash "$build_dir/$_script_name" "$_install_args"; then
    log "Logitech HID modules built and installed"
    rm -rf "$build_dir"
    return 0
  else
    warn "FAILED: Logitech HID build failed"
    rm -rf "$build_dir"
    return 1
  fi
}

