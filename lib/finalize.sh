#!/bin/bash
#
# steamos-build-installer — lib/finalize.sh
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
  local nvidia_ver lib32_ver
  nvidia_ver="$(
    pacman -Q --dbpath "$(resolve_pacman_dbpath "$MNT")" nvidia-utils 2>/dev/null \
      | awk '{print $2}' || true
  )"
  lib32_ver="$(
    pacman -Q --dbpath "$(resolve_pacman_dbpath "$MNT")" lib32-nvidia-utils 2>/dev/null \
      | awk '{print $2}' || true
  )"

  # Only verify nvidia packages if they were installed
  if [[ -n "$nvidia_ver" ]]; then
    log "  nvidia-utils:       $nvidia_ver"
    log "  lib32-nvidia-utils: $lib32_ver"

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

  else
    log "  Skipping nvidia verification (nvidia not installed)"
  fi

  # HID module checks — only if logitech-hid was built and installed
  if [[ -d "$MNT/usr/lib/modules/$KVER/updates/logitech" ]]; then
    log "  Checking HID modules at: $MNT/usr/lib/modules/$KVER/updates/logitech/"
    compgen -G "$MNT/usr/lib/modules/$KVER/updates/logitech/hid-logitech-dj.ko*" >/dev/null \
      || die "hid-logitech-dj.ko missing from image"
    compgen -G "$MNT/usr/lib/modules/$KVER/updates/logitech/hid-logitech-hidpp.ko*" >/dev/null \
      || die "hid-logitech-hidpp.ko missing from image"
    chroot "$MNT" modinfo -k "$KVER" -F alias hid-logitech-dj \
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
  else
    log "  Skipping HID module verification (logitech-hid not installed)"
  fi

  if [[ $UPDATE_MODE == selfheal ]]; then
    grep -q 'self-healing' "$MNT/usr/bin/steamos-update" || die "update wrapper missing"
    [[ -f "$MNT/usr/bin/steamos-update.orig" ]] || die "original steamos-update not preserved"
    grep -q 'repatch' "/home/.steamos-build/build_cache/lib/repatch.sh" || die "repatch tool missing"
    [[ -f "/home/.steamos-build/build_cache/lib/overlay.sh" ]] || die "overlay helper missing"
    [[ -f "$HOMEMNT/.steamos-build/build.conf" ]] || die "build.conf missing"
    # Verify HID source bundle for self-heal (only if logitech-hid was installed)
    if [[ -d "$MNT/usr/lib/modules/$KVER/updates/logitech" ]]; then
      for f in hid-logitech-dj.c hid-logitech-hidpp.c hid-ids.h usbhid/usbhid.h Makefile; do
        [[ -f "/home/.steamos-build/bundles/hid/$f" ]] \
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
  local AVAIL_AFTER
  AVAIL_AFTER="$(df -m --output=avail "$MNT" | tail -1 | tr -d ' ')"
  log "Rootfs free space after install: ${AVAIL_AFTER} MB"

  # Disk usage diagnostics — distinguishes original SteamOS from our additions.
  log "Disk usage breakdown:"
  log "  /usr:        $(du -shx "$MNT/usr" 2>/dev/null | cut -f1 || true)"
  log "  /usr/lib:    $(du -shx "$MNT/usr/lib" 2>/dev/null | cut -f1 || true)"
  log "  /usr/lib/firmware: $(du -shx "$MNT/usr/lib/firmware" 2>/dev/null | cut -f1 || true)"
  log "  /usr/lib/modules: $(du -shx "$MNT/usr/lib/modules" 2>/dev/null | cut -f1 || true)"
  log "  /usr/share:  $(du -shx "$MNT/usr/share" 2>/dev/null | cut -f1 || true)"

  # Per-package apparent size — files that landed in the image rootfs.
  # NEW_PKGS is from the old overlay copy-back model; initialize if unset.
  if [[ -z "${NEW_PKGS+x}" ]]; then
    NEW_PKGS=()
  fi
  if [[ ${#NEW_PKGS[@]} -gt 0 ]]; then
    log "  Per-package additions (apparent, in image rootfs):"
    local pkg total_payload_kb=0
    for pkg in "${NEW_PKGS[@]}"; do
      local pkg_usage
      _compute_pkg_usage() {
        pacman -Qlq --dbpath "$(resolve_pacman_dbpath "$MNT")" "$1" 2>/dev/null \
          | while IFS="" read -r f; do
            [[ -f "$MNT$f" || -L "$MNT$f" ]] && printf '%s\0' "$MNT$f"
          done \
          | xargs -0 du -c --apparent-size --no-dereference 2>/dev/null \
          | tail -1 | cut -f1
      }
      pkg_usage="$(_compute_pkg_usage "$pkg")" || pkg_usage=""
      unset -f _compute_pkg_usage
      pkg_usage="${pkg_usage:-0}"
      log "    $pkg: ${pkg_usage} KiB"
      total_payload_kb=$((total_payload_kb + pkg_usage))
    done
    log "  Total payload additions: $((total_payload_kb / 1024)) MB apparent"
  fi

  # Top-level /usr breakdown for quick triage.
  log "  /usr top-level:"
  du -xhd1 "$MNT/usr" 2>/dev/null | sort -h | tail -10 | while IFS="" read -r line; do
    log "    $line"
  done || true

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

  # ── Custom script ──────────────────────────────────────────────────────
  run_custom_script "$MNT"

  # ── Pacman repository config ───────────────────────────────────────────
  # When Pacman repo is main, point all repos at the -main variants
  if [[ "${PACMAN_REPO:-valve}" == "main" ]]; then
    log "Switching pacman repos to main branch"
    sed -Ei \
      -e 's/^\[jupiter-[^]]+\][[:space:]]*$/[jupiter-main]/' \
      -e 's/^\[holo-[^]]+\][[:space:]]*$/[holo-main]/' \
      -e 's/^\[core-[^]]+\][[:space:]]*$/[core-main]/' \
      -e 's/^\[extra-[^]]+\][[:space:]]*$/[extra-main]/' \
      -e 's/^\[multilib-[^]]+\][[:space:]]*$/[multilib-main]/' \
      "$MNT/etc/pacman.conf" \
      || die "Failed to rewrite pacman.conf repos to main branch"
  fi

  # Flush all pending writes BEFORE flipping the subvolume read-only —
  # flipping with delalloc data still queued can silently produce 0-byte files.
  log "Syncing filesystems"
  btrfs filesystem sync "$MNT" || die "btrfs filesystem sync failed for $MNT"
  sync -f "$MNT" || die "sync -f $MNT failed"
  [[ -n "${HOMEMNT:-}" ]] && { sync -f "$HOMEMNT" || die "sync -f $HOMEMNT failed"; }
  [[ -n "${EFIMNT:-}" ]] && { sync -f "$EFIMNT" || die "sync -f $EFIMNT failed"; }

  # Restore btrfs rootfs to read-only to match Valve's source image.
  # The build process clears this property for modifications; restore it now
  # that all writes (including user custom script) are complete.
  restore_rootfs_readonly "$MNT" || die "Failed to restore rootfs to read-only — image is compromised"

  # Publish: rename .building to final output BEFORE tearing down mounts.
  # When WORKDIR is in RAM (/dev/shm), OUT lives inside WORKDIR, so
  # cleanup() would delete the image before we can move it otherwise.
  if [[ -n "${OUT_FINAL:-}" && "$OUT" != "$OUT_FINAL" ]]; then
    mv -- "$OUT" "$OUT_FINAL" \
      || die "Failed to publish completed image: mv $OUT -> $OUT_FINAL"
    mv "${OUT}.src-fingerprint" "${OUT_FINAL}.src-fingerprint" 2>/dev/null || true
    OUT="$OUT_FINAL"
  fi

  [[ -s "$OUT" ]] \
    || die "Published image is missing or empty: $OUT"

  # ── Final image verification ───────────────────────────────────────────
  # Log image details and assert expected size if configured.
  log "Final image details:"
  stat -c '  %n
  size:     %s bytes
  modified: %y' "$OUT" | while IFS="" read -r line; do log "$line"; done

  if [[ -n "${EXPECTED_IMAGE_SIZE:-}" ]]; then
    local actual_size
    actual_size="$(stat -c '%s' "$OUT")"
    if [[ "$actual_size" != "$EXPECTED_IMAGE_SIZE" ]]; then
      die "Image size mismatch: expected $EXPECTED_IMAGE_SIZE bytes, got $actual_size bytes"
    fi
    log "  size assertion passed: $EXPECTED_IMAGE_SIZE bytes"
  fi

  # Unmount/detach everything.  This must succeed before we declare victory
  # so that a cleanup failure never coexists with a DONE message.
  log "Unmounting"
  cleanup || die "cleanup (unmount/detach) failed — image may be inconsistent"
  _cleanup_done=1
  trap - EXIT

  # Mark the build as complete — setup_copy_image and flash_image_is_complete
  # check this before reusing a cached image.
  # Created AFTER cleanup succeeds so a failed teardown never leaves a
  # marker that makes the image look acceptably complete.
  touch "${OUT}.build-complete" || die "Failed to create build-complete marker: ${OUT}.build-complete"

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

    # Clean up overlay backing files.  If loop devices are still attached
    # (e.g. jbd2 held the superblock past the cleanup timeout), attempt to
    # detach them first.  If detach fails, do NOT delete the backing file —
    # that would leave the loop in a "(deleted)" state with no way to cleanly
    # release later.  Warn the user that a reboot may be required.
    local _overlay_loops
    _overlay_loops="$(loops_for_file "$WORKDIR/overlay-work.img")"
    if [[ -n "$_overlay_loops" ]]; then
      warn "Overlay loop(s) still attached after cleanup: $_overlay_loops"
      warn "  This is typically caused by the kernel's jbd2 journal thread"
      warn "  holding an ext4 superblock reference after unmount."
      warn "  Attempting detach..."
      while IFS="" read -r _loop; do
        [[ -n "$_loop" ]] || continue
        local _backing
        _backing="$(losetup -l -O BACK-FILE "$_loop" 2>/dev/null | tail -1 | tr -d ' ')"
        if losetup -d "$_loop" 2>/dev/null; then
          log "  Detached $_loop (${_backing:-unknown})"
        else
          warn "  Could not detach $_loop (${_backing:-unknown})"
        fi
      done <<<"$_overlay_loops"

      # Re-check after detach attempts.
      _overlay_loops="$(loops_for_file "$WORKDIR/overlay-work.img")"
      if [[ -n "$_overlay_loops" ]]; then
        warn "WARNING: Overlay loop(s) still attached after detach attempts: $_overlay_loops"
        warn "  Backing file will NOT be deleted to avoid orphaned loop state."
        warn "  A reboot is required to fully release these resources."
      else
        log "  All overlay loops detached"
        rm -f "$WORKDIR"/overlay-work.img
      fi
    else
      rm -f "$WORKDIR"/overlay-work.img
    fi
    rm -f "$WORKDIR"/.steamos-build-overlay-cache-key

    # Safe removal helper: skip directories that are still mountpoints.
    # If cleanup() partially failed, a directory may still be a live mount;
    # rm -rf on a mounted directory traverses into it and can destroy host
    # filesystem entries (e.g. /dev/snd audio devices through an overlay).
    _safe_rmdir() {
      local dir="$1"
      if [[ ! -e "$dir" ]]; then
        return 0
      fi
      if mountpoint -q "$dir" 2>/dev/null; then
        warn "$dir is still mounted — skipping removal"
        return 0
      fi
      rm -rf "$dir"
    }

    if mountpoint -q "$WORKDIR/overlay-mnt" 2>/dev/null; then
      warn "overlay-mnt is still mounted — attempting unmount"
      if umount "$WORKDIR/overlay-mnt" 2>/dev/null; then
        rm -rf "$WORKDIR"/overlay-mnt
      else
        warn "WARNING: Could not unmount overlay-mnt"
        warn "  A reboot is required to release this mount."
      fi
    else
      rm -rf "$WORKDIR"/overlay-mnt
    fi
    _safe_rmdir "$WORKDIR/merged"
    _safe_rmdir "$WORKDIR/upper"
    _safe_rmdir "$WORKDIR/ovlwork"
    _safe_rmdir "${WORKDIR:?}/mnt"
    _safe_rmdir "$WORKDIR/efi"
    _safe_rmdir "${WORKDIR:?}/home"
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

  # Use the already-validated $KVER (discovery from the image would fail
  # here because $MNT has been unmounted during cleanup).
  local final_kver="$KVER"

  local driver_text="" update_text="" install_text=""

  # Driver line — show what was actually installed
  if nvidia_is_selected; then
    driver_text="  Driver:  nvidia-open (DKMS) for kernel $final_kver"
  else
    driver_text="  Kernel:  $final_kver"
  fi

  # Update mode text — only relevant when custom drivers are installed
  if nvidia_is_selected; then
    case "$UPDATE_MODE" in
      selfheal)
        update_text="  Updates: SELF-HEALING — updating from within Steam works; the
             driver is rebuilt for each new OS version automatically
             (adds 10-20 min per update; failed rebuilds cancel the update,
             system stays working). For a NEWER driver later: rerun this
             script and reinstall from the fresh USB image."
        ;;
      hold)
        update_text="  Updates: OS updates HELD (atomupd + OOBE migration masked, CLIs stubbed)."
        ;;
      stock)
        update_text="  Updates: STOCK behaviour — an OS update will REMOVE the NVIDIA driver!"
        ;;
    esac
  fi

  if ((ADD_INSTALLER == 1)); then
    install_text='  Install: boot the USB → double-click "Install SteamOS (NVIDIA) to
             Hard Drive" → pick disk → machine powers off → remove USB, boot.'
  fi

  cat <<EOF

$driver_text
$update_text
$install_text

  Flash:   sudo dd if="$OUT" of=/dev/sdX bs=4M status=progress conv=fsync
EOF

  # Only show nvidia requirements when nvidia is installed
  if nvidia_is_selected; then
    cat <<EOF
  Needs:   UEFI + Secure Boot off; RTX 20xx or newer (nvidia-open = Turing+).
EOF
  fi
}
