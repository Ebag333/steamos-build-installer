#!/bin/bash
#
# steamos-nvidia-installer — lib/finalize.sh
# Stage 7: sanity-check the patched image, flush writes, restore the btrfs RO
# property, tear everything down, and print the summary.
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/finalize.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

finalize() {
  log "Sanity checks"
  compgen -G "$MNT/usr/lib/modules/$KVER/updates/dkms/nvidia.ko*" >/dev/null || die "nvidia.ko missing from image"

  # HID module checks (only if --hid was used).
  if [[ $BUILD_HID -eq 1 ]]; then
    compgen -G "$MNT/usr/lib/modules/$KVER/updates/logitech/hid-logitech-dj.ko*" >/dev/null \
      || die "hid-logitech-dj.ko missing from image"
    compgen -G "$MNT/usr/lib/modules/$KVER/updates/logitech/hid-logitech-hidpp.ko*" >/dev/null \
      || die "hid-logitech-hidpp.ko missing from image"
    chroot "$MNT" modinfo -F alias "/usr/lib/modules/$KVER/updates/logitech/hid-logitech-dj.ko" \
      | grep -qi 'v0000046Dp0000C547' \
      || die "image hid-logitech-dj module lacks the 046d:c547 alias"
    compgen -G "$PACDB/libratbag-[0-9]*" >/dev/null \
      || die "libratbag missing from image package database"
  fi

  grep -q 'blacklist nouveau' "$MNT/etc/modprobe.d/99-nvidia-patch.conf" || die "modprobe conf is empty/missing"
  if [[ $UPDATE_MODE == selfheal ]]; then
    grep -q 'self-healing' "$MNT/usr/bin/steamos-update" || die "update wrapper missing"
    [[ -f "$MNT/usr/bin/steamos-update.orig" ]] || die "original steamos-update not preserved"
    grep -q 'repatch' "$MNT/usr/lib/steamos-nvidia/repatch.sh" || die "repatch tool missing"
    grep -q "^DRIVER_VERSION=\"$DRIVER_VERSION\"" "$MNT/usr/lib/steamos-nvidia/driver.conf" || die "driver.conf missing/wrong"
    # Verify HID source bundle for self-heal.
    if [[ $BUILD_HID -eq 1 ]]; then
      for f in hid-logitech-dj.c hid-logitech-hidpp.c hid-ids.h usbhid/usbhid.h Makefile; do
        [[ -f "$MNT/usr/lib/steamos-nvidia/hid/$f" ]] \
          || die "self-heal HID source missing: $f"
      done
    fi
    [[ -L "$MNT/etc/systemd/system/atomupd.service" ]] && die "atomupd must NOT be masked in selfheal mode"
  fi
  compgen -G "$MNT/usr/lib/firmware/nvidia/*/gsp_*.bin" >/dev/null || warn "GSP firmware not found — nvidia-open needs it"
  [[ -f "$MNT/usr/share/vulkan/icd.d/nvidia_icd.json" ]] || warn "Vulkan ICD json missing"
  AVAIL_AFTER="$(df -m --output=avail "$MNT" | tail -1 | tr -d ' ')"
  log "Rootfs free space after install: ${AVAIL_AFTER} MB"

  # Flush all pending writes BEFORE flipping the subvolume read-only —
  # flipping with delalloc data still queued can silently produce 0-byte files.
  log "Syncing filesystems"
  btrfs filesystem sync "$MNT"
  sync -f "$MNT"; sync -f "$HOMEMNT"; sync -f "$EFIMNT"

  log "Restoring btrfs read-only property"
  btrfs property set "$MNT" ro true

  log "Unmounting"
  cleanup
  trap - EXIT

  log "DONE — $OUT"
  cat <<EOF

  Driver:  nvidia-open (DKMS) $NVIDIA_VER for kernel $KVER
           (latest Arch at build time, pinned — Valve's mirror only has 575.x)
$( case $UPDATE_MODE in
     selfheal) echo "  Updates: SELF-HEALING — updating from within Steam works; the SAME
           pinned driver is rebuilt for each new OS version automatically
           (adds 10-20 min per update; failed rebuilds cancel the update,
           system stays working). For a NEWER driver later: rerun this
           script and reinstall from the fresh USB image." ;;
     hold)     echo "  Updates: OS updates HELD (atomupd + OOBE migration masked, CLIs stubbed)." ;;
     stock)    echo "  Updates: STOCK behaviour — an OS update will REMOVE the NVIDIA driver!" ;;
   esac )
$( [[ $ADD_INSTALLER -eq 1 ]] && echo "  Install: boot the USB → double-click \"Install SteamOS (NVIDIA) to
           Hard Drive\" → pick disk → machine powers off → remove USB, boot." )

  Flash:   sudo dd if="$OUT" of=/dev/sdX bs=4M status=progress conv=fsync
  Needs:   UEFI + Secure Boot off; RTX 20xx or newer (nvidia-open = Turing+).
  Cache:   $WORKDIR (speeds up reruns; safe to delete)
EOF
}