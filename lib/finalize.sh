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

  # Verify modprobe will actually select our installed modules.
  for mod in nvidia; do
    local path
    path="$(chroot "$MNT" modinfo -k "$KVER" -n "$mod" 2>/dev/null)" \
      || die "modinfo cannot resolve $mod for $KVER"
    case "$path" in
      /usr/lib/modules/"$KVER"/updates/*|/lib/modules/"$KVER"/updates/*) ;;
      *) die "$mod resolves to unexpected module: $path" ;;
    esac
    local vermagic
    vermagic="$(chroot "$MNT" modinfo -k "$KVER" -F vermagic "$mod" 2>/dev/null | head -1)" \
      || die "modinfo cannot read vermagic for $mod"
    [[ "$vermagic" == "$KVER "* ]] \
      || die "$mod vermagic '$vermagic' does not match $KVER"
  done

  # HID module checks (only if --hw-support was used).
  if [[ $BUILD_HW_SUPPORT -eq 1 ]]; then
    compgen -G "$MNT/usr/lib/modules/$KVER/updates/logitech/hid-logitech-dj.ko*" >/dev/null \
      || die "hid-logitech-dj.ko missing from image"
    compgen -G "$MNT/usr/lib/modules/$KVER/updates/logitech/hid-logitech-hidpp.ko*" >/dev/null \
      || die "hid-logitech-hidpp.ko missing from image"
    chroot "$MNT" modinfo -F alias "/usr/lib/modules/$KVER/updates/logitech/hid-logitech-dj.ko" \
      | grep -qi 'v0000046Dp0000C547' \
      || die "image hid-logitech-dj module lacks the 046d:c547 alias"
    compgen -G "$PACDB/libratbag-[0-9]*" >/dev/null \
      || die "libratbag missing from image package database"

    # Verify HID modules resolve to our /updates replacement, not stock.
    for mod in hid-logitech-dj hid-logitech-hidpp; do
      local path
      path="$(chroot "$MNT" modinfo -k "$KVER" -n "$mod" 2>/dev/null)" \
        || die "modinfo cannot resolve $mod for $KVER"
      case "$path" in
        /usr/lib/modules/"$KVER"/updates/logitech/*|/lib/modules/"$KVER"/updates/logitech/*) ;;
        *) die "$mod resolves to $path — stock driver winning over our replacement" ;;
      esac
      local vermagic
      vermagic="$(chroot "$MNT" modinfo -k "$KVER" -F vermagic "$mod" 2>/dev/null | head -1)" \
        || die "modinfo cannot read vermagic for $mod"
      [[ "$vermagic" == "$KVER "* ]] \
        || die "$mod vermagic '$vermagic' does not match $KVER"
    done
  fi

  grep -q 'blacklist nouveau' "$MNT/etc/modprobe.d/99-nvidia-patch.conf" || die "modprobe conf is empty/missing"
  if [[ $UPDATE_MODE == selfheal ]]; then
    grep -q 'self-healing' "$MNT/usr/bin/steamos-update" || die "update wrapper missing"
    [[ -f "$MNT/usr/bin/steamos-update.orig" ]] || die "original steamos-update not preserved"
    grep -q 'repatch' "$MNT/usr/lib/steamos-nvidia/repatch.sh" || die "repatch tool missing"
    grep -q "^DRIVER_VERSION=\"$DRIVER_VERSION\"" "$MNT/usr/lib/steamos-nvidia/driver.conf" || die "driver.conf missing/wrong"
    # Verify HID source bundle for self-heal.
    if [[ $BUILD_HW_SUPPORT -eq 1 ]]; then
      for f in hid-logitech-dj.c hid-logitech-hidpp.c hid-ids.h usbhid/usbhid.h Makefile; do
        [[ -f "$MNT/usr/lib/steamos-nvidia/hid/$f" ]] \
          || die "self-heal HID source missing: $f"
      done
    fi
    # Check that atomupd isn't masked — a symlink to /dev/null specifically
    # means masked; a plain symlink doesn't.
    local atomupd="$MNT/etc/systemd/system/atomupd.service"
    if [[ -L "$atomupd" ]] && [[ "$(readlink "$atomupd")" == "/dev/null" ]]; then
      die "atomupd must NOT be masked in selfheal mode"
    fi
  fi
  compgen -G "$MNT/usr/lib/firmware/nvidia/*/gsp_*.bin" >/dev/null \
    || die "GSP firmware not found — nvidia-open requires it"
  [[ -f "$MNT/usr/share/vulkan/icd.d/nvidia_icd.json" ]] \
    || die "Vulkan ICD json missing — Steam games will not find the GPU"
  AVAIL_AFTER="$(df -m --output=avail "$MNT" | tail -1 | tr -d ' ')"
  log "Rootfs free space after install: ${AVAIL_AFTER} MB"

  # Final writability check — confirms the rootfs is still usable after all
  # modifications.  The RDONLY rebuild in prepare_writable_rootfs() made it
  # writable, but verify nothing broke that.
  touch "$MNT/.final-rw-test" || die "Rootfs became read-only during build"
  rm -f "$MNT/.final-rw-test"

  # Flush all pending writes BEFORE flipping the subvolume read-only —
  # flipping with delalloc data still queued can silently produce 0-byte files.
  log "Syncing filesystems"
  btrfs filesystem sync "$MNT"
  sync -f "$MNT"; sync -f "$HOMEMNT"; sync -f "$EFIMNT"

  # Mark the build as complete — setup_copy_image checks this before
  # reusing a cached decompressed image.
  touch "${OUT}.build-complete"

  # Rename .building to final output — the wrapper uses a temp name so a
  # failed build doesn't destroy a previous successful image.
  if [[ -n "${OUT_FINAL:-}" && "$OUT" != "$OUT_FINAL" ]]; then
    mv "$OUT" "$OUT_FINAL"
    mv "${OUT}.src-fingerprint" "${OUT_FINAL}.src-fingerprint" 2>/dev/null || true
    mv "${OUT}.build-complete" "${OUT_FINAL}.build-complete" 2>/dev/null || true
    OUT="$OUT_FINAL"
  fi

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
