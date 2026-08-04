#!/bin/bash
#
# flash-image.sh — flash a SteamOS installer image to a USB stick.
#
# Scans for removable USB devices, presents a picker, confirms, and runs dd.
# Requires: zenity, lsblk, dd, sudo
#
# Usage:
#   ./flash-image.sh [image.img]
#
# If no image is given, auto-discovers .img files in common build locations.

set -euo pipefail

# ---- helpers ----
die()  { zenity --error --no-wrap --text "$1" 2>/dev/null || echo "ERROR: $1" >&2; exit 1; }

# ---- find the image ----
IMG="${1:-}"
if [[ -z "$IMG" ]]; then
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  search_dirs=("$script_dir" "$script_dir/.nvidia-usb-work" "/dev/shm/nvidia-build" "/home/deck/Downloads/.nvidia-usb-work")
  imgs=()
  for d in "${search_dirs[@]}"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r f; do
      imgs+=("$f")
    done < <(find "$d" -maxdepth 1 -name '*nvidia*usbinstall*.img' -type f 2>/dev/null)
  done
  mapfile -t imgs < <(printf '%s\n' "${imgs[@]}" | sort -u)
  case ${#imgs[@]} in
    0) die "No *nvidia*usbinstall*.img found. Pass the image path as an argument." ;;
    1) IMG="${imgs[0]}" ;;
    *)
      IMG="$(zenity --list --title="Select Image" --text="Multiple images found:" \
        --column="Image" --width=700 --height=300 "${imgs[@]}")" || exit 0
      [[ -n "$IMG" ]] || die "No image selected."
      ;;
  esac
fi
[[ -f "$IMG" ]] || die "Image not found: $IMG"
IMG_SIZE="$(du -h "$IMG" | cut -f1)"

# ---- scan for target devices ----
DEVICE_LIST=$(lsblk -dno NAME,SIZE,MODEL,TRAN,RM,TYPE --json 2>/dev/null | python3 -c "
import json, sys, re
d = json.load(sys.stdin)
for dev in d.get('blockdevices', []):
    name = dev.get('name', '')
    size_str = str(dev.get('size', '0'))
    model = (dev.get('model', '') or '').strip()
    tran = dev.get('tran', '') or ''
    rm = dev.get('rm', False)
    dtype = dev.get('type', '')
    if dtype != 'disk':
        continue
    if any(name.startswith(p) for p in ('loop', 'zram', 'sr', 'nbd', 'ram')):
        continue
    # Parse size string (e.g. '7.6G', '61.5G', '0B')
    m = re.match(r'([\d.]+)([KMGTP]?)', size_str)
    if m:
        val = float(m.group(1))
        unit = m.group(2)
        mult = {'': 1, 'K': 1024, 'M': 1048576, 'G': 1073741824, 'T': 1099511627776}
        size_bytes = int(val * mult.get(unit, 1))
    else:
        size_bytes = 0
    if size_bytes == 0:
        continue
    if size_bytes >= 1073741824:
        s = '%.1f GB' % (size_bytes / 1073741824)
    elif size_bytes >= 1048576:
        s = '%.0f MB' % (size_bytes / 1048576)
    else:
        s = '%d bytes' % size_bytes
    tag = '[removable]' if rm else ''
    print('/dev/%s\t%s\t%s\t%s\t%s' % (name, s, tran, model, tag))
" 2>/dev/null)

[[ -n "$DEVICE_LIST" ]] || die "No target USB devices found.\n\nPlug in a USB stick and try again."

# ---- build zenity list ----
ROWS=()
while IFS=$'\t' read -r dev size tran model tag; do
  type_label="Internal"
  [[ "$tag" == "[removable]" ]] && type_label="Removable"
  ROWS+=(FALSE "$dev" "$size" "$model" "$tran" "$type_label")
done <<< "$DEVICE_LIST"

TARGET="$(zenity --list --radiolist \
  --title="Flash SteamOS Image" \
  --text="Select the target USB device.\n\nImage: $(basename "$IMG") ($IMG_SIZE)\n\n<b>ALL DATA ON THE SELECTED DEVICE WILL BE DESTROYED.</b>" \
  --column="" --column="Device" --column="Size" --column="Model" --column="Bus" --column="Type" \
  --width=750 --height=400 \
  --print-column=2 \
  "${ROWS[@]}")" || exit 0

[[ -n "$TARGET" && -b "$TARGET" ]] || die "No device selected."
TARGET_DEV="$(echo "$TARGET" | tr -d ' ')"

# ---- check if target is the system disk ----
SRC_PART="$(findmnt -no SOURCE / 2>/dev/null || true)"
SRC_DISK=""
[[ -n "$SRC_PART" ]] && SRC_DISK="$(lsblk -no PKNAME "$SRC_PART" 2>/dev/null | head -1 || true)"
if [[ -n "$SRC_DISK" && "$TARGET_DEV" == "/dev/$SRC_DISK" ]]; then
  zenity --warning --title="Warning: System Disk" \
    --text="<b>$TARGET_DEV appears to be the disk you are running from.</b>\n\nIf this is your recovery USB, the OS is loaded into RAM so flashing is safe - but if something goes wrong, you will need to recreate the recovery USB from another machine.\n\nIf this is your internal drive, <b>DO NOT proceed</b> unless you know exactly what you are doing." \
    --width=500 2>/dev/null || exit 0
fi

# ---- confirm ----
TARGET_SIZE="$(lsblk -dnbo SIZE "$TARGET_DEV" 2>/dev/null | head -1)"
if [[ -n "$TARGET_SIZE" && "$TARGET_SIZE" -gt 0 ]]; then
  TARGET_HR="$(numfmt --to=iec "$TARGET_SIZE" 2>/dev/null || echo "$TARGET_SIZE bytes")"
else
  TARGET_HR="unknown size"
fi

CONFIRM="$(zenity --question \
  --title="Confirm Flash" \
  --text="<b>About to flash:</b>\n\n  $(basename "$IMG") ($IMG_SIZE)\n\n<b>To:</b>\n\n  $TARGET_DEV ($TARGET_HR)\n\n<b>This PERMANENTLY DESTROYS all data on $TARGET_DEV.</b>\n\nThis cannot be undone." \
  --ok-label="Flash" --cancel-label="Cancel" \
  --width=500 2>&1)" || exit 0

# ---- flash with progress ----
BS="4M"
if command -v pv >/dev/null 2>&1; then
  zenity --info --title="Flashing" --text="Flashing $(basename "$IMG") to $TARGET_DEV...\n\nThis will take a few minutes.\nDo NOT remove the USB stick." --width=400 &
  ZENITY_PID=$!
  sudo bash -c "pv \"$IMG\" | dd of=\"$TARGET_DEV\" bs=$BS conv=fsync oflag=sync 2>&1" || true
  kill $ZENITY_PID 2>/dev/null || true
else
  sudo dd if="$IMG" of="$TARGET_DEV" bs=$BS status=progress conv=fsync oflag=sync 2>&1 \
    | zenity --progress --title="Flashing" --text="Flashing $(basename "$IMG") to $TARGET_DEV...\n\nDo NOT remove the USB stick." \
      --pulsate --auto-close --auto-kill --width=400 --ok-label="" --cancel-label="Cancel" 2>/dev/null || true
fi

# ---- sync and done ----
# sync may fail if we just overwrote the disk we're running from (the
# filesystem is gone). dd's conv=fsync already flushed, so this is cosmetic.
sync 2>/dev/null || true
zenity --info --title="Flash Complete" \
  --text="<b>Flashing complete!</b>\n\n$(basename "$IMG") -> $TARGET_DEV\n\n<b>Next steps:</b>\n1. Remove the USB stick\n2. Insert into target machine\n3. Boot from USB (UEFI, Secure Boot off)\n4. Double-click 'Install SteamOS (NVIDIA) to Hard Drive'\n5. Pick your disk and install" \
  --width=500 2>/dev/null || true
