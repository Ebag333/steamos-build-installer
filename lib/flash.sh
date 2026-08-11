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
" 2>/dev/null
}

# Check if a target device is the system disk.  Returns 0 if it is (danger).
flash_is_system_disk() {
  local target_dev="$1"
  local src_part src_disk
  src_part="$(findmnt -no SOURCE / 2>/dev/null || true)"
  [[ -n "$src_part" ]] && src_disk="$(lsblk -no PKNAME "$src_part" 2>/dev/null | head -1 || true)"
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

  if command -v pv >/dev/null 2>&1; then
    sudo bash -c "pv \"$img\" | dd of=\"$target\" bs=$bs conv=fsync oflag=sync 2>&1"
  else
    sudo dd if="$img" of="$target" bs=$bs status=progress conv=fsync oflag=sync 2>&1
  fi

  sync 2>/dev/null || true
}