#!/bin/bash
#
# steamos-nvidia-installer — lib/flash.sh
# Flash a SteamOS image to a USB stick.  Provides device scanning, validation,
# and the actual dd flash.  UI-agnostic — callers handle dialogs/prompts.
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/flash.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Scan for removable USB devices.  Prints tab-separated lines:
#   /dev/sdX  SIZE  TRAN  MODEL  [removable]
flash_scan_devices() {
  lsblk -dno NAME,SIZE,MODEL,TRAN,RM,TYPE --json 2>/dev/null | python3 -c "
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
    m = re.match(r'([\d.]+)([KMGTP]?)', size_str)
    if m:
        val = float(m.group(1))
        unit = m.group(2)
        mult = {'': 1, 'K': 1000, 'M': 1000000, 'G': 1000000000, 'T': 1000000000000}
        size_bytes = int(val * mult.get(unit, 1))
    else:
        size_bytes = 0
    if size_bytes == 0:
        continue
    if size_bytes >= 1000000000:
        s = '%.1f GB' % (size_bytes / 1000000000)
    elif size_bytes >= 1000000:
        s = '%.0f MB' % (size_bytes / 1000000)
    else:
        s = '%d bytes' % size_bytes
    tag = '[removable]' if rm else ''
    print('/dev/%s\t%s\t%s\t%s\t%s' % (name, s, tran, model, tag))
" 2>/dev/null
}

# Check if a target device is the system disk.  Returns 0 if it is (danger).
# Conservative: walks block-device ancestry to handle btrfs subvolumes,
# LUKS, LVM, and device-mapper.
flash_is_system_disk() {
  local target_dev="$1"
  local src_part src_disk dev

  src_part="$(findmnt -no SOURCE / 2>/dev/null || true)"
  [[ -n "$src_part" ]] || return 1

  # Strip btrfs subvolume suffix: /dev/nvme0n1p3[/@] → /dev/nvme0n1p3
  src_part="${src_part%%\[*}"

  # Walk up the PKNAME ancestry until we reach a whole disk.
  dev="$src_part"
  while [[ -n "$dev" ]]; do
    src_disk="$(lsblk -no PKNAME "$dev" 2>/dev/null | head -1 || true)"
    if [[ -z "$src_disk" ]]; then
      # dev is itself a whole disk (no parent)
      src_disk="$(basename "$dev")"
      break
    fi
    dev="/dev/$src_disk"
  done

  [[ -n "$src_disk" && "$target_dev" == "/dev/$src_disk" ]]
}

# Get human-readable size of a block device.
flash_device_size() {
  local dev="$1"
  local bytes
  bytes="$(lsblk -dnbo SIZE "$dev" 2>/dev/null | head -1)"
  if [[ -n "$bytes" && "$bytes" -gt 0 ]]; then
    numfmt --to=iec "$bytes" 2>/dev/null || echo "$bytes bytes"
  else
    echo "unknown size"
  fi
}

# Flash an image to a device.  Requires root.
#   flash_write IMAGE TARGET_DEV
# Exits on failure.  Prints progress to stderr.
flash_write() {
  local img="$1" target="$2" bs="4M"

  [[ -f "$img" ]] || { echo "Image not found: $img" >&2; return 1; }
  [[ -b "$target" ]] || { echo "Not a block device: $target" >&2; return 1; }
  [[ $EUID -eq 0 ]] || { echo "Flash requires root (sudo)." >&2; return 1; }

  # Size check: refuse if image is larger than target device.
  local img_bytes target_bytes
  img_bytes="$(stat -c '%s' "$img")"
  target_bytes="$(blockdev --getsize64 "$target")"
  if (( img_bytes > target_bytes )); then
    echo "Image ($(( img_bytes / 1000000000 )) GB) is larger than target device ($(( target_bytes / 1000000000 )) GB)." >&2
    return 1
  fi

  # Unmount everything on the target device before writing.
  echo "Checking for mounts on $target..."
  local mounts
  mounts="$(lsblk -lnpo MOUNTPOINT "$target" 2>/dev/null | awk 'NF' | tac)"
  if [[ -n "$mounts" ]]; then
    echo "Found mounts:"
    echo "$mounts"
    while IFS= read -r mp; do
      [[ -n "$mp" ]] || continue
      echo "Unmounting $mp..."
      if ! umount "$mp" 2>/dev/null; then
        echo "  Regular unmount failed, trying lazy unmount..."
        umount -l "$mp" || { echo "  Failed to unmount $mp" >&2; return 1; }
      fi
      echo "  Unmounted $mp"
    done <<< "$mounts"
  else
    echo "No mounts found on $target"
  fi

  # Write the image.
  echo "Writing image to $target (bs=$bs)..."
  if command -v pv >/dev/null 2>&1; then
    (
      set -o pipefail
      pv "$img" | dd of="$target" bs="$bs" conv=fsync oflag=sync
    ) 2>&1
  else
    echo "  (pv not available, using dd with progress)"
    dd if="$img" of="$target" bs="$bs" status=progress conv=fsync oflag=sync 2>&1
  fi

  echo "Syncing..."
  sync 2>/dev/null || true
  echo "Flash complete!"
}
