#!/bin/bash
#
# steamos-build-installer — lib/installer.sh
# Stage 6: inject boot log collector and (optionally) install the one-click
# "Install SteamOS (NVIDIA)" desktop installer built around Valve's patched
# repair_device.sh.
#
# Kernel command line management is in lib/grub.sh.
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/installer.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Inject a boot log collector: systemd service + script that writes
# initramfs logs, dmesg, journal, etc. to the USB's home partition.
inject_log_collector() {
  [[ -n "${MNT:-}" && -d "$MNT" ]] || die "inject_log_collector: MNT is unset or not a directory"
  [[ -n "${HOMEMNT:-}" && -d "$HOMEMNT" ]] || die "inject_log_collector: HOMEMNT is unset or not a directory"
  log "Injecting boot log collector"

  # Ensure the persistent .steamos-build tree exists (logs + recovery).
  ensure_steamos_build_dirs "$HOMEMNT"

  # Marker file so the collector script can find the USB at runtime.
  touch "$HOMEMNT/.steamos-build/usb-marker"

  # Log output directory.
  mkdir -p "$HOMEMNT/deck/logs/boot"

  # The collector script — lives in the image rootfs.
  cat "$(_heredoc_dir)/static/collect-boot-logs.sh" >"$MNT/usr/local/bin/collect-boot-logs"
  chmod 755 "$MNT/usr/local/bin/collect-boot-logs"

  # Systemd service — runs after home partition is available.
  mkdir -p "$MNT/etc/systemd/system"
  cat "$(_heredoc_dir)/static/collect-boot-logs.service" >"$MNT/etc/systemd/system/collect-boot-logs.service"

  mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
  ln -sf ../collect-boot-logs.service \
    "$MNT/etc/systemd/system/multi-user.target.wants/collect-boot-logs.service"

  log "Boot log collector injected"
}

# One-click installer: patch Valve's repair_device.sh for generic hardware,
# add a zenity disk-picker wrapper + desktop icons, and NOPASSWD sudo for deck.
install_one_click_installer() {
  if [[ $ADD_INSTALLER -eq 1 ]]; then
    TOOLS="$HOMEMNT/deck/tools"
    DESKTOP="$HOMEMNT/deck/Desktop"
    [[ -f "$TOOLS/repair_device.sh" ]] \
      || die "No repair_device.sh in image home — is this the OOBE *repair* image?"

    log "Patching Valve's repair_device.sh for generic hardware"
    cp -a "$TOOLS/repair_device.sh" "$TOOLS/repair_device.sh.stock"
    # shellcheck disable=SC2016  # literal $ wanted in the patched script
    sed -i \
      -e 's|^DISK=/dev/nvme0n1$|DISK="${STEAMOS_TARGET_DISK:-/dev/nvme0n1}"|' \
      -e 's|^DISK_SUFFIX=p$|DISK_SUFFIX=""; [[ "$DISK" =~ [0-9]$ ]] \&\& DISK_SUFFIX="p"|' \
      "$TOOLS/repair_device.sh"
    grep -q 'STEAMOS_TARGET_DISK' "$TOOLS/repair_device.sh" || die "DISK patch failed"
    # make sanitize fault-tolerant: some NVMe drives (e.g. older WD Gen3)
    # don't support the command and hard-fail with "Access Denied"
    # shellcheck disable=SC2016
    sed -i '/^all)$/,/^  ;;$/ s#^  sanitize_all$#  sanitize_all || ewarn "NVMe sanitize failed or unsupported — continuing"#' \
      "$TOOLS/repair_device.sh"
    grep -q 'sanitize failed or unsupported' "$TOOLS/repair_device.sh" || die "sanitize patch failed"

    # --rootfs-size: make rootfs-A/B bigger than Valve's default 5120 MiB and
    # expand the btrfs filesystem to fill the larger partitions after imaging.
    if [[ -n "$ROOTFS_SIZE" ]]; then
      log "Patching root partition size: ${ROOTFS_SIZE} MiB (Valve default: 5120)"
      # shellcheck disable=SC2016  # literal $ wanted
      sed -i 's|^PART_SIZE_ROOT="5120".*|PART_SIZE_ROOT="${STEAMOS_ROOTFS_SIZE:-5120}"|' \
        "$TOOLS/repair_device.sh"
      grep -q 'STEAMOS_ROOTFS_SIZE' "$TOOLS/repair_device.sh" || die "PART_SIZE_ROOT patch failed"

      # After the dd clone, expand the btrfs filesystem to fill the (now larger)
      # partition.  The clone carries ro=true from the USB image, so clear it first.
      # Inject right after the second imageroot call (the one for rootfs-B).
      _resize_tmp="$(mktemp /tmp/nvidia-resize-block.XXXXXX)"
      cat "$(_heredoc_dir)/static/resize-btrfs.sh" >"$_resize_tmp"
      awk -v blk="$_resize_tmp" '
        /imageroot "\$rootdevice".*FS_ROOT_B/ {
          print; while ((getline line < blk) > 0) print line; close(blk); next
        }
        { print }
      ' "$TOOLS/repair_device.sh" >"$TOOLS/repair_device.sh.tmp" \
        && mv "$TOOLS/repair_device.sh.tmp" "$TOOLS/repair_device.sh"
      rm -f "$_resize_tmp"
      grep -q 'Expanding btrfs on' "$TOOLS/repair_device.sh" || die "btrfs resize injection failed"
    fi

    log "Installing disk-picker wrapper + desktop icons"
    cat "$(_heredoc_dir)/static/install-to-hd.sh" >"$TOOLS/install_to_hd.sh"
    chmod 755 "$TOOLS/install_to_hd.sh"

    # Bake the chosen rootfs size into the wrapper (the heredoc is literal,
    # so we inject it after the fact).
    if [[ -n "$ROOTFS_SIZE" ]]; then
      sed -i "2a STEAMOS_ROOTFS_SIZE=${ROOTFS_SIZE}" "$TOOLS/install_to_hd.sh"
      sed -i "s|exec sudo env STEAMOS_TARGET_DISK|exec sudo env STEAMOS_ROOTFS_SIZE=\"\$STEAMOS_ROOTFS_SIZE\" STEAMOS_TARGET_DISK|" \
        "$TOOLS/install_to_hd.sh"
      grep -q 'STEAMOS_ROOTFS_SIZE' "$TOOLS/install_to_hd.sh" || die "ROOTFS_SIZE injection into install_to_hd.sh failed"
    fi

    cat "$(dirname "${BASH_SOURCE[0]}")/heredocs/static/install-steamos-nvidia.desktop" >"$DESKTOP/Install SteamOS NVIDIA.desktop"
    chmod 755 "$DESKTOP/Install SteamOS NVIDIA.desktop"

    cat "$(dirname "${BASH_SOURCE[0]}")/heredocs/static/upgrade-steamos-nvidia.desktop" >"$DESKTOP/Upgrade SteamOS NVIDIA.desktop"
    chmod 755 "$DESKTOP/Upgrade SteamOS NVIDIA.desktop"

    chmod +x "$TOOLS"/*.sh 2>/dev/null || true

    chown -R 1000:1000 "$TOOLS/install_to_hd.sh" "$TOOLS/repair_device.sh" \
      "$TOOLS/repair_device.sh.stock" "$DESKTOP/Install SteamOS NVIDIA.desktop" \
      "$DESKTOP/Upgrade SteamOS NVIDIA.desktop"

    # Privilege-escalation wrapper: only allows running repair_device.sh
    # (and nothing else) as root, with the required environment variables.
    log "Installing privilege-escalation helper"
    cat "$(dirname "${BASH_SOURCE[0]}")/heredocs/static/nvidia-install-run.sh" \
      >"$MNT/usr/local/bin/nvidia-install-run"
    chmod 755 "$MNT/usr/local/bin/nvidia-install-run"

    # NOPASSWD sudoers: only the wrapper, not blanket ALL.
    log "Adding NOPASSWD sudoers drop-in for deck (wrapper only)"
    echo 'deck ALL=(ALL) NOPASSWD: /usr/local/bin/nvidia-install-run' \
      >"$MNT/etc/sudoers.d/zz-deck-nopasswd"
    chmod 440 "$MNT/etc/sudoers.d/zz-deck-nopasswd"
  fi
}
