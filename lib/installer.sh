#!/bin/bash
#
# steamos-nvidia-installer — lib/installer.sh
# Stage 6: append the nvidia kernel cmdline, then (optionally) install the
# one-click "Install SteamOS (NVIDIA)" desktop installer built around Valve's
# patched repair_device.sh.
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/installer.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# rd.driver.blacklist keeps the initramfs from loading its bundled nouveau,
# so no initramfs regeneration is needed. /etc/default/grub matters too:
# the installer's update-grub regenerates the target's grub.cfg from it.
patch_kernel_cmdline() {
  CMDLINE_ADD='rd.driver.blacklist=nouveau modprobe.blacklist=nouveau nvidia-drm.modeset=1 nvidia-drm.fbdev=1'
  log "Appending to kernel cmdline: $CMDLINE_ADD"
  sed -i -E "s#(steamenv_boot[[:space:]]+linux[[:space:]]+/boot/vmlinuz[^\n]*)#\1 $CMDLINE_ADD#" \
    "$EFIMNT/EFI/steamos/grub.cfg"
  grep -q 'rd.driver.blacklist=nouveau' "$EFIMNT/EFI/steamos/grub.cfg" \
    || die "grub.cfg edit failed — cmdline pattern not found"
  if [[ -f "$MNT/etc/default/grub" ]]; then
    sed -i -E "s#^(GRUB_CMDLINE_LINUX_DEFAULT=\")#\1$CMDLINE_ADD #" "$MNT/etc/default/grub"
  fi
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
    # skip NVMe sanitize for non-NVMe targets (it error-traps on SATA/virtio)
    # shellcheck disable=SC2016
    sed -i '/^all)$/,/^  ;;$/ s|^  sanitize_all$|  if [[ "$DISK" == /dev/nvme* ]]; then sanitize_all; else ewarn "Non-NVMe target: skipping NVMe sanitize"; fi|' \
      "$TOOLS/repair_device.sh"
    grep -q 'skipping NVMe sanitize' "$TOOLS/repair_device.sh" || die "sanitize patch failed"

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
      cat > "$_resize_tmp" <<'RESIZE'

  # --- expand rootfs partitions to fill their (possibly larger) partitions ---
  if [[ -n "${STEAMOS_ROOTFS_SIZE:-}" ]]; then
    for _root_part_num in $FS_ROOT_A $FS_ROOT_B; do
      _root_part="$(diskpart $_root_part_num)"
      estat "Expanding btrfs on $_root_part to fill partition"
      _tmpmnt="$(mktemp -d /tmp/resize-btrfs.XXXXXX)"
      mount -o compress-force=zstd:3 "$_root_part" "$_tmpmnt"
      if [[ "$(btrfs property get "$_tmpmnt" ro)" == "ro=true" ]]; then
        btrfs property set "$_tmpmnt" ro false
      fi
      btrfs filesystem resize max "$_tmpmnt"
      umount "$_tmpmnt"
      rmdir "$_tmpmnt"
    done
  fi
RESIZE
      awk -v blk="$_resize_tmp" '
        /imageroot "\$rootdevice".*FS_ROOT_B/ {
          print; while ((getline line < blk) > 0) print line; close(blk); next
        }
        { print }
      ' "$TOOLS/repair_device.sh" > "$TOOLS/repair_device.sh.tmp" \
        && mv "$TOOLS/repair_device.sh.tmp" "$TOOLS/repair_device.sh"
      rm -f "$_resize_tmp"
      grep -q 'Expanding btrfs on' "$TOOLS/repair_device.sh" || die "btrfs resize injection failed"
    fi

    log "Installing disk-picker wrapper + desktop icons"
    cat > "$TOOLS/install_to_hd.sh" <<'WRAPPER'
#!/bin/bash
# One-click SteamOS (NVIDIA-patched) installer/upgrader. Picks an internal
# disk, then runs Valve's repair_device.sh which clones the running USB
# system onto it.
#   $1 = all    → full install: wipes the disk (default)
#   $1 = system → upgrade: reimages the OS partitions, KEEPS games & data
set -eu

MODE="${1:-all}"
case "$MODE" in
  all)
    TITLE="Install SteamOS (NVIDIA) to Hard Drive"
    PICK_TEXT="Select the disk to install SteamOS onto.\n\nEVERYTHING ON THE SELECTED DISK WILL BE ERASED."
    CONFIRM_LABEL="ERASE AND INSTALL"
    CONFIRM_TEXT_TPL="About to install SteamOS (NVIDIA-patched) onto:\n\n    %s\n\nThis PERMANENTLY DESTROYS everything on that disk.\nThe install takes several minutes. The machine powers off when done:\nremove the USB stick, then boot from %s."
    ;;
  system)
    TITLE="Upgrade SteamOS (NVIDIA) — keeps games & data"
    PICK_TEXT="Select the disk with the existing SteamOS installation to upgrade.\n\nThe OS partitions are reinstalled from this USB; the home partition\n(games, saves, Steam login) is NOT touched."
    CONFIRM_LABEL="UPGRADE"
    CONFIRM_TEXT_TPL="About to upgrade the SteamOS installation on:\n\n    %s\n\nGames and user data on that disk are preserved.\nOS customisations outside /home will be lost.\nThe machine powers off when done: remove the USB stick and boot."
    ;;
  *) echo "Usage: $0 [all|system]" >&2; exit 1 ;;
esac

err_exit() { zenity --error --no-wrap --text "$1" 2>/dev/null || echo "ERROR: $1" >&2; exit 1; }

# Disk we're running from (the USB) — never offer it as a target
SRC_PART="$(findmnt -no SOURCE /)"
SRC_DISK="$(lsblk -no PKNAME "$SRC_PART" 2>/dev/null | head -1)"

mapfile -t CANDIDATES < <(lsblk -dn -o NAME,SIZE,MODEL,TRAN,TYPE | \
  awk -v src="$SRC_DISK" '$NF=="disk" && $1!=src && $1 !~ /^(loop|zram|sr|nbd|ram)/ {NF--; print}')

[[ ${#CANDIDATES[@]} -gt 0 ]] || err_exit "No target disk found.\nThis machine appears to have no internal drive (other than this USB)."

ROWS=()
for c in "${CANDIDATES[@]}"; do
  name="${c%% *}"; rest="${c#* }"
  ROWS+=(FALSE "/dev/$name" "$rest")
done

TARGET=$(zenity --list --radiolist --title "$TITLE" \
  --text "$PICK_TEXT" \
  --column "" --column "Disk" --column "Size / Model / Bus" \
  --width 640 --height 340 "${ROWS[@]}") || exit 0
[[ -n "$TARGET" && -b "$TARGET" ]] || err_exit "No disk selected."

# Upgrade mode only makes sense on a disk that already has the SteamOS layout
if [[ "$MODE" == system ]]; then
  if ! lsblk -no PARTLABEL "$TARGET" 2>/dev/null | grep -qx "rootfs-A"; then
    err_exit "No existing SteamOS installation found on $TARGET.\nUse \"Install SteamOS (NVIDIA) to Hard Drive\" for a fresh install."
  fi
fi

# shellcheck disable=SC2059  # template contains the %s placeholders
CONFIRM_TEXT="$(printf "$CONFIRM_TEXT_TPL" "$TARGET" "$TARGET")"
zenity --question --no-wrap --title "Final confirmation" --ok-label "$CONFIRM_LABEL" --cancel-label "Cancel" \
  --text "$CONFIRM_TEXT" || exit 0

# POWEROFF=1: end with a shutdown prompt so the user can pull the USB
exec sudo env STEAMOS_TARGET_DISK="$TARGET" POWEROFF=1 \
  "$(dirname "$(readlink -f "$0")")/repair_device.sh" "$MODE"
WRAPPER
    chmod 755 "$TOOLS/install_to_hd.sh"

    # Bake the chosen rootfs size into the wrapper (the heredoc is literal,
    # so we inject it after the fact).
    if [[ -n "$ROOTFS_SIZE" ]]; then
      sed -i "2a STEAMOS_ROOTFS_SIZE=${ROOTFS_SIZE}" "$TOOLS/install_to_hd.sh"
      sed -i 's|exec sudo env STEAMOS_TARGET_DISK|exec sudo env STEAMOS_ROOTFS_SIZE="$STEAMOS_ROOTFS_SIZE" STEAMOS_TARGET_DISK|' \
        "$TOOLS/install_to_hd.sh"
      grep -q 'STEAMOS_ROOTFS_SIZE' "$TOOLS/install_to_hd.sh" || die "ROOTFS_SIZE injection into install_to_hd.sh failed"
    fi

    cat > "$DESKTOP/Install SteamOS NVIDIA.desktop" <<'ICON'
[Desktop Entry]
Name=Install SteamOS (NVIDIA) to Hard Drive
GenericName=Install SteamOS (NVIDIA) to Hard Drive
Comment=Erase an internal disk and install this NVIDIA-patched SteamOS onto it
Exec=/home/deck/tools/install_to_hd.sh all
Icon=drive-harddisk
Path=/home/deck
Terminal=true
Type=Application
StartupNotify=true
ICON
    chmod 755 "$DESKTOP/Install SteamOS NVIDIA.desktop"

    cat > "$DESKTOP/Upgrade SteamOS NVIDIA.desktop" <<'ICON'
[Desktop Entry]
Name=Upgrade SteamOS (NVIDIA) — keeps games & data
GenericName=Upgrade SteamOS (NVIDIA) — keeps games & data
Comment=Reinstall the OS partitions from this USB while preserving the home partition
Exec=/home/deck/tools/install_to_hd.sh system
Icon=system-software-update
Path=/home/deck
Terminal=true
Type=Application
StartupNotify=true
ICON
    chmod 755 "$DESKTOP/Upgrade SteamOS NVIDIA.desktop"

    chown -R 1000:1000 "$TOOLS/install_to_hd.sh" "$TOOLS/repair_device.sh" \
      "$TOOLS/repair_device.sh.stock" "$DESKTOP/Install SteamOS NVIDIA.desktop" \
      "$DESKTOP/Upgrade SteamOS NVIDIA.desktop"

    log "Adding NOPASSWD sudoers drop-in for deck (needed by the install icon)"
    echo 'deck ALL=(ALL) NOPASSWD: ALL' > "$MNT/etc/sudoers.d/zz-deck-nopasswd"
    chmod 440 "$MNT/etc/sudoers.d/zz-deck-nopasswd"
  fi
}