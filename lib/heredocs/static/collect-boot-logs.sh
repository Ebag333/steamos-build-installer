#!/bin/bash
# collect-boot-logs — gather initramfs + early boot diagnostics onto the USB.
# Runs as a oneshot systemd service after local-fs.target.

set -euo pipefail

LOG_DIR=""
USB_MOUNT=""

_find_usb() {
  # Already mounted (e.g. home partition automounted)?
  for mp in /run/media/*/home /media/*/home /home; do
    if [[ -f "$mp/.steamos-build/usb-marker" ]]; then
      LOG_DIR="$mp/deck/logs/boot"
      return 0
    fi
  done

  # Scan block devices for the home partition by label.
  for dev in $(lsblk -rno NAME,PARTLABEL 2>/dev/null | awk '$2=="home"{print "/dev/"$1}'); do
    [[ -b "$dev" ]] || continue
    USB_MOUNT="$(mktemp -d /tmp/usb-home.XXXXXX)"
    if mount -o rw "$dev" "$USB_MOUNT" 2>/dev/null; then
      if [[ -f "$USB_MOUNT/.steamos-build/usb-marker" ]]; then
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

if ! _find_usb; then
  echo "collect-boot-logs: USB not found, skipping." >&2
  exit 0
fi

_collect_boot_logs_cleanup() {
  [[ -n "${OUT:-}" && -d "$OUT" ]] && rm -rf "$OUT"
  if [[ -n "${USB_MOUNT:-}" ]]; then
    umount "$USB_MOUNT" 2>/dev/null || true
    rmdir "$USB_MOUNT" 2>/dev/null || true
  fi
}
trap _collect_boot_logs_cleanup EXIT

mkdir -p "$LOG_DIR"

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$LOG_DIR/boot-${TS}"
mkdir -p "$OUT"

_cp_if() { [[ -f "$1" ]] && cp "$1" "$OUT/" 2>/dev/null || true; }
save() { [[ -f "$1" ]] && cp "$1" "$OUT/$2" 2>/dev/null || true; }

# --- initramfs logs (dracut: rd.log=all writes here) ---
_cp_if /run/initramfs/init.log

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
tar czf "$TARBALL" -C "$LOG_DIR" "boot-${TS}"
rm -rf "$OUT"

# Keep only the 20 most recent log archives.
ls -1t "$LOG_DIR"/boot-logs-*.tar.gz 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null || true

# Unmount if we mounted the USB ourselves.
if [[ -n "$USB_MOUNT" ]]; then
  umount "$USB_MOUNT" 2>/dev/null || true
  rmdir "$USB_MOUNT" 2>/dev/null || true
fi

echo "collect-boot-logs: wrote $TARBALL" >&2
