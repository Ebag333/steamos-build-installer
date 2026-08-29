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
    if [[ -f "$src_service" ]]; then
      mkdir -p "$(dirname "$service_file")"
      cp "$src_service" "$service_file"
      log "    Installed service file"
    else
      warn "    Service file not found at $src_service"
    fi
  fi

  # Install script
  if [[ ! -f "$install_script" ]]; then
    local src_script="$script_dir/lib/configs/install-staged-flatpaks.sh"
    if [[ -f "$src_script" ]]; then
      mkdir -p "$(dirname "$install_script")"
      install -m 755 "$src_script" "$install_script"
      log "    Installed staging script"
    else
      warn "    Staging script not found at $src_script"
    fi
  fi

  # Enable service
  if [[ ! -L "$wants_link" ]]; then
    mkdir -p "$(dirname "$wants_link")"
    ln -sf /etc/systemd/user/steamos-build-flatpak-install.service "$wants_link"
    log "    Enabled service"
  fi

  log "  Flatpak staging service installed"
  return 0
}

# Install flatpak packages from hw-packages-build.conf.
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

  return $rc
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

  # Remove existing keyring for a clean reset
  rm -rf "$root/etc/pacman.d/gnupg" 2>/dev/null || true

  # Initialize keyring
  case "$keyring" in
    archlinux)
      chroot "$root" pacman-key --init 2>/dev/null \
        || { warn "pacman-key --init failed"; return 1; }
      chroot "$root" pacman-key --populate archlinux 2>/dev/null \
        || { warn "pacman-key --populate archlinux failed"; return 1; }
      ;;
    holo)
      chroot "$root" pacman-key --init 2>/dev/null \
        || { warn "pacman-key --init failed"; return 1; }
      chroot "$root" pacman-key --populate holo 2>/dev/null \
        || { warn "pacman-key --populate holo failed"; return 1; }
      ;;
    both)
      chroot "$root" pacman-key --init 2>/dev/null \
        || { warn "pacman-key --init failed"; return 1; }
      chroot "$root" pacman-key --populate archlinux holo 2>/dev/null \
        || { warn "pacman-key --populate failed"; return 1; }
      ;;
    *)
      warn "Unknown keyring type: $keyring"
      return 1
      ;;
  esac

  return 0
}

# ---------------------------------------------------------------------------
# Root Filesystem Expansion
# ---------------------------------------------------------------------------
# Expand rootfs-A and rootfs-B to fill their partitions.
# Used by: post-install, live workflows.

resize_rootfs() {
  log "Expanding root filesystems to fill partitions"

  # Find all rootfs partitions (rootfs-A and rootfs-B)
  local part
  for part in /dev/disk/by-partsets/*/rootfs; do
    [[ -b "$part" ]] || continue

    local label
    label="$(lsblk -no PARTLABEL "$part" 2>/dev/null || basename "$(readlink -f "$part")")"
    echo "  Processing $label ($part)..."

    # If this is the active root, expand it directly
    if findmnt -n -o SOURCE / 2>/dev/null | grep -q "$(readlink -f "$part")"; then
      echo "    Active root — expanding online"
      btrfs filesystem resize max / 2>/dev/null \
        || warn "Failed to expand active root"
    else
      # Inactive root — mount temporarily, expand, unmount
      local tmpmnt
      tmpmnt="$(mktemp -d /tmp/resize-XXXXXX)"
      if mount -o ro "$part" "$tmpmnt" 2>/dev/null; then
        # Check if it's read-only btrfs (subvolid=5)
        if [[ "$(btrfs property get "$tmpmnt" ro 2>/dev/null)" == "ro=true" ]]; then
          echo "    Inactive root is read-only (subvolid=5), skipping"
        else
          # Remount rw and expand
          mount -o remount,rw "$tmpmnt" 2>/dev/null || true
          echo "    Expanding inactive root"
          btrfs filesystem resize max "$tmpmnt" 2>/dev/null \
            || warn "Failed to expand inactive root"
        fi
        umount "$tmpmnt" 2>/dev/null || true
      fi
      rmdir "$tmpmnt" 2>/dev/null || true
    fi
  done

  # Also expand the active root if we haven't already
  if ! findmnt -n -o SOURCE / 2>/dev/null | grep -q "rootfs"; then
    # Active root isn't on a partset path, try direct resize
    btrfs filesystem resize max / 2>/dev/null || true
  fi

  log "Root filesystem expansion complete"
  df -h / 2>/dev/null || true
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
        nvidia-suspend)   target="systemd-suspend.target" ;;
        nvidia-resume)    target="systemd-resume.target" ;;
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

# ---------------------------------------------------------------------------
# SteamOS Read-Only Mode
# ---------------------------------------------------------------------------
# Disable/enable SteamOS read-only filesystem protection.
# Used by: post-install, live pipeline, build workflows.

disable_steamos_readonly() {
  if command -v steamos-readonly >/dev/null 2>&1; then
    log "Disabling SteamOS read-only mode"
    steamos-readonly disable || true
  fi
}

enable_steamos_readonly() {
  if command -v steamos-readonly >/dev/null 2>&1; then
    log "Re-enabling SteamOS read-only mode"
    steamos-readonly enable || true
  fi
}

# ---------------------------------------------------------------------------
# Disk Cleanup
# ---------------------------------------------------------------------------
# Clean pacman cache, temp files, and journal logs.
# Used by: post-install, live pipeline.

cleanup_disk_space() {
  local root="${1:-/}"

  log "Cleaning up disk space"

  if [[ "$root" == "/" ]]; then
    pacman -Sc --noconfirm 2>/dev/null || warn "pacman cache cleanup failed"
  else
    chroot "$root" pacman -Sc --noconfirm 2>/dev/null || warn "pacman cache cleanup failed"
  fi

  rm -rf /tmp/* 2>/dev/null || true
  journalctl --vacuum-size=50M 2>/dev/null || warn "journal cleanup failed"

  local freed
  freed="$(df -m / | awk 'NR==2{print $4}')"
  log "Cleanup complete — ${freed}MB free on /"
}

# ---------------------------------------------------------------------------
# User Password
# ---------------------------------------------------------------------------
# Set user password (interactive).
# Used by: post-install, live pipeline.

set_user_password() {
  if passwd -S deck 2>/dev/null | grep -q "P"; then
    log "User 'deck' already has a password set"
    return 0
  fi
  log "Setting user password"
  echo ""
  echo "Enter a new password for the 'deck' user:"
  passwd deck
}
