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

# rsync the payload into the real image rootfs and register its packages.
install_payload() {
  log "Copying driver payload into the image rootfs"
  rsync -a --files-from="$FILELIST.rel" "$MERGED/" "$MNT/"
  rsync -a "$UPPER/usr/lib/modules/$KVER/updates" "$MNT/usr/lib/modules/$KVER/"

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