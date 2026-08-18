#!/bin/bash
#
# steamos-nvidia-installer — lib/installer.sh
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
  log "Injecting boot log collector"

  # Marker file so the collector script can find the USB at runtime.
  mkdir -p "$HOMEMNT/.steamos-nvidia"
  touch "$HOMEMNT/.steamos-nvidia/usb-marker"

  # Log output directory.
  mkdir -p "$HOMEMNT/deck/logs/boot"

  # The collector script — lives in the image rootfs.
  cat > "$MNT/usr/local/bin/collect-boot-logs" <<'SCRIPT'
#!/bin/bash
# collect-boot-logs — gather initramfs + early boot diagnostics onto the USB.
# Runs as a oneshot systemd service after local-fs.target.

set -euo pipefail

LOG_DIR=""
USB_MOUNT=""

find_usb() {
  # Already mounted (e.g. home partition automounted)?
  for mp in /run/media/*/home /media/*/home /home; do
    if [[ -f "$mp/.steamos-nvidia/usb-marker" ]]; then
      LOG_DIR="$mp/deck/logs/boot"
      return 0
    fi
  done

  # Scan block devices for the home partition by label.
  for dev in $(lsblk -rno NAME,PARTLABEL 2>/dev/null | awk '$2=="home"{print "/dev/"$1}'); do
    [[ -b "$dev" ]] || continue
    USB_MOUNT="$(mktemp -d /tmp/usb-home.XXXXXX)"
    if mount -o rw "$dev" "$USB_MOUNT" 2>/dev/null; then
      if [[ -f "$USB_MOUNT/.steamos-nvidia/usb-marker" ]]; then
        LOG_DIR="$USB_MOUNT/deck/logs/boot"
        return 0
      fi
      umount "$USB_MOUNT" 2>/dev/null
      rmdir "$USB_MOUNT" 2>/dev/null
      USB_MOUNT=""
    fi
  done

  return 1
}

if ! find_usb; then
  echo "collect-boot-logs: USB not found, skipping." >&2
  exit 0
fi

mkdir -p "$LOG_DIR"

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$LOG_DIR/boot-${TS}"
mkdir -p "$OUT"

cp_if() { [[ -f "$1" ]] && cp "$1" "$OUT/" 2>/dev/null || true; }
save() { [[ -f "$1" ]] && cp "$1" "$OUT/$2" 2>/dev/null || true; }

# --- initramfs logs (dracut: rd.log=all writes here) ---
cp_if /run/initramfs/init.log

# --- dmesg ---
dmesg > "$OUT/dmesg.txt" 2>/dev/null || true
dmesg --level=err,warn > "$OUT/dmesg-warnings.txt" 2>/dev/null || true

# --- systemd journal (full boot) ---
journalctl -b --no-pager > "$OUT/journal.txt" 2>/dev/null || true
journalctl -b -p err --no-pager > "$OUT/journal-errors.txt" 2>/dev/null || true

# --- hardware ---
lspci -vvnn > "$OUT/lspci.txt" 2>/dev/null || true
lspci -k > "$OUT/lspci-k.txt" 2>/dev/null || true
lsusb > "$OUT/lsusb.txt" 2>/dev/null || true
lsmod > "$OUT/lsmod.txt" 2>/dev/null || true
cat /proc/modules > "$OUT/modules.txt" 2>/dev/null || true

# --- block devices & mounts ---
lsblk -f > "$OUT/lsblk.txt" 2>/dev/null || true
findmnt --tree > "$OUT/findmnt.txt" 2>/dev/null || true
mount > "$OUT/mount.txt" 2>/dev/null || true

# --- kernel & boot config ---
uname -a > "$OUT/uname.txt" 2>/dev/null || true
cat /proc/cmdline > "$OUT/cmdline.txt" 2>/dev/null || true
save /etc/default/grub grub-default.txt
save /boot/grub/grub.cfg grub.cfg

# --- overlayfs info ---
cat /proc/mounts > "$OUT/proc-mounts.txt" 2>/dev/null || true

# --- nvidia specifics ---
modinfo nvidia > "$OUT/modinfo-nvidia.txt" 2>/dev/null || true
cat /proc/driver/nvidia/version > "$OUT/nvidia-version.txt" 2>/dev/null || true
nvidia-smi > "$OUT/nvidia-smi.txt" 2>/dev/null || true

# --- module parameters ---
find /sys/module/nvidia* -name '*' -type f 2>/dev/null | while read -r f; do
  echo "=== $f ==="; cat "$f" 2>/dev/null || true
done > "$OUT/nvidia-params.txt" 2>/dev/null || true

# --- udev info for nvidia ---
udevadm info --query=all --name=/dev/nvidia0 > "$OUT/udevadm-nvidia0.txt" 2>/dev/null || true

# --- systemd services ---
systemctl list-units --all > "$OUT/systemd-units.txt" 2>/dev/null || true
systemctl list-unit-files > "$OUT/systemd-unit-files.txt" 2>/dev/null || true

# --- package database (nvidia-related) ---
pacman -Q | grep -i nvidia > "$OUT/pacman-nvidia.txt" 2>/dev/null || true

# --- network diagnostics ---
ip -br link > "$OUT/ip-link.txt" 2>&1 || true
ip -br addr > "$OUT/ip-addr.txt" 2>&1 || true
ip route > "$OUT/ip-route.txt" 2>&1 || true
rfkill list > "$OUT/rfkill.txt" 2>&1 || true
nmcli device status > "$OUT/nmcli-devices.txt" 2>&1 || true
nmcli general status > "$OUT/nmcli-status.txt" 2>&1 || true
systemctl status NetworkManager iwd systemd-networkd \
    --no-pager > "$OUT/network-services.txt" 2>&1 || true
journalctl -b \
    -u NetworkManager \
    -u iwd \
    -u systemd-networkd \
    --no-pager > "$OUT/network-journal.txt" 2>&1 || true
dmesg | grep -Ei \
    'wifi|wlan|wireless|ether|network|firmware|iwl|igc|igb|r816|rtl|ath|mt76|brcm|failed|error' \
    > "$OUT/network-dmesg.txt" 2>&1 || true

# --- compress and clean up ---
TARBALL="$LOG_DIR/boot-logs-${TS}.tar.gz"
tar czf "$TARBALL" -C "$LOG_DIR" "boot-${TS}" 2>/dev/null
rm -rf "$OUT"

# Keep only the 20 most recent log archives.
ls -1t "$LOG_DIR"/boot-logs-*.tar.gz 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null || true

# Unmount if we mounted the USB ourselves.
if [[ -n "$USB_MOUNT" ]]; then
  umount "$USB_MOUNT" 2>/dev/null || true
  rmdir "$USB_MOUNT" 2>/dev/null || true
fi

echo "collect-boot-logs: wrote $TARBALL" >&2
SCRIPT
  chmod 755 "$MNT/usr/local/bin/collect-boot-logs"

  # Systemd service — runs after home partition is available.
  mkdir -p "$MNT/etc/systemd/system"
  cat > "$MNT/etc/systemd/system/collect-boot-logs.service" <<'SERVICE'
[Unit]
Description=Collect boot logs to USB
DefaultDependencies=no
After=local-fs.target
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/collect-boot-logs
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
SERVICE

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

# Disk we're running from (the USB) — never offer it as a target.
# Fail closed: if we can't determine the source disk, refuse to proceed
# rather than risk offering the USB as an install target.
SRC_PART="$(findmnt -no SOURCE /)"
SRC_DISK="$(lsblk -no PKNAME "$SRC_PART" 2>/dev/null | head -1)"
if [[ -z "$SRC_DISK" ]]; then
  err_exit "Cannot determine which disk contains the USB rootfs.\nRefusing to proceed — the USB might be offered as an install target."
fi

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
# nvidia-install-run is the restricted sudo helper — only repair_device.sh.
exec sudo env STEAMOS_TARGET_DISK="$TARGET" POWEROFF=1 \
  /usr/local/bin/nvidia-install-run \
  "$(dirname "$(readlink -f "$0")")/repair_device.sh" "$MODE"
WRAPPER
    chmod 755 "$TOOLS/install_to_hd.sh"

    # Bake the chosen rootfs size into the wrapper (the heredoc is literal,
    # so we inject it after the fact).
    if [[ -n "$ROOTFS_SIZE" ]]; then
      sed -i "2a STEAMOS_ROOTFS_SIZE=${ROOTFS_SIZE}" "$TOOLS/install_to_hd.sh"
      sed -i "s|exec sudo env STEAMOS_TARGET_DISK|exec sudo env STEAMOS_ROOTFS_SIZE=\"\$STEAMOS_ROOTFS_SIZE\" STEAMOS_TARGET_DISK|" \
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

    chmod +x "$TOOLS"/*.sh 2>/dev/null || true

    chown -R 1000:1000 "$TOOLS/install_to_hd.sh" "$TOOLS/repair_device.sh" \
      "$TOOLS/repair_device.sh.stock" "$DESKTOP/Install SteamOS NVIDIA.desktop" \
      "$DESKTOP/Upgrade SteamOS NVIDIA.desktop"

    # Privilege-escalation wrapper: only allows running repair_device.sh
    # (and nothing else) as root, with the required environment variables.
    log "Installing privilege-escalation helper"
    cat > "$MNT/usr/local/bin/nvidia-install-run" <<'HELPER'
#!/bin/bash
# Restricted sudo helper for the one-click installer.
# Only allows running repair_device.sh as root with the required env vars.
set -euo pipefail

SCRIPT="/home/deck/tools/repair_device.sh"

# Reject anything that isn't our installer script.
if [[ "${1:-}" != "$SCRIPT" ]]; then
  echo "nvidia-install-run: only $SCRIPT is permitted" >&2
  exit 1
fi

shift
exec "$SCRIPT" "$@"
HELPER
    chmod 755 "$MNT/usr/local/bin/nvidia-install-run"

    # NOPASSWD sudoers: only the wrapper, not blanket ALL.
    log "Adding NOPASSWD sudoers drop-in for deck (wrapper only)"
    echo 'deck ALL=(ALL) NOPASSWD: /usr/local/bin/nvidia-install-run' \
      > "$MNT/etc/sudoers.d/zz-deck-nopasswd"
    chmod 440 "$MNT/etc/sudoers.d/zz-deck-nopasswd"
  fi
}