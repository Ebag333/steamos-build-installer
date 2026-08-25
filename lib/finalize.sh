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

  # ── Package verification ───────────────────────────────────────────────
  # Query the image's pacman database for required packages.
  local nvidia_ver lib32_ver fw_ver
  nvidia_ver="$(
    pacman -Q --dbpath "$MNT/usr/lib/holo/pacmandb" nvidia-utils 2>/dev/null \
      | awk '{print $2}' || true
  )"
  lib32_ver="$(
    pacman -Q --dbpath "$MNT/usr/lib/holo/pacmandb" lib32-nvidia-utils 2>/dev/null \
      | awk '{print $2}' || true
  )"
  fw_ver="$(
    pacman -Q --dbpath "$MNT/usr/lib/holo/pacmandb" linux-firmware 2>/dev/null \
      | awk '{print $2}' || true
  )"

  [[ -n "$nvidia_ver" ]] \
    || die "nvidia-utils missing from final image pacman database"
  [[ -n "$lib32_ver" ]] \
    || die "lib32-nvidia-utils missing from final image pacman database"
  [[ -n "$fw_ver" ]] \
    || die "linux-firmware missing from final image pacman database"

  log "  nvidia-utils:       $nvidia_ver"
  log "  lib32-nvidia-utils: $lib32_ver"
  log "  linux-firmware:     $fw_ver"

  # ── Module verification ────────────────────────────────────────────────
  # Verify kmod can resolve each module for the target kernel, that it
  # lands in our /updates tree (not stock), and that the version matches
  # the pacman package.
  for mod in nvidia nvidia_modeset nvidia_drm nvidia_uvm; do
    local modfile
    modfile="$(chroot "$MNT" modinfo -k "$KVER" -n "$mod" 2>/dev/null || true)"
    [[ -n "$modfile" ]] \
      || die "$mod not resolvable for kernel $KVER"
    case "$modfile" in
      */updates/*) ;;
      *) die "$mod resolves to $modfile — stock module winning over our replacement" ;;
    esac
    local vermagic
    vermagic="$(chroot "$MNT" modinfo -k "$KVER" -F vermagic "$mod" 2>/dev/null | head -1)" \
      || die "modinfo cannot read vermagic for $mod"
    [[ "$vermagic" == "$KVER "* ]] \
      || die "$mod vermagic '$vermagic' does not match $KVER"
    log "  ✓ $mod: $modfile"
  done

  # Cross-check: module version must match the pacman package version.
  local module_ver
  module_ver="$(chroot "$MNT" modinfo -k "$KVER" -F version nvidia 2>/dev/null || true)"
  [[ -n "$module_ver" ]] \
    || die "Could not determine NVIDIA kernel module version"
  [[ "${nvidia_ver%-*}" == "$module_ver" ]] \
    || die "NVIDIA version mismatch: pacman=$nvidia_ver module=$module_ver"
  log "  NVIDIA kernel module: $module_ver for $KVER"

  # HID module checks (always applied)
  compgen -G "$MNT/usr/lib/modules/$KVER/updates/logitech/hid-logitech-dj.ko*" >/dev/null \
    || die "hid-logitech-dj.ko missing from image"
  compgen -G "$MNT/usr/lib/modules/$KVER/updates/logitech/hid-logitech-hidpp.ko*" >/dev/null \
    || die "hid-logitech-hidpp.ko missing from image"
  chroot "$MNT" modinfo -F alias "/usr/lib/modules/$KVER/updates/logitech/hid-logitech-dj.ko" \
    | grep -qi 'v0000046Dp0000C547' \
    || die "image hid-logitech-dj module lacks the 046d:c547 alias"

  # Verify HID modules resolve to our /updates replacement, not stock.
  for mod in hid-logitech-dj hid-logitech-hidpp; do
    local path
    path="$(chroot "$MNT" modinfo -k "$KVER" -n "$mod" 2>/dev/null)" \
      || die "modinfo cannot resolve $mod for $KVER"
    case "$path" in
      /usr/lib/modules/"$KVER"/updates/logitech/* | /lib/modules/"$KVER"/updates/logitech/*) ;;
      *) die "$mod resolves to $path — stock driver winning over our replacement" ;;
    esac
    local vermagic
    vermagic="$(chroot "$MNT" modinfo -k "$KVER" -F vermagic "$mod" 2>/dev/null | head -1)" \
      || die "modinfo cannot read vermagic for $mod"
    [[ "$vermagic" == "$KVER "* ]] \
      || die "$mod vermagic '$vermagic' does not match $KVER"
  done

  grep -q 'blacklist nouveau' "$MNT/etc/modprobe.d/99-nvidia-patch.conf" || die "modprobe conf is empty/missing"
  if [[ $UPDATE_MODE == selfheal ]]; then
    grep -q 'self-healing' "$MNT/usr/bin/steamos-update" || die "update wrapper missing"
    [[ -f "$MNT/usr/bin/steamos-update.orig" ]] || die "original steamos-update not preserved"
    grep -q 'repatch' "$MNT/usr/lib/steamos-nvidia/repatch.sh" || die "repatch tool missing"
    [[ -f "$MNT/usr/lib/steamos-nvidia/overlay.sh" ]] || die "overlay helper missing"
    [[ -f "$MNT/home/.steamos-nvidia/build.conf" ]] || die "build.conf missing"
    # Verify HID source bundle for self-heal (always applied)
    for f in hid-logitech-dj.c hid-logitech-hidpp.c hid-ids.h usbhid/usbhid.h Makefile; do
      [[ -f "$MNT/usr/lib/steamos-nvidia/hid/$f" ]] \
        || die "self-heal HID source missing: $f"
    done
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

  # Disk usage diagnostics — distinguishes original SteamOS from our additions.
  log "Disk usage breakdown:"
  log "  /usr:        $(du -shx "$MNT/usr" 2>/dev/null | cut -f1)"
  log "  /usr/lib:    $(du -shx "$MNT/usr/lib" 2>/dev/null | cut -f1)"
  log "  /usr/lib/firmware: $(du -shx "$MNT/usr/lib/firmware" 2>/dev/null | cut -f1)"
  log "  /usr/lib/modules: $(du -shx "$MNT/usr/lib/modules" 2>/dev/null | cut -f1)"
  log "  /usr/share:  $(du -shx "$MNT/usr/share" 2>/dev/null | cut -f1)"

  # Per-package apparent size — this is what WE added to the original SteamOS.
  # Directories excluded (du on /usr/ would recursively count everything).
  if [[ ${#NEW_PKGS[@]} -gt 0 ]]; then
    log "  Per-package additions (apparent, files only):"
    local pkg total_payload_kb=0
    for pkg in "${NEW_PKGS[@]}"; do
      local pkg_usage
      pkg_usage="$(pacman -Qlq --dbpath "$MNT/usr/lib/holo/pacmandb" "$pkg" 2>/dev/null \
        | while IFS= read -r f; do
          [[ -f "$MNT$f" || -L "$MNT$f" ]] && printf '%s\0' "$MNT$f"
        done \
        | xargs -0 du -c --apparent-size --no-dereference 2>/dev/null \
        | tail -1 | cut -f1)" || true
      pkg_usage="${pkg_usage:-0}"
      log "    $pkg: ${pkg_usage} KiB"
      total_payload_kb=$((total_payload_kb + pkg_usage))
    done
    log "  Total payload additions: $((total_payload_kb / 1024)) MB apparent"
  fi

  # Top-level /usr breakdown for quick triage.
  log "  /usr top-level:"
  du -xhd1 "$MNT/usr" 2>/dev/null | sort -h | tail -10 | while IFS= read -r line; do
    log "    $line"
  done

  # Convenience symlink so boot logs are easy to find from the command line.
  if [[ -d "$HOMEMNT/deck/logs/boot" ]]; then
    ln -sfn /home/deck/logs/boot "$MNT/boot-logs"
    log "Boot logs accessible at /boot-logs -> /home/deck/logs/boot"
  fi

  # Final writability check — confirms the rootfs is still usable after all
  # modifications.  The RDONLY rebuild in prepare_writable_rootfs() made it
  # writable, but verify nothing broke that.
  touch "$MNT/.final-rw-test" || die "Rootfs became read-only during build"
  rm -f "$MNT/.final-rw-test"

  # Flush all pending writes BEFORE flipping the subvolume read-only —
  # flipping with delalloc data still queued can silently produce 0-byte files.
  log "Syncing filesystems"
  btrfs filesystem sync "$MNT"
  sync -f "$MNT"
  sync -f "$HOMEMNT"
  sync -f "$EFIMNT"

  # Unmount/detach everything.  This must succeed before we publish the image
  # so that a cleanup failure never coexists with a .build-complete marker.
  log "Unmounting"
  cleanup
  trap - EXIT

  # Publish: rename .building to final output, then atomically mark complete.
  # The wrapper uses a temp name so a failed build doesn't destroy a previous
  # successful image.
  if [[ -n "${OUT_FINAL:-}" && "$OUT" != "$OUT_FINAL" ]]; then
    mv "$OUT" "$OUT_FINAL"
    mv "${OUT}.src-fingerprint" "${OUT_FINAL}.src-fingerprint" 2>/dev/null || true
    OUT="$OUT_FINAL"
  fi

  # Mark the build as complete — setup_copy_image and flash_image_is_complete
  # check this before reusing a cached image.  Written last so a failed
  # teardown never produces a false-positive marker.
  touch "${OUT}.build-complete"

  # Clean up temporary build artifacts from WORKDIR.
  # Keep the final image, package cache, and build manifest.
  # Remove everything else (overlay workspace, mount points, temp state).
  if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then
    log "Cleaning up temporary build artifacts"

    # Remove stale output images from WORKDIR if the real image is elsewhere.
    # This catches orphaned images from previous builds that used a different
    # OUTPUT_DIR or WORKDIR_LOCATION.
    local out_dir
    out_dir="$(dirname "$OUT_FINAL")"
    if [[ "$(realpath "$WORKDIR")" != "$(realpath "$out_dir")" ]]; then
      rm -f "$WORKDIR"/*-nvidia-usbinstall.img
      rm -f "$WORKDIR"/*-nvidia-usbinstall.img.build-complete
      rm -f "$WORKDIR"/*-nvidia-usbinstall.img.src-fingerprint
      rm -f "$WORKDIR"/*-nvidia-usbinstall.img.conf
    fi

    rm -f "$WORKDIR"/overlay-work.img
    rm -f "$WORKDIR"/.steamos-nvidia-overlay-cache-key
    rm -rf "$WORKDIR"/overlay-mnt
    rm -rf "$WORKDIR"/merged
    rm -rf "$WORKDIR"/upper
    rm -rf "$WORKDIR"/ovlwork
    rm -rf "$WORKDIR"/mnt
    rm -rf "$WORKDIR"/efi
    rm -rf "$WORKDIR"/home
    rm -f "$WORKDIR"/*.building
    rm -f "$WORKDIR"/*.building.src-fingerprint
    rm -f "$WORKDIR"/pkgs-before.txt
    rm -f "$WORKDIR"/pkgs-after.txt
    rm -f "$WORKDIR"/payload-files.txt
    rm -f "$WORKDIR"/payload-files.rel
    rm -f "$WORKDIR"/driver-files.txt
    rm -f "$WORKDIR"/driver-files.rel
    rm -f "$WORKDIR"/driver-after.txt
    rm -f "$WORKDIR"/build-only-exclusions.txt
    rm -f "$WORKDIR"/custom-payload-files.txt
    rm -f "$WORKDIR"/partitions-before-rootfs-grow.txt
    rm -rf "$WORKDIR"/hid-src
    rm -rf "$WORKDIR"/aotofu-src
    rm -rf "$WORKDIR"/aotofu-build
    rm -rf "$WORKDIR"/aotofu-base.txt
    rm -rf "$WORKDIR"/aotofu-runtime.txt
    rm -rf "$WORKDIR"/aotofu-build.txt
    rm -rf "$WORKDIR"/aotofu-rebuild
    rm -rf "$WORKDIR"/effective-etc-*
    rm -rf "$WORKDIR"/rootfs-*
    rm -rf "$WORKDIR"/tmp-*
  fi

  log "DONE — $OUT"
  cat <<EOF

  Driver:  nvidia-open (DKMS) for kernel $KVER
$(case $UPDATE_MODE in
    selfheal) echo "  Updates: SELF-HEALING — updating from within Steam works; the
           driver is rebuilt for each new OS version automatically
           (adds 10-20 min per update; failed rebuilds cancel the update,
           system stays working). For a NEWER driver later: rerun this
           script and reinstall from the fresh USB image." ;;
    hold) echo "  Updates: OS updates HELD (atomupd + OOBE migration masked, CLIs stubbed)." ;;
    stock) echo "  Updates: STOCK behaviour — an OS update will REMOVE the NVIDIA driver!" ;;
  esac)
$([[ $ADD_INSTALLER -eq 1 ]] && echo "  Install: boot the USB → double-click \"Install SteamOS (NVIDIA) to
           Hard Drive\" → pick disk → machine powers off → remove USB, boot.")

  Flash:   sudo dd if="$OUT" of=/dev/sdX bs=4M status=progress conv=fsync
  Needs:   UEFI + Secure Boot off; RTX 20xx or newer (nvidia-open = Turing+).
  Cache:   $WORKDIR (speeds up reruns; safe to delete)
EOF
}
