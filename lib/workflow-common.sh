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

  apply_system_config "default-session" "$root" "$session"
}

# ---------------------------------------------------------------------------
# Custom Script Execution
# ---------------------------------------------------------------------------
# Runs user-provided custom script if present.
# Used by: build, repatch, live workflows.

# Run custom script if present.
# Args: $1 = root path (optional, defaults to /)
# Returns 0 on success or script not found, 1 on script failure
run_custom_script() {
  local root="${1:-/}"
  local custom="$root/home/.steamos-build/recovery/custom.sh"

  if [[ -f "$custom" ]]; then
    log "Running custom script: $custom"
    if bash "$custom" 2>&1; then
      log "Custom script completed successfully"
      return 0
    else
      warn "Custom script exited with non-zero status (non-fatal)"
      return 0 # Non-fatal
    fi
  else
    log "No custom script at $custom — skipping"
    return 0
  fi
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

  # Get partition and filesystem sizes
  local part_size fs_size
  part_size="$(btrfs filesystem show "$mount_point" 2>/dev/null | grep -oP 'total size \K[0-9]+' || echo 0)"
  fs_size="$(btrfs filesystem show "$mount_point" 2>/dev/null | grep -oP 'devid.*size \K[0-9]+' || echo 0)"

  if [[ "$part_size" -gt "$fs_size" ]]; then
    log "  Expanding btrfs filesystem to fill partition"
    if btrfs filesystem resize max "$mount_point" 2>/dev/null; then
      log "  Filesystem expanded successfully"
      return 0
    else
      warn "Failed to expand filesystem"
      return 1
    fi
  else
    log "  Filesystem already fills partition"
    return 0
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
  if ! chroot "$root" /bin/sh -c 'command -v "$1" >/dev/null 2>&1' sh pacman; then
    warn "pacman not available in target"
    return 1
  fi

  # Initialize keyring
  case "$keyring" in
    archlinux)
      chroot "$root" pacman-key --init 2>/dev/null
      chroot "$root" pacman-key --populate archlinux 2>/dev/null
      ;;
    holo)
      chroot "$root" pacman-key --init 2>/dev/null
      chroot "$root" pacman-key --populate holo 2>/dev/null
      ;;
    both)
      chroot "$root" pacman-key --init 2>/dev/null
      chroot "$root" pacman-key --populate archlinux holo 2>/dev/null
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

  # Enable nvidia-hibernate/suspend if available
  local service
  for service in nvidia-hibernate nvidia-suspend nvidia-resume; do
    if [[ -f "$root/usr/lib/systemd/system/${service}.service" ]]; then
      mkdir -p "$root/etc/systemd/system/systemd-hibernate.target.wants"
      ln -sf "/usr/lib/systemd/system/${service}.service" \
        "$root/etc/systemd/system/systemd-hibernate.target.wants/${service}.service" 2>/dev/null \
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
