#!/bin/bash
#
# post-install.sh
#
# SteamOS NVIDIA post-install configuration utility.
#
# Normal mode:
#   Run as the logged-in desktop user.
#   Displays a Zenity checklist of optional configuration changes.
#
# Worker mode:
#   Re-executes itself through pkexec with --apply.
#   Performs only the selected privileged operations.
#
# Safe to run repeatedly.

set -uo pipefail

TITLE="SteamOS NVIDIA Configuration"
LOG="/var/log/steamos-nvidia-post-install.log"
SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT")"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/common.sh"

# ============================================================
# Privileged worker
# ============================================================

PASS=0
FAIL=0

run_action() {
  local label="$1"
  local fn="$2"

  printf '%s... ' "$label"

  if "$fn"; then
    echo "✓"
    PASS=$((PASS + 1))
  else
    echo "✗"
    FAIL=$((FAIL + 1))
  fi
}

make_rootfs_writable() {
  if command -v steamos-readonly >/dev/null 2>&1; then
    log "Disabling SteamOS read-only mode"
    steamos-readonly disable || true
  fi
}

restore_rootfs_readonly() {
  if command -v steamos-readonly >/dev/null 2>&1; then
    log "Re-enabling SteamOS read-only mode"
    steamos-readonly enable || true
  fi
}

# ============================================================
# Thunderbolt
# ============================================================

apply_thunderbolt() {
  apply_optimization_for_item "thunderbolt" "live" "$config_root"
}

# ============================================================
# Hardware scan utility
# ============================================================

apply_hardware_scan() {
  log "Installing hardware scan utility"

  install -d -m755 /usr/local/bin/diagnostics \
    || return 1

  cat >/usr/local/bin/diagnostics/scan-hardware <<'SCANEOF'
#!/bin/bash

echo "=== Hardware scan: unclaimed PCI devices ==="
echo

found=0

while IFS= read -r line; do
    dev="$(echo "$line" | cut -d' ' -f1)"
    desc="$(echo "$line" | cut -d' ' -f2-)"

    vendor_device="$(
        echo "$line" |
            grep -oP '\[\K[0-9a-fA-F]{4}:[0-9a-fA-F]{4}' |
            head -1 ||
            true
    )"

    driver="$(
        lspci -k -s "$dev" 2>/dev/null |
            grep "Kernel driver in use" |
            awk '{print $NF}' ||
            true
    )"

    #
    # If a kernel driver already owns the device, it's fine.
    #
    [[ -n "$driver" ]] && continue

    found=1

    echo "Unclaimed: $dev $desc"

    if [[ -n "$vendor_device" ]]; then
        vendor="${vendor_device%:*}"
        device="${vendor_device#*:}"

        vendor="${vendor^^}"
        device="${device^^}"

        modalias="pci:v0000${vendor}d0000${device}sv*sd*bc*sc*i*"

        modules="$(
            modprobe -R "$modalias" 2>/dev/null |
                head -5 ||
                true
        )"

        if [[ -n "$modules" ]]; then
            echo "  Matching module(s):"
            echo "$modules" | sed 's/^/    /'
        else
            echo "  No matching kernel module found for $vendor_device"
        fi
    fi

    echo

done < <(lspci -nn)


if [[ $found -eq 0 ]]; then
    echo "All PCI devices have drivers loaded."
fi
SCANEOF

  chmod 755 /usr/local/bin/diagnostics/scan-hardware \
    || return 1

  log "Running hardware scan"
  /usr/local/bin/diagnostics/scan-hardware

  return 0
}

# ============================================================
# Default SteamOS session
# ============================================================

apply_desktop_mode() {
  log "Configuring desktop session"

  # Set desktop session defaults via steamosctl (safe, no session switch).
  if command -v steamosctl >/dev/null 2>&1; then
    steamosctl set-default-login-mode desktop 2>/dev/null \
      || warn "steamosctl set-default-login-mode failed (non-fatal)"
    steamosctl set-default-desktop-session plasma.desktop 2>/dev/null \
      || warn "steamosctl set-default-desktop-session failed (non-fatal)"
  else
    # Fallback: write config directly
    log "steamosctl not available, writing config directly"
    local config_dir="/home/deck/.config/steamos-manager"
    install -d -m755 "$config_dir" || return 1
    cat >"$config_dir/state.toml" <<'EOF'
version = 1

[services]

[session_manager]
default_login_mode = "Desktop"
EOF
    chown 1000:1000 "$config_dir/state.toml"
  fi

  # sddm.conf — ensure Session= points to Plasma, not gamescope.
  local sddm_conf="/etc/sddm.conf.d/steamos.conf"
  if [[ -f "$sddm_conf" ]]; then
    if grep -q '^Session=gamescope' "$sddm_conf"; then
      log "Switching sddm Session from gamescope to plasma.desktop"
      sed -i 's/^Session=gamescope.*/Session=plasma.desktop/' "$sddm_conf"
    fi
  fi

  log "Default login mode set to Desktop"
}

# ============================================================
# Set user password
# ============================================================

apply_set_password() {
  if passwd -S deck 2>/dev/null | grep -q "P"; then
    log "User 'deck' already has a password set"
    echo "Password already set. Use 'passwd deck' to change it."
    return 0
  fi
  log "Setting user password"
  echo ""
  echo "Enter a new password for the 'deck' user:"
  passwd deck
}

# ============================================================
# Lock screen
# ============================================================

apply_lock_screen() {
  # Lock screen requires a password — check first.
  if ! passwd -S deck 2>/dev/null | grep -q "P"; then
    warn "User 'deck' has no password set"
    echo "A password is required for the lock screen to work."
    echo ""
    echo "Set a password now:"
    passwd deck || return 1
  fi

  log "Enabling lock screen"

  # Write KDE lock screen config directly (kwriteconfig5 may not be available)
  local config_dir="/home/deck/.config"
  install -d -m755 "$config_dir" || return 1
  cat >"$config_dir/kscreenlockerrc" <<'EOF'
[Daemon]
Autolock=true
LockOnResume=true
Timeout=5
EOF
  chown 1000:1000 "$config_dir/kscreenlockerrc"
  log "Lock screen enabled (5 minute timeout)"
}

# ============================================================
# Disk cleanup
# ============================================================

apply_cleanup() {
  log "Cleaning up disk space"

  echo "  Cleaning pacman package cache..."
  pacman -Sc --noconfirm 2>/dev/null || warn "pacman cache cleanup failed"

  echo "  Cleaning /tmp..."
  rm -rf /tmp/* 2>/dev/null || true

  echo "  Trimming journal logs to 50MB..."
  journalctl --vacuum-size=50M 2>/dev/null || warn "journal cleanup failed"

  local freed
  freed="$(df -m / | awk 'NR==2{print $4}')"
  log "Cleanup complete — ${freed}MB free on /"
}

# ============================================================
# Expand root volumes to fill partitions
# ============================================================

apply_resize_roots() {
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

# ============================================================
# Reboot to specific root slot
# ============================================================

apply_reboot_to() {
  detect_roots

  local -a options=()
  [[ -n "$ROOT_A" ]] && options+=("A" "Root A ($ROOT_A)")
  [[ -n "$ROOT_B" ]] && options+=("B" "Root B ($ROOT_B)")

  if [[ ${#options[@]} -eq 0 ]]; then
    warn "No root partitions found"
    return 1
  fi

  local selected
  if command -v yad >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
    selected="$(yad --list \
      --title="Reboot to..." \
      --text="Select which root to boot into on next restart:" \
      --column="Slot" --column="Device" \
      --width=400 --height=200 \
      --selectable-rows \
      --print-column=1 \
      "${options[@]}" 2>/dev/null)" || return 0
    selected="$(echo "$selected" | tr -d '|' | tr -d '\n' | xargs)"
  else
    echo ""
    echo "Reboot to which slot?"
    [[ -n "$ROOT_A" ]] && echo "  1) Root A ($ROOT_A)"
    [[ -n "$ROOT_B" ]] && echo "  2) Root B ($ROOT_B)"
    read -rp "Choice: " choice
    case "$choice" in
      1) selected="A" ;;
      2) selected="B" ;;
      *) return 0 ;;
    esac
  fi

  local target_dev=""
  case "$selected" in
    A) target_dev="$ROOT_A" ;;
    B) target_dev="$ROOT_B" ;;
    *) return 0 ;;
  esac

  log "Setting next boot to Root $selected ($target_dev)"

  # Use steamos-bootconf with the bootconf file path
  local conf_file="/esp/SteamOS/conf/${selected}.conf"
  if [[ -f "$conf_file" ]]; then
    local now
    now="$(date -u +%Y%m%d%H%M%S)"

    # Set target slot to boot next
    sed -i "s/^boot-requested-at:.*/boot-requested-at: $now/" "$conf_file" \
      || {
        warn "Failed to set boot-requested-at for $selected"
        return 1
      }

    # Clear the other slot
    local other="A"
    [[ "$selected" == "A" ]] && other="B"
    local other_conf="/esp/SteamOS/conf/${other}.conf"
    [[ -f "$other_conf" ]] \
      && sed -i "s/^boot-requested-at:.*/boot-requested-at: 0/" "$other_conf" 2>/dev/null

    log "Boot slot set: $selected will boot on next restart"
    return 0
  fi

  # Fallback: try efibootmgr
  if command -v efibootmgr >/dev/null 2>&1; then
    local boot_num
    boot_num="$(efibootmgr 2>/dev/null | grep -i "steam" | grep -oP 'Boot\K[0-9]+')"
    if [[ -n "$boot_num" ]]; then
      efibootmgr -n "$boot_num" 2>/dev/null \
        && log "Boot slot set via efibootmgr: Boot$boot_num" && return 0
    fi
  fi

  warn "Could not set boot slot automatically"
  return 1
}

# ============================================================
# Pacman keyring fix
# ============================================================

apply_keyring() {
  log "Initialising pacman keyring"
  rm -rf "$config_root/etc/pacman.d/gnupg" \
    || return 1
  if [[ "$config_root" == "/" ]]; then
    pacman-key --init \
      || return 1
    pacman-key --populate archlinux holo \
      || return 1
  else
    # Offline root: run inside chroot
    chroot "$config_root" pacman-key --init \
      || return 1
    chroot "$config_root" pacman-key --populate archlinux holo \
      || return 1
  fi
  log "Keyring initialised"
}

# ============================================================
# Gamemode: group membership + user service
# ============================================================

apply_gamemode() {
  log "Configuring gamemode"
  if [[ "$config_root" == "/" ]]; then
    if getent group gamemode >/dev/null 2>&1; then
      usermod -aG gamemode deck \
        || warn "Failed to add deck to gamemode group"
    else
      warn "gamemode group not found — skipping group membership"
    fi
    install -d -m755 /etc/systemd/user/graphical-session.target.wants
    ln -sf /usr/lib/systemd/user/gamemoded.service \
      /etc/systemd/user/graphical-session.target.wants/gamemoded.service \
      || warn "Failed to enable gamemoded user service"
  else
    if chroot "$config_root" getent group gamemode >/dev/null 2>&1; then
      chroot "$config_root" usermod -aG gamemode deck \
        || warn "Failed to add deck to gamemode group"
    else
      warn "gamemode group not found — skipping group membership"
    fi
    install -d -m755 "$config_root/etc/systemd/user/graphical-session.target.wants"
    ln -sf /usr/lib/systemd/user/gamemoded.service \
      "$config_root/etc/systemd/user/graphical-session.target.wants/gamemoded.service" \
      || warn "Failed to enable gamemoded user service"
  fi
  log "Gamemode configured"
}

# ============================================================
# Disable automatic login
# ============================================================

apply_disable_autologin() {
  log "Disabling automatic login"
  local sddm_conf="$config_root/etc/sddm.conf.d/steamos.conf"
  if [[ -f "$sddm_conf" ]]; then
    if grep -q '^Relogin=true' "$sddm_conf"; then
      sed -i 's/^Relogin=true/Relogin=false/' "$sddm_conf"
      log "Auto login disabled (Relogin=false)"
    else
      log "Auto login already disabled"
    fi
  else
    warn "sddm.conf not found — cannot disable auto login"
    return 1
  fi
}

# ============================================================
# scx_lavd scheduler (autopilot)
# ============================================================

apply_scx_lavd() {
  log "Configuring scx_lavd scheduler"
  if [[ ! -x "$config_root/usr/bin/scx_lavd" ]]; then
    warn "scx_lavd not found in $config_root — install scx-scheds first"
    return 1
  fi
  local config_src="$SCRIPT_DIR/configs/scx_loader_config.toml"
  local config_dir="$config_root/etc/scx_loader"
  local wants_dir="$config_root/etc/systemd/system/multi-user.target.wants"
  if [[ ! -f "$config_src" ]]; then
    warn "scx_loader_config.toml not found in installer configs"
    return 1
  fi
  if [[ "$config_root" == "/" ]]; then
    install -d -m755 "$config_dir"
    cp "$config_src" "$config_dir/config.toml"
    install -d -m755 "$wants_dir"
    ln -sf /usr/lib/systemd/system/scx.service \
      "$wants_dir/scx.service" \
      || warn "Failed to enable scx.service"
    systemctl daemon-reload
    systemctl restart scx.service 2>/dev/null \
      || warn "Failed to start scx.service (will activate on next boot)"
  else
    install -d -m755 "$config_dir"
    cp "$config_src" "$config_dir/config.toml"
    install -d -m755 "$wants_dir"
    ln -sf /usr/lib/systemd/system/scx.service \
      "$wants_dir/scx.service" \
      || warn "Failed to enable scx.service"
  fi
  log "scx_lavd configured via scx_loader (autopilot, pinned-slice-us 500)"
}

# ============================================================
# VM tunables (swappiness)
# ============================================================

apply_vm_tunables() {
  log "Configuring vm.swappiness"
  local has_zram=0 current_swappiness conf_src

  if [[ "$config_root" == "/" ]]; then
    # Online: detect zram from the running system.
    [[ -e /sys/block/zram0 ]] && has_zram=1
    current_swappiness="$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 60)"
  else
    # Offline: detect zram from the target image's generator config.
    if [[ -e "$config_root/usr/lib/systemd/zram-generator.conf" ]] \
      || [[ -e "$config_root/etc/systemd/zram-generator.conf" ]] \
      || [[ -e "$config_root/usr/lib/systemd/zram-generator.conf.d" ]] \
      || [[ -e "$config_root/etc/systemd/zram-generator.conf.d" ]]; then
      has_zram=1
    fi
    current_swappiness="$(cat "$config_root/proc/sys/vm/swappiness" 2>/dev/null || echo 60)"
  fi

  if ((has_zram)) && ((current_swappiness < 100)); then
    conf_src="$SCRIPT_DIR/configs/swappiness-zram.conf"
  elif ((!has_zram)) && ((current_swappiness > 10)); then
    conf_src="$SCRIPT_DIR/configs/swappiness-disk.conf"
  else
    log "vm.swappiness already appropriate (${current_swappiness}, zram=${has_zram}) — skipping"
    return 0
  fi

  install -d -m755 "$config_root/etc/sysctl.d"
  cp "$conf_src" "$config_root/etc/sysctl.d/99-vm-swappiness.conf"

  if [[ "$config_root" == "/" ]]; then
    local target_val
    target_val="$(grep -oP 'vm\.swappiness\s*=\s*\K[0-9]+' "$conf_src")"
    sysctl -q -w "vm.swappiness=$target_val" 2>/dev/null \
      || warn "Failed to apply swappiness live (will take effect on next boot)"
  fi
  log "vm.swappiness configured (zram=${has_zram}, was ${current_swappiness})"
}

# ============================================================
# Boot-time performance hooks
# ============================================================

apply_boot_framework() {
  local item="${1:-all}"
  log "Installing steam-perf boot framework ($item)"

  local boot_src="$SCRIPT_DIR/configs/boot"
  local boot_dst="/usr/lib/steam-perf"

  if [[ ! -d "$boot_src" ]]; then
    warn "Boot hook sources not found at $boot_src"
    return 1
  fi

  install -d -m755 "$boot_dst/boot.d"
  install -d -m755 /etc/steam-perf

  cp "$boot_src/apply-boot" "$boot_dst/apply-boot"
  chmod 755 "$boot_dst/apply-boot"
  cp "$boot_src/config.conf" /etc/steam-perf/config.conf

  if [[ "$item" == "cpu-performance" || "$item" == "all" ]]; then
    cp "$boot_src/30-cpu" "$boot_dst/boot.d/30-cpu"
    chmod 755 "$boot_dst/boot.d/30-cpu"
  fi
  if [[ "$item" == "gpu-power-limit" || "$item" == "all" ]]; then
    cp "$boot_src/20-nvidia-gpu" "$boot_dst/boot.d/20-nvidia-gpu"
    chmod 755 "$boot_dst/boot.d/20-nvidia-gpu"
    cp "$boot_src/25-amd-gpu" "$boot_dst/boot.d/25-amd-gpu"
    chmod 755 "$boot_dst/boot.d/25-amd-gpu"
  fi

  cp "$boot_src/steam-perf.service" /usr/lib/systemd/system/steam-perf.service
  install -d -m755 /etc/systemd/system/multi-user.target.wants
  ln -sf /usr/lib/systemd/system/steam-perf.service \
    /etc/systemd/system/multi-user.target.wants/steam-perf.service \
    || warn "Failed to enable steam-perf.service"
  systemctl daemon-reload 2>/dev/null || true

  log "steam-perf boot framework installed ($item)"
}

# ============================================================
# NVIDIA initramfs configuration
# ============================================================

# ============================================================
# Critical modules for initramfs
# ============================================================
# Module list is now sourced from configs/initramfs.conf via initramfs.sh

# Detect which root partition is currently active and which is A/B.
detect_roots() {
  local current_dev
  current_dev="$(findmnt -n -o SOURCE / 2>/dev/null || true)"

  ROOT_CURRENT=""
  ROOT_A=""
  ROOT_B=""
  ROOT_CURRENT_LABEL=""

  # Find rootfs-A and rootfs-B partitions
  while IFS= read -r line; do
    local dev label
    dev="/dev/$(echo "$line" | awk '{print $1}')"
    label="$(echo "$line" | awk '{print $2}')"
    case "$label" in
      rootfs-A) ROOT_A="$dev" ;;
      rootfs-B) ROOT_B="$dev" ;;
    esac
  done < <(lsblk -dno NAME,PARTLABEL /dev/nvme[0-9]* 2>/dev/null)

  # Identify which is current
  if [[ -n "$current_dev" ]]; then
    if [[ "$current_dev" == "$ROOT_A" ]]; then
      # shellcheck disable=SC2034
      ROOT_CURRENT="A"
      ROOT_CURRENT_LABEL="Root A (current)"
    elif [[ "$current_dev" == "$ROOT_B" ]]; then
      # shellcheck disable=SC2034
      ROOT_CURRENT="B"
      ROOT_CURRENT_LABEL="Root B (current)"
    fi
  fi
}

apply_critical_modules() {
  log "Configuring critical modules for initramfs"

  # Get all modules from initramfs.conf (replaces hardcoded list)
  local all_modules
  all_modules="$(get_all_initramfs_modules_force)"

  # Detect if Thunderbolt is present (eGPU indicator).
  local has_thunderbolt=0
  if lspci 2>/dev/null | grep -qi thunderbolt; then
    has_thunderbolt=1
  fi

  # Ask about eGPU if Thunderbolt is detected.
  local egpu_mode="none"
  if [[ $has_thunderbolt -eq 1 ]]; then
    egpu_mode="$(yad --list \
      --title="GPU Configuration" \
      --text="Thunderbolt detected. How is your NVIDIA GPU connected?" \
      --column="Mode" --column="Description" \
      --width=500 --height=250 \
      --selectable-rows \
      --print-column=1 \
      "internal" "NVIDIA GPU is built-in (load early from initramfs)" \
      "egpu" "NVIDIA GPU is external via Thunderbolt (load after TB ready)" \
      2>/dev/null)" || true
    egpu_mode="$(echo "$egpu_mode" | tr -d '|' | tr -d '\n' | xargs)"
  fi
  log "GPU mode: ${egpu_mode:-internal}"

  # Scan which modules are currently loaded or have hardware present.
  local -a recommended=()
  local mod

  for mod in $all_modules; do
    # Skip nvidia modules for eGPU — they must load after Thunderbolt.
    if [[ "$egpu_mode" == "egpu" && "$mod" == nvidia* ]]; then
      continue
    fi
    # Check if module is loaded or has PCI hardware that needs it
    if lsmod 2>/dev/null | grep -q "^${mod} " \
      || modinfo "$mod" >/dev/null 2>&1; then
      recommended+=("$mod")
    fi
  done

  # Show checklist with recommended modules pre-checked.
  local -a checklist_args=()
  for mod in $all_modules; do
    local desc=""
    # Get description from initramfs.conf groups
    local group
    for group in "${!_INITRAMFS_GROUP_MODULES[@]}"; do
      if [[ " ${_INITRAMFS_GROUP_MODULES[$group]} " == *" $mod "* ]]; then
        desc="${_INITRAMFS_GROUP_DESC[$group]}"
        break
      fi
    done

    local check="FALSE"
    for r in "${recommended[@]}"; do
      [[ "$r" == "$mod" ]] && check="TRUE" && break
    done

    checklist_args+=("$check" "$mod" "$desc")
  done

  local selected
  local egpu_note=""
  if [[ "$egpu_mode" == "egpu" ]]; then
    egpu_note="\n\n<b>eGPU mode:</b> nvidia modules excluded — they load via udev after Thunderbolt."
  fi
  selected="$(yad --list --checklist \
    --title="Critical Modules for Initramfs" \
    --text="Select modules to include in the initramfs.\n\nThese load before the root filesystem mounts.\nChecked = recommended for your hardware.$egpu_note" \
    --column="" --column="Module" --column="Description" \
    --width=550 --height=500 \
    --separator=' ' \
    --print-column=2 \
    "${checklist_args[@]}" 2>/dev/null)" || return 0

  # Clean up selection
  selected="$(echo "$selected" | tr -d '|' | xargs)"
  [[ -n "$selected" ]] || {
    log "No modules selected"
    return 0
  }

  log "Selected modules: $selected"

  # Detect kernel version
  local kver
  kver="$(find "$config_root/usr/lib/modules/" -maxdepth 1 -mindepth 1 -printf '%f\n' 2>/dev/null | head -1)"
  if [[ -z "$kver" ]]; then
    warn "Could not detect kernel version in $config_root/usr/lib/modules/"
    kver="$(uname -r)"
    log "Falling back to running kernel: $kver"
  else
    log "Target kernel: $kver"
  fi

  # Apply via initramfs.sh
  if [[ "$config_root" == "/" ]]; then
    # Live system — regenerate immediately
    apply_initramfs "/" "$kver" "$selected"
  else
    # Offline target — write config only, regenerate after boot
    write_initramfs_config "$config_root" "$kver" "$selected" \
      || warn "Failed to write initramfs config (will regenerate on boot)"
  fi

  log "Critical modules configured: $selected"

  # If eGPU mode, remove nvidia early-loading from grub so nvidia loads
  # via udev after Thunderbolt is ready.
  # The grub config is shared (EFI partition), so clean both target root AND current system.
  if [[ "$egpu_mode" == "egpu" ]]; then
    log "eGPU mode: removing nvidia early-loading from grub"
    local nvidia_params=" $NVIDIA_CMDLINE_ADD"
    local grub_changed=0

    # Clean target root's grub config
    if [[ -f "$config_root/etc/default/grub" ]]; then
      if grep -q "nvidia-drm.modeset" "$config_root/etc/default/grub"; then
        sed -i "s/$nvidia_params//" "$config_root/etc/default/grub"
        grub_changed=1
        log "  Removed from $config_root/etc/default/grub"
      fi
    fi

    # Clean EFI grub.cfg on target root
    local efi_grub="$config_root/efi/EFI/steamos/grub.cfg"
    if [[ -f "$efi_grub" ]]; then
      if grep -q "nvidia-drm.modeset" "$efi_grub"; then
        sed -i "s/$nvidia_params//" "$efi_grub"
        grub_changed=1
        log "  Removed from $efi_grub"
      fi
    fi

    # Also clean current system's grub (shared EFI partition)
    if [[ "$config_root" != "/" ]]; then
      if [[ -f "/etc/default/grub" ]] && grep -q "nvidia-drm.modeset" "/etc/default/grub"; then
        sed -i "s/$nvidia_params//" "/etc/default/grub"
        grub_changed=1
        log "  Removed from current system /etc/default/grub"
      fi
      if [[ -f "/efi/EFI/steamos/grub.cfg" ]] && grep -q "nvidia-drm.modeset" "/efi/EFI/steamos/grub.cfg"; then
        sed -i "s/$nvidia_params//" "/efi/EFI/steamos/grub.cfg"
        grub_changed=1
        log "  Removed from current system EFI grub.cfg"
      fi
    fi

    if [[ $grub_changed -eq 1 ]]; then
      log "Nvidia early-loading removed — nvidia will load via udev after Thunderbolt"
    else
      log "No nvidia early-loading params found in grub"
    fi
  fi
}

# ============================================================
# Root detection and selection
# ============================================================

select_target_root() {
  detect_roots

  log "Detected roots: A=${ROOT_A:-none} B=${ROOT_B:-none} Current=${ROOT_CURRENT_LABEL:-unknown}"

  local -a options=()
  local current_label="${ROOT_CURRENT_LABEL:-Current (unknown)}"

  # selectable-rows: click a row to select it, OK to confirm
  options+=("current" "$current_label")
  [[ -n "$ROOT_A" ]] && options+=("A" "Root A ($ROOT_A)")
  [[ -n "$ROOT_B" ]] && options+=("B" "Root B ($ROOT_B)")

  log "Options: ${options[*]}"

  local selected

  # Use yad (consistent with gui.sh)
  if command -v yad >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
    selected="$(yad --list \
      --title="Select Target Root" \
      --text="Which root filesystem should be configured?" \
      --column="Target" --column="Device" \
      --width=400 --height=250 \
      --selectable-rows \
      --print-column=1 \
      "${options[@]}" 2>/dev/null)" || true
    selected="$(echo "$selected" | tr -d '|' | tr -d '\n' | xargs)"
  fi

  # Fall back to terminal if no display
  if [[ -z "$selected" ]]; then
    echo ""
    echo "Select target root filesystem:"
    echo "  1) Current (${ROOT_CURRENT_LABEL:-unknown})"
    [[ -n "$ROOT_A" ]] && echo "  2) Root A ($ROOT_A)"
    [[ -n "$ROOT_B" ]] && echo "  3) Root B ($ROOT_B)"
    echo ""
    read -rp "Choice [1]: " choice
    case "${choice:-1}" in
      1) selected="current" ;;
      2) selected="A" ;;
      3) selected="B" ;;
      *) selected="current" ;;
    esac
  fi

  log "User selected: '$selected'"

  case "$selected" in
    current)
      TARGET_ROOT=""
      TARGET_ROOT_LABEL="Current root"
      ;;
    A)
      TARGET_ROOT="$ROOT_A"
      TARGET_ROOT_LABEL="Root A"
      ;;
    B)
      TARGET_ROOT="$ROOT_B"
      TARGET_ROOT_LABEL="Root B"
      ;;
    *)
      log "Unknown selection: '$selected'"
      return 1
      ;;
  esac
}

# ============================================================
# Privileged action dispatcher
# ============================================================

apply_actions() {
  local selected="$1"
  local target_root="${2:-}" # empty = current root
  local action
  local -a actions

  if [[ $EUID -ne 0 ]]; then
    echo "Privileged worker must run as root." >&2
    return 1
  fi

  mkdir -p "$(dirname "$LOG")"

  #
  # Everything from here goes both to the terminal/pkexec process
  # and the persistent log.
  #
  exec > >(tee -a "$LOG") 2>&1

  echo
  echo "=============================================="
  echo " SteamOS NVIDIA Post-Install Configuration"
  echo "=============================================="
  echo
  date
  echo

  # ---- Set up chroot for offline root ----
  local config_root="/"
  local needs_umount=0
  local target_label="Current root"

  if [[ -n "$target_root" ]]; then
    target_label="$(lsblk -no PARTLABEL "$target_root" 2>/dev/null || echo "$target_root")"
    config_root="/tmp/post-install-root-$$"
    mkdir -p "$config_root"
    log "Mounting $target_label ($target_root) at $config_root"
    mount -o rw "$target_root" "$config_root" || die "Failed to mount $target_root"
    needs_umount=1

    # Set up chroot environment
    mount -t proc proc "$config_root/proc"
    mount --rbind /sys "$config_root/sys"
    mount --rbind /dev "$config_root/dev"
  fi

  log "Target: $target_label"

  make_rootfs_writable

  #
  # Restore SteamOS filesystem protection regardless of how the
  # worker exits.
  #
  trap restore_rootfs_readonly EXIT

  IFS='|' read -r -a actions <<<"$selected"
  log "Worker received ${#actions[@]} actions: ${actions[*]}"

  for action in "${actions[@]}"; do
    case "$action" in

      resize)
        run_action \
          "Expanding root filesystems" \
          apply_resize_roots
        ;;

      thunderbolt)
        run_action \
          "Configuring Thunderbolt support" \
          apply_thunderbolt
        ;;

      hardware-scan)
        run_action \
          "Installing hardware scan utility" \
          apply_hardware_scan
        ;;

      desktop)
        run_action \
          "Setting Desktop Mode as default" \
          apply_desktop_mode
        ;;

      initramfs)
        run_action \
          "Configuring critical modules for initramfs" \
          apply_critical_modules
        ;;

      keyring)
        run_action \
          "Initialising pacman keyring" \
          apply_keyring
        ;;

      gamemode)
        run_action \
          "Configuring gamemode" \
          apply_gamemode
        ;;

      disable-autologin)
        run_action \
          "Disabling automatic login" \
          apply_disable_autologin
        ;;

      scx-lavd)
        run_action \
          "Configuring scx_lavd scheduler" \
          apply_scx_lavd
        ;;

      vm-tunables)
        run_action \
          "Configuring vm.swappiness" \
          apply_vm_tunables
        ;;

      cpu-performance)
        run_action \
          "Installing CPU performance boot hook" \
          apply_boot_framework "cpu-performance"
        ;;

      gpu-power-limit)
        run_action \
          "Installing GPU power limit boot hook" \
          apply_boot_framework "gpu-power-limit"
        ;;

      password)
        run_action \
          "Setting user password" \
          apply_set_password
        ;;

      lockscreen)
        run_action \
          "Enabling lock screen" \
          apply_lock_screen
        ;;

      cleanup)
        run_action \
          "Cleaning up disk space" \
          apply_cleanup
        ;;

      reboot)
        run_action \
          "Selecting boot slot" \
          apply_reboot_to
        ;;

      "") ;;

      *)
        warn "Unknown action: $action"
        FAIL=$((FAIL + 1))
        ;;
    esac
  done

  # ---- Regenerate initramfs if targeting offline root ----
  if [[ $needs_umount -eq 1 ]]; then
    log "Regenerating initramfs for $target_label"
    local regen_done=0
    if [[ -x "$config_root/usr/bin/dracut" ]]; then
      if chroot "$config_root" dracut -f; then
        regen_done=1
      else
        warn "dracut regeneration failed"
      fi
    elif [[ -x "$config_root/usr/bin/mkinitcpio" ]]; then
      if chroot "$config_root" mkinitcpio -P; then
        regen_done=1
      else
        warn "mkinitcpio regeneration failed"
      fi
    fi
    if [[ $regen_done -eq 0 ]]; then
      warn "No initramfs tool found in $target_label"
      warn "Creating first-boot service to regenerate initramfs"
      # Create a oneshot service that regenerates initramfs on first boot
      mkdir -p "$config_root/etc/systemd/system"
      cat >"$config_root/etc/systemd/system/steamos-nvidia-initramfs.service" <<'SVCEOF'
[Unit]
Description=Regenerate initramfs with NVIDIA modules
DefaultDependencies=no
After=local-fs.target
Before=display-manager.service
ConditionPathExists=/etc/mkinitcpio.conf.d/99-steamos-nvidia.conf

[Service]
Type=oneshot
ExecStart=/usr/bin/mkinitcpio -P
ExecStartPost=/bin/rm -f /etc/systemd/system/steamos-nvidia-initramfs.service
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF
      # Enable the service (symlink in multi-user.target.wants)
      mkdir -p "$config_root/etc/systemd/system/multi-user.target.wants"
      ln -sf ../steamos-nvidia-initramfs.service \
        "$config_root/etc/systemd/system/multi-user.target.wants/steamos-nvidia-initramfs.service"
      log "First-boot initramfs service created"
    fi
  fi

  # ---- Cleanup chroot ----
  if [[ $needs_umount -eq 1 ]]; then
    log "Unmounting $target_label"
    umount -R "$config_root/proc" "$config_root/sys" "$config_root/dev" 2>/dev/null || true
    umount "$config_root" 2>/dev/null || true
    rmdir "$config_root" 2>/dev/null || true
  fi

  # ---- Run user-provided custom script if present (fail open) ----
  local _custom="$config_root/home/.steamos-nvidia/recovery/custom.sh"
  if [[ -x "$_custom" ]]; then
    log "Running custom script: $_custom"
    if bash "$_custom" 2>&1; then
      log "Custom script completed successfully"
    else
      warn "Custom script exited with non-zero status (non-fatal)"
    fi
  else
    log "No custom script at $_custom — skipping"
  fi

  echo
  echo "=============================================="
  echo " Results"
  echo "=============================================="
  echo
  echo "Successful: $PASS"
  echo "Failed:     $FAIL"
  echo
  echo "Log: $LOG"
  echo

  if ((FAIL > 0)); then
    return 1
  fi

  return 0
}

# ============================================================
# Worker entry point
# ============================================================

if [[ "${1:-}" == "--apply" ]]; then
  shift

  selected="${1:-}"
  TARGET_ROOT="${2:-}" # empty = current root, otherwise partition device

  if [[ -z "$selected" ]]; then
    echo "No configuration actions supplied." >&2
    exit 1
  fi

  apply_actions "$selected" "$TARGET_ROOT"
  exit $?
fi

# --reboot-only: just show the reboot-to-slot dialog
if [[ "${1:-}" == "--reboot-only" ]]; then
  apply_reboot_to
  exit $?
fi

# ============================================================
# GUI frontend
# ============================================================

#
# The GUI must run as the desktop user.
#
if [[ $EUID -eq 0 ]]; then
  echo "Run this configuration utility as the logged-in desktop user."
  echo
  echo "Do not run it with sudo."
  exit 1
fi

if ! command -v yad >/dev/null 2>&1; then
  echo "yad is required for the graphical configuration utility."
  exit 1
fi

if ! command -v pkexec >/dev/null 2>&1 && ! command -v sudo >/dev/null 2>&1; then
  yad \
    --error \
    --title="$TITLE" \
    --width=400 \
    --text="<b>Neither pkexec nor sudo was found.</b>

Administrator privileges are required to apply system configuration changes."

  exit 1
fi

# ============================================================
# Configuration checklist
# ============================================================

# Select target root first
TARGET_ROOT=""
if ! select_target_root; then
  log "Root selection failed or cancelled"
  exit 0
fi

target_label="Online (current root)"
pw_check="TRUE"
cleanup_check="TRUE"
desktop_check="TRUE"
lockscreen_check="TRUE"
hw_scan_desc="Scan for unclaimed hardware and missing drivers"
pw_desc="Set user password (requires running system)"
cleanup_desc="Clean up disk space (pacman cache, /tmp, logs)"
desktop_desc="Boot into Desktop Mode by default"
lockscreen_desc="Enable lock screen (requires password)"

if [[ -n "$TARGET_ROOT" ]]; then
  target_label="Offline: $TARGET_ROOT_LABEL ($TARGET_ROOT)"
  # Online-only actions are not available for offline roots
  pw_check="FALSE"
  cleanup_check="FALSE"
  desktop_check="FALSE"
  lockscreen_check="FALSE"
  hw_scan_desc="Scan for unclaimed hardware [runs against current OS]"
  pw_desc="Set user password (requires running system) [N/A offline]"
  cleanup_desc="Clean up disk space (pacman cache, /tmp, logs) [N/A offline]"
  desktop_desc="Boot into Desktop Mode by default [N/A offline]"
  lockscreen_desc="Enable lock screen (requires password) [N/A offline]"
fi

SELECTED="$(
  yad \
    --list \
    --checklist \
    --title="$TITLE" \
    --text="Select the changes you want to apply:\n\n<b>Target: $target_label</b>\n\nOnline actions require the running system.\nOffline actions can be applied to a mounted root." \
    --width=760 \
    --height=420 \
    --column="Apply" \
    --column="#" \
    --column="ID" \
    --column="Mode" \
    --column="Configuration change" \
    --hide-column=3 \
    --print-column=3 \
    --separator='|' \
    --sort-column=2 \
    TRUE 1 resize "offline" "Expand root filesystems to fill partitions" \
    TRUE 2 thunderbolt "offline" "Configure Thunderbolt dock and hotplug support" \
    TRUE 3 hardware-scan "offline" "$hw_scan_desc" \
    "$desktop_check" 4 desktop "online" "$desktop_desc" \
    TRUE 5 initramfs "offline" "Add critical modules to initramfs (interactive)" \
    TRUE 6 keyring "offline" "Fix pacman keyring (required for package installs)" \
    TRUE 7 gamemode "online" "Enable gamemode: add deck to group + enable gamemoded service" \
    TRUE 8 scx-lavd "offline" "Enable scx_lavd scheduler (autopilot) for frametime consistency" \
    TRUE 9 vm-tunables "offline" "Tune vm.swappiness for zram (180) or disk swap (10)" \
    TRUE 10 cpu-performance "offline" "Set CPU governor + EPP to performance on every boot" \
    TRUE 11 gpu-power-limit "offline" "Raise discrete GPU power limit to vendor ceiling on every boot" \
    "$pw_check" 12 password "online" "$pw_desc" \
    "$lockscreen_check" 13 lockscreen "online" "$lockscreen_desc" \
    "$cleanup_check" 14 cleanup "online" "$cleanup_desc" \
    TRUE 15 reboot "online" "Reboot to specific root slot (A/B)"
)"

YAD_RC=$?

#
# Cancel or window close.
#
if [[ $YAD_RC -ne 0 ]]; then
  exit 0
fi

#
# OK with nothing selected.
#
# yad returns multiple selected rows separated by newlines (or | if only column)
# Normalize to pipe-separated, strip empty entries
SELECTED="$(echo "$SELECTED" | tr -s '\n' '|' | sed 's/^|//;s/|$//')"
log "Selected actions: '$SELECTED'"
if [[ -z "$SELECTED" ]]; then
  yad \
    --info \
    --title="$TITLE" \
    --width=360 \
    --text="No configuration changes were selected."

  exit 0
fi

IFS='|' read -r -a SELECTED_ARRAY <<<"$SELECTED"
COUNT="${#SELECTED_ARRAY[@]}"

# ============================================================
# Elevate only the worker
# ============================================================

# Elevate only the worker — prefer sudo, fall back to pkexec.
if command -v sudo >/dev/null 2>&1; then
  sudo /bin/bash "$SCRIPT" --apply "$SELECTED" "$TARGET_ROOT"
elif command -v pkexec >/dev/null 2>&1; then
  pkexec /bin/bash "$SCRIPT" --apply "$SELECTED" "$TARGET_ROOT"
else
  echo "Neither sudo nor pkexec found." >&2
  exit 1
fi
RC=$?
if [[ $RC -eq 0 ]]; then

  yad \
    --info \
    --title="$TITLE" \
    --width=450 \
    --text="<b>Configuration complete.</b>

$COUNT selected configuration item(s) completed successfully.

Some changes may require a reboot to take effect."

else
  yad \
    --warning \
    --title="$TITLE" \
    --width=500 \
    --text="<b>Configuration completed with one or more errors.</b>

Check the log for details:

$LOG

Worker exit code: $RC"
fi
