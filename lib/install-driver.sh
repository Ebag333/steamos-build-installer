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

  log "Enabling nvidia suspend/resume services"
  chroot "$MNT" systemctl enable nvidia-suspend nvidia-resume nvidia-hibernate 2>/dev/null \
    || warn "Could not enable nvidia power services (non-fatal)"
}