#!/bin/bash
#
# steamos-build-installer — lib/workflow-common.sh
# Shared functions used by multiple workflows.
# Extracted to avoid duplication between build, repatch, and live workflows.
#
# Sourced by pipeline.sh and workflow entry points — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/workflow-common.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Desktop Session Configuration
# ---------------------------------------------------------------------------
# Configures the default desktop session and login mode.
# Used by: build, repatch, live workflows.

# Configure desktop session defaults.
# Args: $1 = root path, $2 = session mode (desktop|game)
# Returns 0 on success, 1 on failure
configure_desktop_session() {
  local root="${1:?configure_desktop_session: missing root}"
  local session="${2:-desktop}"

  apply_system_config "default-session" "$root" "$session" || return 1
}

# ---------------------------------------------------------------------------
# Custom Script Execution
# ---------------------------------------------------------------------------
# Runs user-provided custom script if present.
# Used by: build, repatch, live workflows.

# Run custom script if present.
# Uses CUSTOM_FINALIZE_SCRIPT from config if set, otherwise falls back to
# the hardcoded path at /home/.steamos-build/recovery/custom.sh.
# Args: $1 = root path (optional, defaults to /)
# Returns 0 on success or script not found, 1 on script failure
run_custom_script() {
  local root="${1:-/}"
  local custom=""

  # User-selected script from config takes priority
  if [[ -n "${CUSTOM_FINALIZE_SCRIPT:-}" ]]; then
    custom="$CUSTOM_FINALIZE_SCRIPT"
  else
    custom="$root/home/.steamos-build/recovery/custom.sh"
  fi

  if [[ -f "$custom" ]]; then
    log "Running custom script: $custom"
    if bash "$custom" "$root" 2>&1; then
      log "Custom script completed successfully"
      return 0
    else
      local _rc=$?
      warn "Custom script exited with non-zero status $_rc (non-fatal)"
      return 0 # Non-fatal
    fi
  else
    log "No custom script at $custom — skipping"
    return 0
  fi
}

# Ensure the flatpak staging service is installed and enabled.
# Idempotent — skips if all three components are already in place.
# Args: $1 = root path (e.g. $NEWROOT for repatch, / for live)
ensure_flatpak_service() {
  local root="${1:-/}"
  local script_dir="${SCRIPT_DIR:-/home/.steamos-build}"

  local service_file="$root/etc/systemd/user/steamos-build-flatpak-install.service"
  local install_script="$root/usr/lib/steamos-build/install-staged-flatpaks"
  local wants_link="$root/etc/systemd/user/default.target.wants/steamos-build-flatpak-install.service"

  # Check if already set up
  if [[ -f "$service_file" && -f "$install_script" && -L "$wants_link" ]]; then
    log "  Flatpak staging service already installed — skipping"
    return 0
  fi

  log "  Installing flatpak staging service"

  # Service file
  if [[ ! -f "$service_file" ]]; then
    local src_service="$script_dir/lib/configs/steamos-build-flatpak-install.service"
    if [[ ! -f "$src_service" ]]; then
      warn "ensure_flatpak_service: source service file not found at $src_service"
      return 1
    fi
    mkdir -p "$(dirname "$service_file")" \
      || {
        warn "ensure_flatpak_service: failed to create directory for service file"
        return 1
      }
    cp "$src_service" "$service_file" \
      || {
        warn "ensure_flatpak_service: failed to copy service file"
        return 1
      }
    log "    Installed service file"
  fi

  # Install script
  if [[ ! -f "$install_script" ]]; then
    local src_script="$script_dir/lib/configs/install-staged-flatpaks.sh"
    if [[ ! -f "$src_script" ]]; then
      warn "ensure_flatpak_service: source staging script not found at $src_script"
      return 1
    fi
    mkdir -p "$(dirname "$install_script")" \
      || {
        warn "ensure_flatpak_service: failed to create directory for install script"
        return 1
      }
    install -m 755 "$src_script" "$install_script" \
      || {
        warn "ensure_flatpak_service: failed to install staging script"
        return 1
      }
    log "    Installed staging script"
  fi

  # Enable service
  if [[ ! -L "$wants_link" ]]; then
    mkdir -p "$(dirname "$wants_link")" \
      || {
        warn "ensure_flatpak_service: failed to create wants directory"
        return 1
      }
    ln -sf /etc/systemd/user/steamos-build-flatpak-install.service "$wants_link" \
      || {
        warn "ensure_flatpak_service: failed to create wants symlink"
        return 1
      }
    log "    Enabled service"
  fi

  log "  Flatpak staging service installed"
  return 0
}

# Install flatpak packages from hw-packages.conf.
# Resolves recipes and runs install scripts for each flatpak item.
# Args: $1 = target root path, $2 = callback function name (optional)
#   If a callback is provided, it is called as: callback PKG "ok"|"fail"
# Returns 0 if all packages succeeded, 1 if any failed
install_flatpak_packages() {
  local root="${1:?install_flatpak_packages: missing root}"
  local callback="${2:-}"
  local rc=0

  local flatpaks
  flatpaks="$(get_build_items "flatpak")"
  [[ -n "$flatpaks" ]] || return 0

  for pkg in $flatpaks; do
    local recipe_name
    recipe_name="$(get_build_recipe "$pkg")" || recipe_name=""
    local recipe_dir=""
    if [[ -n "$recipe_name" ]]; then
      recipe_dir="$SCRIPT_DIR/lib/configs/build_recipes/$recipe_name"
    fi

    if [[ -d "$recipe_dir" ]]; then
      local install_script="$recipe_dir/sources/install-${recipe_name}.sh"
      if [[ -x "$install_script" ]]; then
        log "Installing $pkg via recipe"
        if bash "$install_script" "$root"; then
          log "$pkg: installed successfully"
          [[ -z "$callback" ]] || "$callback" "$pkg" "ok"
        else
          warn "FAILED: $pkg install failed"
          [[ -z "$callback" ]] || "$callback" "$pkg" "fail"
          rc=1
        fi
      else
        warn "No install script found for $pkg at $install_script"
        [[ -z "$callback" ]] || "$callback" "$pkg" "fail"
        rc=1
      fi
    else
      warn "No recipe found for $pkg"
      [[ -z "$callback" ]] || "$callback" "$pkg" "fail"
      rc=1
    fi
  done

  return "$rc"
}

# ---------------------------------------------------------------------------
# Rootfs Expansion
# ---------------------------------------------------------------------------
# Expands filesystem to fill partition.
# Used by: repatch, live, flashless workflows.

# Expand btrfs filesystem to fill partition.
# Args: $1 = root path, $2 = mount point (optional)
# Returns 0 on success, 1 on failure
expand_rootfs_to_fill() {
  local root="${1:?expand_rootfs_to_fill: missing root}"
  local mount_point="${2:-$root}"

  # Check if btrfs
  if ! btrfs filesystem show "$mount_point" >/dev/null 2>&1; then
    log "  Not a btrfs filesystem — skipping expansion"
    return 0
  fi

  log "  Expanding btrfs filesystem to fill partition"
  if btrfs filesystem resize max "$mount_point" 2>/dev/null; then
    log "  Filesystem expanded successfully"
    return 0
  else
    warn "Failed to expand filesystem"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Btrfs Read-Only Property
# ---------------------------------------------------------------------------
# Handles btrfs read-only property on rootfs.
# Used by: repatch, flashless workflows.

# Ensure btrfs rootfs is writable.
# Args: $1 = root path
# Returns 0 on success, 1 on failure
ensure_rootfs_writable() {
  local root="${1:?ensure_rootfs_writable: missing root}"

  # Check if btrfs
  if ! btrfs filesystem show "$root" >/dev/null 2>&1; then
    return 0
  fi

  # Check if read-only
  local ro_prop
  ro_prop="$(btrfs property get "$root" ro 2>/dev/null || echo "ro=false")"

  if [[ "$ro_prop" == "ro=true" ]]; then
    log "  Rootfs is read-only — setting to writable"
    if btrfs property set "$root" ro false; then
      log "  Rootfs set to writable"
      return 0
    else
      warn "Failed to set rootfs writable"
      return 1
    fi
  fi

  return 0
}

# Restore btrfs rootfs to read-only.
# Args: $1 = root path
# Returns 0 on success, 1 on failure
restore_rootfs_readonly() {
  local root="${1:?restore_rootfs_readonly: missing root}"

  # Check if btrfs
  if ! btrfs filesystem show "$root" >/dev/null 2>&1; then
    return 0
  fi

  # Check if writable
  local ro_prop
  ro_prop="$(btrfs property get "$root" ro 2>/dev/null || echo "ro=false")"

  if [[ "$ro_prop" == "ro=false" ]]; then
    log "  Restoring rootfs to read-only"
    if btrfs property set "$root" ro true; then
      log "  Rootfs restored to read-only"
      return 0
    else
      warn "Failed to restore rootfs to read-only"
      return 1
    fi
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Pacman Keyring Initialization
# ---------------------------------------------------------------------------
# Initializes pacman keyring in target root.
# Used by: build, repatch, live workflows.

# Initialize pacman keyring.
# Args: $1 = root path, $2 = keyring type (archlinux|holo|both)
# Returns 0 on success, 1 on failure
init_pacman_keyring() {
  local root="${1:?init_pacman_keyring: missing root}"
  local keyring="${2:-both}"

  log "Initializing pacman keyring ($keyring)"

  # Check if pacman is available
  # shellcheck disable=SC2016 # $1 expands inside the chroot shell, not locally
  if ! chroot "$root" /bin/sh -c 'command -v "$1" >/dev/null 2>&1' sh pacman; then
    warn "pacman not available in target"
    return 1
  fi

  # Remove existing keyring for a clean reset
  rm -rf "$root/etc/pacman.d/gnupg" 2>/dev/null || true

  # Initialize keyring
  case "$keyring" in
    archlinux)
      chroot "$root" pacman-key --init 2>/dev/null \
        || {
          warn "pacman-key --init failed"
          return 1
        }
      chroot "$root" pacman-key --populate archlinux 2>/dev/null \
        || {
          warn "pacman-key --populate archlinux failed"
          return 1
        }
      ;;
    holo)
      chroot "$root" pacman-key --init 2>/dev/null \
        || {
          warn "pacman-key --init failed"
          return 1
        }
      chroot "$root" pacman-key --populate holo 2>/dev/null \
        || {
          warn "pacman-key --populate holo failed"
          return 1
        }
      ;;
    both)
      chroot "$root" pacman-key --init 2>/dev/null \
        || {
          warn "pacman-key --init failed"
          return 1
        }
      chroot "$root" pacman-key --populate archlinux holo 2>/dev/null \
        || {
          warn "pacman-key --populate failed"
          return 1
        }
      ;;
    *)
      warn "Unknown keyring type: $keyring"
      return 1
      ;;
  esac

  return 0
}

# ---------------------------------------------------------------------------
# Nvidia Power Services
# ---------------------------------------------------------------------------
# Enables nvidia power management services.
# Used by: build, repatch workflows.

# Enable nvidia power services.
# Args: $1 = root path
# Returns 0 on success, 1 on failure
enable_nvidia_power_services() {
  local root="${1:?enable_nvidia_power_services: missing root}"

  log "Enabling nvidia power services"

  # Enable nvidia-powerd if available
  if [[ -f "$root/usr/lib/systemd/system/nvidia-powerd.service" ]]; then
    mkdir -p "$root/etc/systemd/system/multi-user.target.wants"
    ln -sf /usr/lib/systemd/system/nvidia-powerd.service \
      "$root/etc/systemd/system/multi-user.target.wants/nvidia-powerd.service" 2>/dev/null \
      || warn "Failed to enable nvidia-powerd (non-fatal)"
  fi

  # Enable nvidia-hibernate/suspend/resume if available
  local service target
  for service in nvidia-hibernate nvidia-suspend nvidia-resume; do
    if [[ -f "$root/usr/lib/systemd/system/${service}.service" ]]; then
      case "$service" in
        nvidia-hibernate) target="systemd-hibernate.target" ;;
        nvidia-suspend) target="systemd-suspend.target" ;;
        nvidia-resume) target="systemd-resume.target" ;;
      esac
      mkdir -p "$root/etc/systemd/system/${target}.wants"
      ln -sf "/usr/lib/systemd/system/${service}.service" \
        "$root/etc/systemd/system/${target}.wants/${service}.service" 2>/dev/null \
        || warn "Failed to enable $service (non-fatal)"
    fi
  done

  return 0
}

# ---------------------------------------------------------------------------
# Modprobe Configuration
# ---------------------------------------------------------------------------
# Installs modprobe configuration for nvidia.
# Used by: build, repatch workflows.

# Install nvidia modprobe configuration.
# Args: $1 = root path
# Returns 0 on success, 1 on failure
install_nvidia_modprobe_conf() {
  local root="${1:?install_nvidia_modprobe_conf: missing root}"

  # Skip if nvidia packages are not installed
  if [[ ! -d "$root/usr/share/nvidia" ]] \
    && [[ ! -f "$root/usr/bin/nvidia-smi" ]]; then
    log "Skipping nvidia modprobe configuration (nvidia not installed)"
    return 0
  fi

  local conf_dir="$root/etc/modprobe.d"
  log "Installing nvidia modprobe configuration"

  mkdir -p "$conf_dir"
  cat >"$conf_dir/99-nvidia-patch.conf" <<'EOF'
# Added by steamos-build-installer
blacklist nouveau
options nouveau modeset=0
options nvidia-drm modeset=1 fbdev=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
EOF

  return 0
}
