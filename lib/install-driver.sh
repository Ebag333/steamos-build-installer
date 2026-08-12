#!/bin/bash
#
# steamos-nvidia-installer — lib/install-driver.sh
# Stage 4: copy the computed payload (files + modules) into the image rootfs,
# register it in the image's pacman db, and apply the driver config.
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/install-driver.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Verify that built kernel modules (HID, etc.) exist in the overlay before
# copying them to the image.  Called explicitly before install_payload() to
# catch build failures early.
verify_built_modules() {
  [[ $BUILD_HW_SUPPORT -eq 1 ]] || return 0

  log "Verifying built kernel modules in overlay"

  # Check HID modules exist in overlay upper layer
  local hid_dj="$UPPER/usr/lib/modules/$KVER/updates/logitech/hid-logitech-dj.ko"
  local hid_hidpp="$UPPER/usr/lib/modules/$KVER/updates/logitech/hid-logitech-hidpp.ko"

  if [[ ! -f "$hid_dj" ]]; then
    die "hid-logitech-dj.ko not found in overlay at $hid_dj — build_hid() may have failed"
  fi
  if [[ ! -f "$hid_hidpp" ]]; then
    die "hid-logitech-hidpp.ko not found in overlay at $hid_hidpp — build_hid() may have failed"
  fi

  log "HID modules verified in overlay: hid-logitech-dj.ko, hid-logitech-hidpp.ko"

  # Verify libratbag is installed in overlay
  if ! in_chroot "pacman -Q libratbag" >/dev/null 2>&1; then
    die "libratbag not found in overlay chroot — install_hw_libs() may have failed"
  fi

  log "libratbag verified in overlay"
}

# rsync the payload into the real image rootfs and register its packages.
install_payload() {
  log "Copying driver payload into the image rootfs"
  rsync -a --files-from="$FILELIST.rel" "$MERGED/" "$MNT/"

  # Copy kernel modules (including HID) from overlay to image
  log "Copying kernel modules from overlay to image"
  rsync -a "$UPPER/usr/lib/modules/$KVER/updates" "$MNT/usr/lib/modules/$KVER/"

  # Verify HID modules landed in the image
  if [[ $BUILD_HW_SUPPORT -eq 1 ]]; then
    local img_hid_dj="$MNT/usr/lib/modules/$KVER/updates/logitech/hid-logitech-dj.ko"
    local img_hid_hidpp="$MNT/usr/lib/modules/$KVER/updates/logitech/hid-logitech-hidpp.ko"

    if [[ ! -f "$img_hid_dj" ]]; then
      die "hid-logitech-dj.ko not copied to image — rsync may have failed"
    fi
    if [[ ! -f "$img_hid_hidpp" ]]; then
      die "hid-logitech-hidpp.ko not copied to image — rsync may have failed"
    fi
    log "HID modules verified in image: hid-logitech-dj.ko, hid-logitech-hidpp.ko"
  fi

  log "Registering payload packages in the image's pacman db"
  for pkg in "${NEW_PKGS[@]}"; do
    # Remove old version entries first — otherwise upgrading nvidia-utils 580→590
    # leaves both /local/nvidia-utils-580.../ and /local/nvidia-utils-590.../
    rm -rf "$MNT/usr/lib/holo/pacmandb/local/$pkg"-[0-9]*
    for ENTRY in "$UPPER/usr/lib/holo/pacmandb/local/$pkg"-[0-9]*; do
      [[ -d "$ENTRY" ]] && rsync -a "$ENTRY" "$MNT/usr/lib/holo/pacmandb/local/" && break
    done
  done

  log "Running depmod + ldconfig in the image"
  chroot "$MNT" depmod "$KVER"
  chroot "$MNT" ldconfig

  log "Writing modprobe config (blacklist nouveau, enable nvidia KMS)"
  cat > "$MNT/etc/modprobe.d/99-nvidia-patch.conf" <<'EOF'
# Added by steamos-nvidia-installer
blacklist nouveau
options nouveau modeset=0
options nvidia-drm modeset=1 fbdev=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
EOF

  log "Restoring module autoloading in initramfs"
  # modprobe -R needs /proc to resolve aliases — mount it now, unmount after.
  log "  Mounting proc/sys/dev in $MNT"
  mkdir -p "$MNT/proc" "$MNT/sys" "$MNT/dev"
  mount -t proc proc "$MNT/proc" || { warn "Failed to mount proc"; return 1; }
  mount --rbind /sys "$MNT/sys" || { warn "Failed to mount sys"; return 1; }
  mount --make-rslave "$MNT/sys"
  mount --rbind /dev "$MNT/dev" || { warn "Failed to mount dev"; return 1; }
  mount --make-rslave "$MNT/dev"
  log "  proc/sys/dev mounted"

  # Discover which modules the image's kernel would load for this machine's
  # hardware — depmod already ran above so the image's alias db is current.
  log "  Discovering modules via modprobe -R"
  local auto_modules
  auto_modules=$(for dev in /sys/bus/pci/devices/*/modalias; do
    chroot "$MNT" modprobe -R "$(cat "$dev")" 2>/dev/null || true
  done | sort -u | { grep -Ev '^nouveau$' || true; } | tr '\n' ' ')
  log "  Discovered: ${auto_modules:-<none>}"

  # Detect initramfs system: dracut (SteamOS) or mkinitcpio (Arch).
  if chroot "$MNT" command -v dracut >/dev/null 2>&1; then
    log "  Using dracut for initramfs"
    # Add discovered modules + nvidia stack to dracut config.
    local dracut_modules="nvidia nvidia_modeset nvidia_drm nvidia_uvm $auto_modules"
    dracut_modules=$(echo "$dracut_modules" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')
    cat > "$MNT/etc/dracut.conf.d/99-steamos-nvidia.conf" <<EOF
# Added by steamos-nvidia-installer
add_drivers+=" $dracut_modules "
EOF
    log "  dracut modules: $dracut_modules"
    chroot "$MNT" dracut -f || warn "dracut failed (non-fatal — will regenerate on first boot)"
  elif chroot "$MNT" command -v mkinitcpio >/dev/null 2>&1; then
    log "  Using mkinitcpio for initramfs"
    if [[ -n "$auto_modules" ]]; then
      local existing_modules merged_modules
      existing_modules=$(sed -n 's/^MODULES=(\(.*\))/\1/p' "$MNT/etc/mkinitcpio.conf")
      log "  Existing modules: ${existing_modules:-<none>}"
      merged_modules=$(echo "$existing_modules $auto_modules" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')
      sed -i "s|^MODULES=(.*)|MODULES=($merged_modules)|" "$MNT/etc/mkinitcpio.conf"
      log "MODULES=($merged_modules)"
    fi
    chroot "$MNT" mkinitcpio -P || warn "mkinitcpio failed (non-fatal — will regenerate on first boot)"
  else
    warn "No initramfs tool found (neither dracut nor mkinitcpio)"
  fi

  log "  Unmounting proc/sys/dev"
  umount -R "$MNT/proc" "$MNT/sys" "$MNT/dev" 2>/dev/null || true

  log "Enabling nvidia suspend/resume services"
  chroot "$MNT" systemctl enable nvidia-suspend nvidia-resume nvidia-hibernate 2>/dev/null \
    || warn "Could not enable nvidia power services (non-fatal)"

  # Bundle scan-hardware.sh for manual use.
  log "Installing hardware scan tool"
  cp "$SCRIPT_DIR/lib/scan-hardware.sh" "$MNT/usr/local/bin/scan-hardware"
  chmod +x "$MNT/usr/local/bin/scan-hardware"

  # Bundle post-install.sh for manual configuration.
  log "Installing post-install configuration script"
  cp "$SCRIPT_DIR/lib/post-install.sh" "$MNT/usr/local/bin/steamos-nvidia-post-install"
  chmod +x "$MNT/usr/local/bin/steamos-nvidia-post-install"

  # Desktop shortcut — user can re-run anytime to reconfigure.
  mkdir -p "$MNT/home/deck/Desktop"
  cat > "$MNT/home/deck/Desktop/NVIDIA Setup.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=NVIDIA Setup
Comment=Configure NVIDIA driver, thunderbolt, hardware scan, desktop mode
Exec=/usr/local/bin/steamos-nvidia-post-install
Icon=preferences-system
Terminal=true
Type=Application
StartupNotify=true
EOF
  chmod +x "$MNT/home/deck/Desktop/NVIDIA Setup.desktop"
  chown -R 1000:1000 "$MNT/home/deck/Desktop"
}
