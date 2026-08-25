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

# Collect and display pre-flight comparison between image and target device.
# Runs safety checks and returns non-zero if the flash should not proceed.
# Args: $1 = image path, $2 = target device
# Sets: IMG_BYTES, TARGET_BYTES, TARGET_SERIAL
flash_preflight() {
  local img="$1" target="$2"
  local checks_passed=0 checks_failed=0
  set +e # diagnostic function — don't die on individual command failures

  IMG_BYTES="$(stat -c '%s' "$img")"
  TARGET_BYTES="$(blockdev --getsize64 "$target")"

  local img_human target_human
  img_human="$(numfmt --to=iec "$IMG_BYTES" 2>/dev/null || echo "$IMG_BYTES bytes")"
  target_human="$(numfmt --to=iec "$TARGET_BYTES" 2>/dev/null || echo "$TARGET_BYTES bytes")"

  # ── Image checks ──────────────────────────────────────────────────────

  # Quiesce: sync before reading the image.
  sync 2>/dev/null || true

  # Loop attachment: check if the image is still attached to a loop device.
  # RO loop with no mounts → informational, not a failure.
  # RW loop with no mounts → try to detach, warn if fails.
  # Any mounted children → hard stop.
  local img_loops img_loop_status="none" img_loop_ok=1
  local img_loop_detail=""
  img_loops="$(losetup -j "$img" 2>/dev/null | cut -d: -f1)"
  if [[ -n "$img_loops" ]]; then
    local loop
    while IFS= read -r loop; do
      [[ -n "$loop" ]] || continue
      local loop_ro loop_mounts
      loop_ro="$(lsblk -ndo RO "$loop" 2>/dev/null || true)"
      loop_mounts="$(findmnt -rn -S "$loop" 2>/dev/null || true)"

      # Capture what's mounted on the loop device itself.
      if [[ -n "$loop_mounts" ]]; then
        img_loop_detail+="    $loop (RO=$loop_ro):"$'\n'
        while IFS= read -r line; do
          img_loop_detail+="      $line"$'\n'
        done <<<"$loop_mounts"
      fi

      # Check for mounted child partitions.
      local child_mounted=0 child
      for child in "$loop"*; do
        [[ -b "$child" ]] || continue
        local child_mnt
        child_mnt="$(findmnt -rn -S "$child" 2>/dev/null || true)"
        if [[ -n "$child_mnt" ]]; then
          child_mounted=1
          local child_ro
          child_ro="$(lsblk -ndo RO "$child" 2>/dev/null || true)"
          img_loop_detail+="    $child (RO=$child_ro):"$'\n'
          while IFS= read -r line; do
            img_loop_detail+="      $line"$'\n'
          done <<<"$child_mnt"
        fi
      done

      if [[ -n "$loop_mounts" || "$child_mounted" -eq 1 ]]; then
        # Mounted children — hard stop.
        img_loop_status="mounted"
        img_loop_ok=0
      elif [[ "$loop_ro" == "0" ]]; then
        # RW, no mounts — try to detach.
        if losetup -d "$loop" 2>/dev/null; then
          img_loop_status="detached"
        else
          img_loop_status="detach-failed"
          img_loop_ok=0
          img_loop_detail+="    $loop: detach failed"$'\n'
        fi
      else
        # RO, no mounts — informational only.
        img_loop_status="ro-ok"
      fi
    done <<<"$img_loops"
  fi

  # GPT validation.
  local img_gpt_ok=0 img_gpt_detail="" sgdisk_rc=0
  if command -v sgdisk >/dev/null 2>&1; then
    img_gpt_detail="$(sgdisk -v "$img" 2>&1)" || sgdisk_rc=$?
    # sgdisk -v returns 0 on success; the output text varies by version.
    if ((sgdisk_rc == 0)); then
      img_gpt_ok=1
    fi
  fi

  # Partition identities: expect exactly esp, efi-A, rootfs-A, var-A, home.
  local img_parts_found img_parts_ok=1
  local -a expected_parts=(esp efi-A rootfs-A var-A home)
  if command -v sgdisk >/dev/null 2>&1; then
    img_parts_found="$(sgdisk -p "$img" 2>/dev/null \
      | awk 'NR>3 && /^[[:space:]]*[0-9]/ {print $7}' \
      | sort | tr '\n' ', ' | sed 's/,$//')"
    local p
    for p in "${expected_parts[@]}"; do
      if [[ ",$img_parts_found," != *",$p,"* ]]; then
        img_parts_ok=0
      fi
    done
  fi

  # ── Target checks ─────────────────────────────────────────────────────

  local dev_model dev_tran dev_serial dev_rm
  dev_model="$(lsblk -dno MODEL "$target" 2>/dev/null | xargs)"
  # shellcheck disable=SC2034
  dev_tran="$(lsblk -dno TRAN "$target" 2>/dev/null | xargs)"
  dev_serial="$(lsblk -dno SERIAL "$target" 2>/dev/null | xargs)"
  dev_rm="$(lsblk -dno RM "$target" 2>/dev/null | xargs)"
  # shellcheck disable=SC2034
  TARGET_SERIAL="$dev_serial"

  # Target unmounted: check all child partitions.
  local target_mounts_ok=1
  local target_mounts
  target_mounts="$(findmnt -rn -S "$target" 2>/dev/null || true)"
  if [[ -n "$target_mounts" ]]; then
    target_mounts_ok=0
  fi
  # Also check child partitions.
  local child
  for child in "$target"*; do
    [[ -b "$child" ]] || continue
    if findmnt -rn -S "$child" >/dev/null 2>&1; then
      target_mounts_ok=0
    fi
  done

  # Target not used as swap/LVM/dm-crypt/RAID.
  local target_holders_ok=1
  local holders
  holders="$(lsblk -lnpo NAME,TYPE "$target" 2>/dev/null \
    | awk '$2 != "disk" && $2 != "part" {print $1}')"
  if [[ -n "$holders" ]]; then
    target_holders_ok=0
  fi
  # Check for swap.
  if swapon --show=NAME 2>/dev/null | grep -qF "$target"; then
    target_holders_ok=0
  fi
  # Check for dm-crypt/LVM.
  if command -v dmsetup >/dev/null 2>&1; then
    if dmsetup ls --target crypt 2>/dev/null | grep -qF "$target"; then
      target_holders_ok=0
    fi
  fi

  # Target not containing /, /boot, /efi, /home, or the build workspace.
  local target_system_ok=1
  if flash_is_system_disk "$target"; then
    target_system_ok=0
  fi
  # Check if build workspace is on the target.
  if [[ -n "${WORKDIR:-}" ]]; then
    local ws_dev
    ws_dev="$(df "$WORKDIR" 2>/dev/null | tail -1 | awk '{print $1}')" || true
    if [[ -n "$ws_dev" ]]; then
      local ws_disk
      ws_disk="$(lsblk -no PKNAME "$ws_dev" 2>/dev/null | head -1)" || true
      if [[ "/dev/$ws_disk" == "$target" ]]; then
        target_system_ok=0
      fi
    fi
  fi

  # ── Display ───────────────────────────────────────────────────────────

  echo "=== Flash Pre-Flight ==="
  echo ""
  echo "Image:"
  echo "  Path:        $img"
  echo "  Size:        $img_human ($IMG_BYTES bytes)"

  if ((img_gpt_ok)); then
    echo "  GPT:         ✓ valid"
    checks_passed=$((checks_passed + 1))
  else
    echo "  GPT:         ✗ INVALID"
    if [[ -n "$img_gpt_detail" ]]; then
      # Show only error/warning lines, not the full dump.
      echo "$img_gpt_detail" | grep -iE 'error|warn|caution|problem|invalid' | head -5 | while IFS= read -r line; do
        echo "    $line"
      done
    fi
    checks_failed=$((checks_failed + 1))
  fi

  if ((img_parts_ok)); then
    echo "  Partitions:  ✓ $img_parts_found"
    checks_passed=$((checks_passed + 1))
  else
    echo "  Partitions:  ✗ expected esp, efi-A, rootfs-A, var-A, home"
    echo "    Found:     $img_parts_found"
    checks_failed=$((checks_failed + 1))
  fi

  if ((img_loop_ok)); then
    case "$img_loop_status" in
      none) echo "  Loop users:  ✓ none" ;;
      ro-ok) echo "  Loop users:  ✓ RO only (no mounts)" ;;
      detached) echo "  Loop users:  ✓ detached stale loop" ;;
    esac
    checks_passed=$((checks_passed + 1))
  else
    case "$img_loop_status" in
      mounted) echo "  Loop users:  ✗ mounted children — unmount before flashing" ;;
      detach-failed) echo "  Loop users:  ✗ could not detach loop — reboot may be required" ;;
      *) echo "  Loop users:  ✗ $img_loops" ;;
    esac
    if [[ -n "$img_loop_detail" ]]; then
      printf '%s' "$img_loop_detail"
    fi
    checks_failed=$((checks_failed + 1))
  fi

  echo "  Quiescent:   ✓ synced"
  echo ""
  echo "Target:"
  echo "  Device:      $target"
  echo "  Model:       ${dev_model:-<unknown>}"
  echo "  Serial:      ${dev_serial:-<unknown>}"
  echo "  Size:        $target_human ($TARGET_BYTES bytes)"
  echo "  Removable:   ${dev_rm:-<unknown>}"

  if ((target_mounts_ok)); then
    echo "  Mounted:     ✓ no"
  else
    local mount_count
    mount_count="$(findmnt -rn -S "$target" 2>/dev/null | wc -l)"
    for child in "$target"*; do
      [[ -b "$child" ]] || continue
      mount_count=$((mount_count + $(findmnt -rn -S "$child" 2>/dev/null | wc -l)))
    done
    echo "  Mounted:     $mount_count partition(s) — will auto-unmount"
  fi

  if ((target_holders_ok)); then
    echo "  Swap:        ✓ no"
    echo "  Holders:     ✓ none"
    checks_passed=$((checks_passed + 1))
  else
    echo "  Holders:     ✗ target is in use (swap/LVM/dm-crypt/RAID)"
    checks_failed=$((checks_failed + 1))
  fi

  if ((target_system_ok)); then
    echo "  System disk: ✓ no"
    checks_passed=$((checks_passed + 1))
  else
    echo "  System disk: ✗ target contains /, /boot, /efi, /home, or build workspace"
    checks_failed=$((checks_failed + 1))
  fi

  # ── Capacity ──────────────────────────────────────────────────────────

  echo ""
  echo "Capacity:"
  echo "  Image:       $img_human"
  echo "  Target:      $target_human"

  if ((IMG_BYTES > TARGET_BYTES)); then
    echo "  Result:      ✗ IMAGE DOES NOT FIT"
    checks_failed=$((checks_failed + 1))
  else
    local headroom=$((TARGET_BYTES - IMG_BYTES))
    local headroom_human
    headroom_human="$(numfmt --to=iec "$headroom" 2>/dev/null || echo "$headroom bytes")"
    echo "  Headroom:    $headroom_human"
    checks_passed=$((checks_passed + 1))
  fi

  # ── Expected post-flash layout ────────────────────────────────────────

  if command -v sgdisk >/dev/null 2>&1 && ((img_gpt_ok)); then
    echo ""
    echo "Expected post-flash layout:"
    sgdisk -p "$img" 2>/dev/null | awk 'NR>3 && /^[[:space:]]*[0-9]/ {
      printf "  %-10s %s\n", $7, $6
    }'
    if ((TARGET_BYTES > IMG_BYTES)); then
      echo "  (unallocated: $(((TARGET_BYTES - IMG_BYTES) / 1048576)) MiB beyond image)"
    fi
  fi

  # ── Summary ───────────────────────────────────────────────────────────

  echo ""
  echo "Checks: $checks_passed passed, $checks_failed failed"

  if ((checks_failed > 0)); then
    echo ""
    echo "Flash aborted."
    return 1
  fi

  return 0
}

# Verify a flash by reading back exactly the image's byte count from the device
# and comparing the SHA256 against the source image.
# MUST be called BEFORE any post-write modifications (e.g. GPT relocation).
# Args: $1 = image path, $2 = target device, $3 = image bytes, $4 = precomputed image SHA256
flash_verify_raw() {
  local img="$1" target="$2" img_bytes="$3" img_hash="$4"

  echo ""
  echo "=== Flash Read-Back Verification ==="
  echo ""

  echo "  Image SHA256:  $img_hash"

  echo "Reading back $img_bytes bytes from $target..."
  local device_hash
  device_hash="$(
    dd if="$target" \
      bs=1M \
      count="$img_bytes" \
      iflag=count_bytes \
      status=none \
      | sha256sum \
      | awk '{print $1}'
  )" || {
    echo "  ✗ Failed to read back device for verification"
    return 1
  }
  echo "  Device SHA256: $device_hash"

  if [[ "$img_hash" != "$device_hash" ]]; then
    echo "  ✗ VERIFICATION FAILED — read-back does NOT match image"
    return 1
  fi

  echo "  ✓ Verification passed — read-back matches image"
}

# Flash an image to a device.  Requires root.
#   flash_write IMAGE TARGET_DEV
# Exits on failure.  Prints progress to stderr.
flash_write() {
  local img="$1" target="$2" bs="4M"

  [[ -f "$img" ]] || {
    echo "Image not found: $img" >&2
    return 1
  }
  [[ -b "$target" ]] || {
    echo "Not a block device: $target" >&2
    return 1
  }
  [[ $EUID -eq 0 ]] || {
    echo "Flash requires root (sudo)." >&2
    return 1
  }

  # Collect sizes (preflight already ran, but we need these for the write).
  local img_bytes target_bytes
  img_bytes="$(stat -c '%s' "$img")"
  target_bytes="$(blockdev --getsize64 "$target")"
  if ((img_bytes > target_bytes)); then
    echo "Image ($((img_bytes / 1000000000)) GB) is larger than target device ($((target_bytes / 1000000000)) GB)." >&2
    return 1
  fi

  # Unmount everything on the target device before writing.
  # No lazy unmounts — a lazy umount can leave the filesystem alive while
  # processes still hold it, and dd would write over a live filesystem.
  echo ""
  local mounts
  mounts="$(lsblk -lnpo MOUNTPOINT "$target" 2>/dev/null | awk 'NF')"
  local child_mounts=""
  for child in "$target"*; do
    [[ -b "$child" ]] || continue
    local cm
    cm="$(findmnt -no TARGET "$child" 2>/dev/null || true)"
    [[ -n "$cm" ]] && child_mounts+="$cm"$'\n'
  done
  mounts="$(printf '%s\n%s' "$mounts" "$child_mounts" | sort -u | sed '/^$/d')"

  if [[ -n "$mounts" ]]; then
    local mount_count
    mount_count="$(printf '%s' "$mounts" | wc -l)"
    echo "Unmounting $mount_count target partition(s)..."
    while IFS= read -r mp; do
      [[ -n "$mp" ]] || continue
      if umount "$mp" 2>/dev/null; then
        echo "  ✓ $mp"
      else
        echo "  ✗ $mp — could not unmount target filesystem" >&2
        return 1
      fi
    done <<<"$mounts"
  else
    echo "No target partitions mounted."
  fi

  # Final recheck: verify nothing is still mounted on the target device.
  for child in "$target"*; do
    [[ -b "$child" ]] || continue
    if findmnt -rn -S "$child" >/dev/null 2>&1; then
      echo "Target still has mounted filesystem: $child" >&2
      return 1
    fi
  done

  # Write the image.  pv is preferred for progress, but dd can report
  # progress itself if pv is unavailable.
  echo ""

  # Compute source checksum BEFORE writing so we verify against the exact
  # source state we intended to flash.
  echo "Computing source image checksum..."
  local img_hash
  img_hash="$(sha256sum "$img" | awk '{print $1}')" \
    || {
      echo "  ✗ Failed to compute image checksum" >&2
      return 1
    }
  echo "  Image SHA256:  $img_hash"

  echo "Writing image to $target (bs=$bs)..."
  local last_pct=-1
  if command -v pv >/dev/null 2>&1; then
    # pv reads the image and pipes data to dd.  pv's stderr (numeric
    # percentages) goes to a named pipe so we can emit @@PROGRESS:XX@@
    # markers for the GUI while dd writes the data.
    local flash_fifo
    flash_fifo="$(mktemp -u /tmp/flash-progress.XXXXXX)"
    mkfifo "$flash_fifo"

    pv -n -s "$img_bytes" "$img" 2>"$flash_fifo" \
      | dd of="$target" bs="$bs" conv=fsync oflag=sync &
    local dd_pid=$!

    while IFS= read -r pct; do
      [[ "$pct" =~ ^[0-9]+$ ]] || continue
      ((pct == last_pct)) && continue
      last_pct=$pct
      printf '%s\n' "@@PROGRESS:$pct@@"
    done <"$flash_fifo"

    wait "$dd_pid" || {
      rm -f "$flash_fifo"
      die "Flash write failed"
    }
    rm -f "$flash_fifo"
  else
    dd if="$img" of="$target" bs="$bs" status=progress conv=fsync oflag=sync 2>&1 \
      | while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+bytes ]]; then
          local written="${BASH_REMATCH[1]}"
          local pct=$((written * 100 / img_bytes))
          ((pct == last_pct)) && continue
          ((pct > 100)) && pct=100
          last_pct=$pct
          printf '%s\n' "@@PROGRESS:$pct@@"
        fi
      done
  fi

  echo "Syncing image data..."
  sync 2>/dev/null || true

  # Flush the block device cache so the readback actually hits the device
  # rather than being satisfied from kernel page cache.
  blockdev --flushbufs "$target" 2>/dev/null || true

  # Verify the raw write BEFORE any post-write modifications.
  flash_verify_raw "$img" "$target" "$img_bytes" "$img_hash" || return 1

  # Raw disk images carry their backup GPT at the end of the IMAGE.  When that
  # image is written to a larger USB stick, the copied backup GPT remains at
  # the old image-size boundary instead of the physical end of the target.
  # Relocate it after the write so the flashed device has a canonical GPT.
  local gpt_fixup="skipped"
  if ((target_bytes > img_bytes)); then
    if command -v sgdisk >/dev/null 2>&1; then
      echo "Target is larger than the image; relocating backup GPT to end of disk..."
      if ! sgdisk --move-second-header "$target"; then
        echo "Failed to relocate backup GPT on $target." >&2
        return 1
      fi

      # Flush the relocated GPT to the device before asking the kernel to
      # re-read it.
      sync 2>/dev/null || true
      blockdev --flushbufs "$target" 2>/dev/null || true

      # Ask the kernel/udev to refresh their view.  rereadpt can
      # occasionally fail even though the GPT on disk is valid, so treat
      # it as advisory rather than fatal.
      blockdev --rereadpt "$target" 2>/dev/null || true
      udevadm settle --timeout=10 2>/dev/null || true

      gpt_fixup="relocated"
      echo "Backup GPT relocated successfully."
    else
      echo "WARNING: $target is larger than the image, but sgdisk is unavailable." >&2
      echo "         Flash succeeded, but the backup GPT remains at the image-size boundary." >&2
      echo "         Install GPT fdisk/sgdisk and run:" >&2
      echo "           sgdisk --move-second-header $target" >&2
      # shellcheck disable=SC2034
      gpt_fixup="unavailable"
    fi
  fi

  # Verify target GPT is valid — this is independent of whether the
  # kernel reread succeeded.
  if command -v sgdisk >/dev/null 2>&1; then
    if sgdisk -v "$target" >/dev/null 2>&1; then
      echo "  ✓ Target GPT valid"
    else
      echo "  ✗ Target GPT invalid after relocation"
      return 1
    fi
  fi

  # Discover the new partitions and mount home for the user.
  echo ""
  echo "Discovering new partitions..."
  udevadm settle --timeout=15 2>/dev/null || true

  # Check if the kernel sees partitions on the target.  If not, try
  # partx -u to force a partition table re-read before giving up.
  local part_count=0
  for part in "${target}"*; do
    [[ -b "$part" ]] && part_count=$((part_count + 1))
  done
  if ((part_count == 0)); then
    echo "  Kernel does not see partitions; trying partx -u..."
    partx -u "$target" 2>/dev/null || true
    udevadm settle --timeout=10 2>/dev/null || true
  fi

  local home_part=""
  local expected_parts=0 found_parts=0
  local part
  for part in "${target}"*; do
    [[ -b "$part" ]] || continue
    expected_parts=$((expected_parts + 1))
    local pname
    pname="$(blkid -s PARTLABEL -o value "$part" 2>/dev/null || true)"
    if [[ -n "$pname" ]]; then
      found_parts=$((found_parts + 1))
    fi
    case "$pname" in
      home) home_part="$part" ;;
    esac
  done

  if ((expected_parts > 0 && found_parts == 0)); then
    echo "  ✗ No partition labels found — kernel may not have re-read the table"
    echo "    Try: partx -u $target"
    return 1
  fi

  if [[ -n "$home_part" ]]; then
    local mount_point="/run/media/${SUDO_USER:-deck}/home"
    mkdir -p "$mount_point"
    if mount "$home_part" "$mount_point" 2>/dev/null; then
      echo "  ✓ home mounted at $mount_point"
    else
      echo "  ⚠ Could not mount home partition (non-fatal)"
    fi
  fi

  echo ""
  echo "Flash complete!"
}
