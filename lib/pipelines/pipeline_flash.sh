#!/bin/bash
#
# steamos-build-installer — lib/pipelines/pipeline_flash.sh
# Flash pipeline definition.
# Writes a SteamOS image to a target block device.
#
# Phases: validate → write → finalize
#
# Sourced by backend.sh — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  log_error flash library-guard "lib/pipelines/pipeline_flash.sh is a library — source it from the wrapper, not run directly."
  exit 1
fi

# ---------------------------------------------------------------------------
# Pipeline Definition
# ---------------------------------------------------------------------------

register_flash_pipeline() {
  _PIPELINE_NAME="flash"
  define_pipeline "validate" "write" "finalize"
  register_phase "validate" "_phase_flash_validate" "Validate inputs and safety checks"
  register_phase "write" "_phase_flash_write" "Write image to target device"
  register_phase "finalize" "_phase_flash_finalize" "GPT fixup, partition discovery, mount home"
}

# ---------------------------------------------------------------------------
# Phase: Validate
# ---------------------------------------------------------------------------
# Validates inputs, checks sizes, and ensures flash can proceed.

_phase_flash_validate() {
  stage_header "flash validate"
  local img="$IMG" target="$TARGET_DEV"

  [[ -f "$img" ]] || {
    log_error flash validation-error "Image not found: $img"
    return 1
  }
  [[ -b "$target" ]] || {
    log_error flash validation-error "Not a block device: $target"
    return 1
  }
  [[ $EUID -eq 0 ]] || {
    log_error flash validation-error "Flash requires root (sudo)."
    return 1
  }

  # Collect sizes (preflight already ran, but we need these for the write).
  IMG_BYTES="$(stat -c '%s' "$img")" || {
    log_error flash validation-error "Cannot determine image size: $img"
    return 1
  }
  TARGET_BYTES="$(blockdev --getsize64 "$target")" || {
    log_error flash validation-error "Cannot determine target size: $target"
    return 1
  }
  if ((IMG_BYTES > TARGET_BYTES)); then
    log_error flash validation-error "Image ($((IMG_BYTES / 1000000000)) GB) is larger than target device ($((TARGET_BYTES / 1000000000)) GB)."
    return 1
  fi

  echo "  Image size:  $IMG_BYTES bytes"
  echo "  Target size: $TARGET_BYTES bytes"
  return 0
}

# ---------------------------------------------------------------------------
# Phase: Write
# ---------------------------------------------------------------------------
# Unmounts target, computes checksum, writes image via dd, verifies.

_phase_flash_write() {
  stage_header "flash write"
  local img="$IMG" target="$TARGET_DEV" bs="4M"

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
    while IFS="" read -r mp; do
      [[ -n "$mp" ]] || continue
      if strict_unmount "$mp" "target before dd"; then
        echo "  ✓ $mp"
      else
        log_error flash unmount-error "  ✗ $mp — could not unmount target filesystem"
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
      log_error flash unmount-error "Target still has mounted filesystem: $child"
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
      log_error flash checksum-error "  ✗ Failed to compute image checksum"
      return 1
    }
  echo "  Image SHA256:  $img_hash"

  echo "Writing image to $target (bs=$bs)..."
  local last_pct=-1
  if command -v pv >/dev/null 2>&1; then
    # pv reads the image and pipes data to dd.  pv's stderr (numeric
    # percentages) goes to a named pipe so we can emit @@PROGRESS:XX@@
    # markers for the GUI while dd writes the data.
    # Use explicit cleanup instead of EXIT trap to avoid conflicting
    # with the parent trap.
    local _fifo_dir
    _fifo_dir="$(mktemp -d /tmp/flash-pv.XXXXXX)"
    local flash_fifo="$_fifo_dir/progress"
    mkfifo "$flash_fifo"

    pv -n -s "$IMG_BYTES" "$img" 2>"$flash_fifo" \
      | dd of="$target" bs="$bs" conv=fsync oflag=sync &
    local dd_pid=$!

    while IFS="" read -r pct; do
      [[ "$pct" =~ ^[0-9]+$ ]] || continue
      [[ "$pct" -eq "$last_pct" ]] && continue
      last_pct=$pct
      printf '%s\n' "@@PROGRESS:$pct@@"
    done <"$flash_fifo"

    local dd_rc=0
    wait "$dd_pid" || dd_rc=$?
    safe_rmdir "$_fifo_dir" 2>/dev/null || true
    if [[ "$dd_rc" -ne 0 ]]; then
      log_error flash write-error "Flash write failed (dd exited with code $dd_rc)"
      return 1
    fi
  else
    local dd_exit=0
    dd if="$img" of="$target" bs="$bs" status=progress conv=fsync oflag=sync \
      > >(while IFS="" read -r line; do
        if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+bytes ]]; then
          local written="${BASH_REMATCH[1]}"
          local pct=$((written * 100 / IMG_BYTES))
          [[ "$pct" -eq "$last_pct" ]] && continue
          [[ "$pct" -gt 100 ]] && pct=100
          last_pct=$pct
          printf '%s\n' "@@PROGRESS:$pct@@"
        else
          # Let dd error/status lines through to stderr
          printf '%s\n' "$line" >&2
        fi
      done) 2>&1 || dd_exit=$?
    if [[ "$dd_exit" -ne 0 ]]; then
      log_error flash write-error "Flash write failed (dd exited with code $dd_exit)"
      return 1
    fi
  fi

  echo "Syncing image data..."
  sync 2>/dev/null || true

  # Flush the block device cache so the readback actually hits the device
  # rather than being satisfied from kernel page cache.
  blockdev --flushbufs "$target" 2>/dev/null || true

  # Verify the raw write BEFORE any post-write modifications.
  flash_verify_raw "$img" "$target" "$IMG_BYTES" "$img_hash" || return 1

  return 0
}

# ---------------------------------------------------------------------------
# Phase: Finalize
# ---------------------------------------------------------------------------
# GPT fixup, partition discovery, and mount home partition.

_phase_flash_finalize() {
  stage_header "flash finalize"
  local img="$IMG" target="$TARGET_DEV"

  # Raw disk images carry their backup GPT at the end of the IMAGE.  When that
  # image is written to a larger USB stick, the copied backup GPT remains at
  # the old image-size boundary instead of the physical end of the target.
  # Relocate it after the write so the flashed device has a canonical GPT.
  local gpt_fixup="skipped"
  if ((TARGET_BYTES > IMG_BYTES)); then
    if command -v sgdisk >/dev/null 2>&1; then
      echo "Target is larger than the image; relocating backup GPT to end of disk..."
      if ! sgdisk --move-second-header "$target"; then
        log_error flash gpt-fixup-error "Failed to relocate backup GPT on $target."
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
      run_dangerous_cmd udevadm settle --timeout=10 2>/dev/null || true

      gpt_fixup="relocated"
      echo "Backup GPT relocated successfully."
    else
      log_warn flash gpt-unavailable "WARNING: $target is larger than the image, but sgdisk is unavailable."
      log_warn flash gpt-unavailable "         Flash succeeded, but the backup GPT remains at the image-size boundary."
      log_warn flash gpt-unavailable "         Install GPT fdisk/sgdisk and run:"
      log_warn flash gpt-unavailable "           sgdisk --move-second-header $target"
      gpt_fixup="unavailable"
    fi
  fi

  debug "  GPT fixup: $gpt_fixup"

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
  run_dangerous_cmd udevadm settle --timeout=15 2>/dev/null || true

  # Check if the kernel sees partitions on the target.  If not, try
  # partx -u to force a partition table re-read before giving up.
  local part_count=0
  for part in "${target}"*; do
    [[ -b "$part" ]] && part_count=$((part_count + 1))
  done
  if ((part_count == 0)); then
    echo "  Kernel does not see partitions; trying partx -u..."
    partx -u "$target" 2>/dev/null || true
    run_dangerous_cmd udevadm settle --timeout=10 2>/dev/null || true
  fi

  local home_part=""
  local expected_count=0 found_count=0
  local part
  for part in "${target}"*; do
    [[ -b "$part" ]] || continue
    expected_count=$((expected_count + 1))
    local pname
    pname="$(blkid -s PARTLABEL -o value "$part" 2>/dev/null || true)"
    if [[ -n "$pname" ]]; then
      found_count=$((found_count + 1))
    fi
    case "$pname" in
      home) home_part="$part" ;;
    esac
  done

  if ((expected_count > 0 && found_count == 0)); then
    echo "  ✗ No partition labels found — kernel may not have re-read the table"
    echo "    Try: partx -u $target"
    return 1
  fi

  cleanup_set_workspace "/run/media" 2>/dev/null || true
  if [[ -n "$home_part" ]]; then
    local mount_point="/run/media/${SUDO_USER:-deck}/home"
    mkdir -p "$mount_point"
    if cleanup_mount "$mount_point" "flash home" -- "$home_part"; then
      echo "  ✓ home mounted at $mount_point"
    else
      echo "  ⚠ Could not mount home partition (non-fatal)"
    fi
  fi

  echo ""
  echo "Flash complete!"
  return 0
}
