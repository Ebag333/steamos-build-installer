#!/bin/bash
#
# steamos-nvidia-installer — lib/setup.sh
# Stage 1: create build dirs, copy the image, set up the loop device and the
# rootfs/efi/home mounts, and discover the image's kernel + headers.
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/setup.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# If the user didn't explicitly set --workdir, pick RAM or disk automatically.
# Strategy: read the decompressed image size from the GPT header, then require
# that size + 15 GB working headroom.  Fall back to compressed × 3 if GPT
# parsing fails.
setup_resolve_workdir() {
  if [[ -n "${_WORKDIR_EXPLICIT:-}" ]]; then
    return 0  # user specified --workdir, don't override
  fi

  # If the user forced a location via config, honour it.
  if [[ "${WORKDIR_LOCATION:-auto}" == "ram" ]]; then
    WORKDIR="/dev/shm/nvidia-build"
    OUT_FINAL="$WORKDIR/$(basename "$OUT_FINAL")"
    OUT="$WORKDIR/$(basename "$OUT")"
    mkdir -p "$WORKDIR"
    log "Build workspace: RAM (forced by config)"
    return 0
  fi

  local disk_avail ram_avail need_mb

  disk_avail="$(df -m --output=avail "$(dirname "$OUT")" | tail -1 | tr -d ' ')"
  ram_avail="$(df -m --output=avail /dev/shm 2>/dev/null | tail -1 | tr -d ' ' || echo 0)"

  # Get the actual decompressed image size from the GPT header.
  # For a raw GPT disk image, the backup GPT header LBA (at offset 512+32)
  # gives the last sector, which tells us the total image size.
  # Only reads the first 1 MiB of the decompressed stream — fast even for
  # compressed images.
  local img_bytes
  if [[ -f "$IMG" ]]; then
    case "$IMG" in
      *.bz2)  img_bytes="$(bzip2 -dc "$IMG" 2>/dev/null | head -c 1M | python3 -c '
import sys, struct
d = sys.stdin.buffer.read()
if len(d) >= 520 and d[512:520] == b"EFI PART":
    last_lba = struct.unpack_from("<Q", d, 512 + 32)[0]
    print((last_lba + 1) * 512)
' 2>/dev/null || true)" ;;
      *.gz)   img_bytes="$(gzip -dc "$IMG" 2>/dev/null | head -c 1M | python3 -c '
import sys, struct
d = sys.stdin.buffer.read()
if len(d) >= 520 and d[512:520] == b"EFI PART":
    last_lba = struct.unpack_from("<Q", d, 512 + 32)[0]
    print((last_lba + 1) * 512)
' 2>/dev/null || true)" ;;
      *.xz)   img_bytes="$(xz -dc "$IMG" 2>/dev/null | head -c 1M | python3 -c '
import sys, struct
d = sys.stdin.buffer.read()
if len(d) >= 520 and d[512:520] == b"EFI PART":
    last_lba = struct.unpack_from("<Q", d, 512 + 32)[0]
    print((last_lba + 1) * 512)
' 2>/dev/null || true)" ;;
      *.zst)  img_bytes="$(zstd -dc "$IMG" 2>/dev/null | head -c 1M | python3 -c '
import sys, struct
d = sys.stdin.buffer.read()
if len(d) >= 520 and d[512:520] == b"EFI PART":
    last_lba = struct.unpack_from("<Q", d, 512 + 32)[0]
    print((last_lba + 1) * 512)
' 2>/dev/null || true)" ;;
      *)      img_bytes="$(stat -c '%s' "$IMG")" ;;
    esac
  fi

  # Fall back to compressed size × 3 if GPT parsing failed.
  if [[ -z "$img_bytes" || "$img_bytes" == "0" ]]; then
    local compressed_mb
    compressed_mb=$(( $(stat -c '%s' "$IMG") / 1048576 ))
    need_mb=$(( compressed_mb * 3 ))
    (( need_mb < 12288 )) && need_mb=12288
    log "Could not read GPT header — estimating ${need_mb} MB from compressed size"
  else
    # Decompressed image + 15 GB working headroom (overlay, packages, build).
    # The overlay-work.img is sparse, so its 8 GB nominal size doesn't fully
    # consume space — 15 GB headroom is realistic.
    local img_mb=$(( img_bytes / 1048576 ))
    need_mb=$(( img_mb + 15360 ))
    log "Decompressed image: ${img_mb} MB, need ~${need_mb} MB (image + 15 GB headroom)"
  fi

  if [[ "${WORKDIR_LOCATION:-auto}" == "disk" ]]; then
    (( disk_avail >= need_mb )) || die "Disk only has ${disk_avail} MB free, need ~${need_mb} MB."
    log "Build workspace: disk (forced by config, ${disk_avail} MB free)"
    return 0
  fi

  # Auto: prefer RAM if it has enough headroom, otherwise disk.
  if (( ram_avail >= need_mb )); then
    WORKDIR="/dev/shm/nvidia-build"
    OUT_FINAL="$WORKDIR/$(basename "$OUT_FINAL")"
    OUT="$WORKDIR/$(basename "$OUT")"
    mkdir -p "$WORKDIR"
    log "Build workspace: RAM (/dev/shm, ${ram_avail} MB free, need ~${need_mb})"
  elif (( disk_avail >= need_mb )); then
    log "Build workspace: disk (${disk_avail} MB free, RAM only ${ram_avail} MB)"
  else
    die "Not enough space: RAM=${ram_avail} MB, disk=${disk_avail} MB. Need ~${need_mb} MB."
  fi
}

# Build/scratch mountpoints used across the whole run.
setup_dirs() {
  log "Creating build directories under $WORKDIR"
  mkdir -p "$MNT" "$EFIMNT" "$HOMEMNT" "$OVLWORK" "$MERGED"
  mkdir -p "${OVL_MNT:-$WORKDIR/overlay-mnt}"
  log "  MERGED=$MERGED (exists: $([[ -d "$MERGED" ]] && echo yes || echo no))"
}

# Clean up stale state from interrupted previous runs: unmount anything backed
# by our output image, detach loop devices, and remove leftover data that
# wastes disk space.  Idempotent — safe to call every run.
setup_clear_stale_state() {
  # Remove incomplete decompressed images from a crashed bzip2/gzip/etc.
  if [[ -f "$OUT" && ! -f "${OUT}.src-fingerprint" ]]; then
    warn "Removing incomplete output from previous failed run"
    rm -f "$OUT"
  fi

  # Detach any loop device backed by our output image.
  local _loop_devs
  _loop_devs="$(losetup -J 2>/dev/null \
    | python3 -c '
import json, sys
target = sys.argv[1]
for d in json.load(sys.stdin).get("loopdevices", []):
    if d.get("back-file", "") == target:
        print(d["name"])
' "$OUT" 2>/dev/null || true)"
  while read -r dev; do
    [[ -n "$dev" ]] || continue
    findmnt -rn -o TARGET,SOURCE 2>/dev/null       | awk -v l="$dev" '$2 ~ "^"l {print $1}'       | tac | while read -r m; do
          warn "Unmounting stale mount $m (from previous run)"
          umount -R "$m" 2>/dev/null || umount -Rl "$m" 2>/dev/null
        done
    warn "Detaching stale loop device $dev"
    losetup -d "$dev" 2>/dev/null
  done <<< "$_loop_devs"

  # Unmount stale overlay workspace (from a crashed build).
  if [[ -d "$WORKDIR/overlay-mnt" ]] && mountpoint -q "$WORKDIR/overlay-mnt" 2>/dev/null; then
    warn "Unmounting stale overlay workspace"
    umount -R "$WORKDIR/overlay-mnt" 2>/dev/null || umount -Rl "$WORKDIR/overlay-mnt" 2>/dev/null
  fi
  # Remove the overlay workspace image if it's not attached to any loop device.
  # losetup -j returns success even with no output, so check for empty output.
  if [[ -f "$WORKDIR/overlay-work.img" ]]; then
    if [[ -z "$(losetup -j "$WORKDIR/overlay-work.img" 2>/dev/null)" ]]; then
      warn "Removing orphaned overlay workspace image"
      rm -f "$WORKDIR/overlay-work.img"
    fi
  fi

  # Clear stale mountpoints and leftover data that wastes disk space.
  for m in "$MERGED" "$EFIMNT" "$HOMEMNT" "$MNT"; do
    if mountpoint -q "$m" 2>/dev/null; then
      warn "Stale mount at $m — unmounting"
      umount -R "$m" 2>/dev/null || umount -Rl "$m"
    fi
  done

  # Remove stale overlay residue (the overlay is gone but the files remain).
  for d in "$MERGED" "$UPPER" "$OVLWORK"; do
    if [[ -d "$d" ]] && ! mountpoint -q "$d" 2>/dev/null; then
      rm -rf "$d" 2>/dev/null
    fi
  done
}

# Keep udisks/desktop automounters away from our loop device during the run.
setup_udev_guard() {
  mkdir -p /run/udev/rules.d
  # Scope to our specific loop device rather than hiding all loop devices.
  echo "SUBSYSTEM==\"block\", KERNEL==\"${LOOPDEV#/dev/}*\", ENV{UDISKS_IGNORE}=\"1\"" > "$UDEV_RULE"
  udevadm control --reload
}

# Copy (or decompress) the input image into $OUT.  The copy is what we modify;
# the input is never touched.  Compressed inputs (.bz2/.gz/.xz/.zst) are
# decompressed directly into $OUT in one pass — no temp .img needed.
#
# Resume: if $OUT already exists and its source fingerprint matches, the
# decompression is skipped.  Delete $OUT manually to force a fresh copy.
setup_copy_image() {
  FINGERPRINT_FILE="${OUT}.src-fingerprint"

  # Build a fingerprint of the source.  For compressed files we hash the
  # compressed data (fast to read, definitive); for plain .img we use
  # size+mtime (hashing 8 GB is slow and unnecessary when the file IS the
  # output).
  case "$IMG" in
    *.bz2|*.gz|*.xz|*.zst)
      _src_fp="$(stat -c '%s:%Y' "$IMG"):$(sha256sum "$IMG" | cut -d' ' -f1)"
      ;;
    *)
      _src_fp="$(stat -c '%s:%Y' "$IMG"):plain"
      ;;
  esac

  # Check for a matching previous decompression.
  # The decompressed image ($OUT_FINAL) is valid whenever the source fingerprint
  # matches, regardless of whether the previous build succeeded.  The build
  # modifies $OUT_FINAL in-place, so we always copy it to a fresh $OUT (.building)
  # as a disposable working copy.
  if [[ -f "$OUT_FINAL" && -f "${OUT_FINAL}.src-fingerprint" ]]; then
    _prev_fp="$(cat "${OUT_FINAL}.src-fingerprint")"
    if [[ "$_src_fp" == "$_prev_fp" ]]; then
      log "Reusing existing $(basename "$OUT_FINAL") (source unchanged)"
      cp --reflink=auto "$OUT_FINAL" "$OUT"
      cp "${OUT_FINAL}.src-fingerprint" "${FINGERPRINT_FILE}"
      return 0
    fi
    log "Source changed — re-decompressing"
    rm -f "$OUT_FINAL" "${OUT_FINAL}.src-fingerprint" "${OUT_FINAL}.build-complete" "$OUT" "${FINGERPRINT_FILE}"
  elif [[ -f "$OUT" ]]; then
    log "Previous decompression incomplete — starting fresh"
    rm -f "$OUT" "${FINGERPRINT_FILE}"
  fi

  # Space check: decompressed image is ~8 GB, packages ~0.5 GB.
  # The overlay workspace is a sparse file (doesn't consume upfront).
  _avail_mb="$(df -m --output=avail "$(dirname "$OUT")" | tail -1 | tr -d ' ')"
  if (( _avail_mb < 9216 )); then
    die "Not enough disk space: ${_avail_mb} MB free, need ~9 GB. Use --workdir /dev/shm to build in RAM."
  fi

  case "$IMG" in
    *.bz2)  log "Decompressing $(basename "$IMG") → $(basename "$OUT")"; bzip2  -dkc "$IMG" > "$OUT" ;;
    *.gz)   log "Decompressing $(basename "$IMG") → $(basename "$OUT")"; gzip   -dkc "$IMG" > "$OUT" ;;
    *.xz)   log "Decompressing $(basename "$IMG") → $(basename "$OUT")"; xz     -dkc "$IMG" > "$OUT" ;;
    *.zst)  log "Decompressing $(basename "$IMG") → $(basename "$OUT")"; zstd   -dk  "$IMG" -o "$OUT" ;;
    *)      log "Copying image → $(basename "$OUT") (~8 GB)"; cp --reflink=auto "$IMG" "$OUT" ;;
  esac

  # Save the fingerprint for next run.
  echo "$_src_fp" > "$FINGERPRINT_FILE"
}

# Attach the output as a loop device and locate the SteamOS partitions.
setup_loop_mount() {
  LOOPDEV="$(losetup -f --show -P "$OUT")"
  log "Loop device: $LOOPDEV"

  # Wait for partition devices to appear (udev needs a moment after losetup -P).
  udevadm settle --timeout=10
  log "Scanning partitions on $LOOPDEV"

  ROOTPART="" EFIPART="" HOMEPART=""
  for part in "$LOOPDEV"p*; do
    [[ -b "$part" ]] || { warn "No partition devices found on $LOOPDEV — image may be corrupt"; break; }
    _pname="$(blkid -p -s PART_ENTRY_NAME -o value "$part" 2>/dev/null)" || true
    log "  $part: ${_pname:-<unknown>}"
    case "$_pname" in
      rootfs-A) ROOTPART="$part" ;;
      efi-A)    EFIPART="$part" ;;
      home)     HOMEPART="$part" ;;
    esac
  done
  log "rootfs=$ROOTPART efi=$EFIPART home=$HOMEPART"
  [[ -n "$ROOTPART" && -n "$EFIPART" && -n "$HOMEPART" ]] \
    || die "rootfs-A/efi-A/home partitions not found on $LOOPDEV — is this a SteamOS image?"

  # Diagnostic: check if this is a Btrfs seeding filesystem.
  log "Rootfs superblock flags:"
  btrfs inspect-internal dump-super "$ROOTPART" 2>/dev/null | grep -E 'flags|fsid|metadata_uuid' || true
  log "Inspecting Btrfs FS_TREE root item"
  btrfs inspect-internal dump-tree -t root "$ROOTPART" 2>/dev/null \
    | grep -A12 -B2 'key (FS_TREE ROOT_ITEM 0)' || true
  log "mkfs.btrfs version: $(mkfs.btrfs --version 2>/dev/null || echo 'unknown')"

  # Unmount any stale mounts backed by our loop partition (use the device,
  # not the UUID — cloned images may share UUIDs).
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    warn "Unmounting stale mount $target"
    umount -R "$target" 2>/dev/null || umount -Rl "$target" 2>/dev/null
  done < <(findmnt -rn -o TARGET -S "$ROOTPART" 2>/dev/null)
}

# The SteamOS repair image's FS_TREE root item has the RDONLY flag set.
# Btrfs won't let us write to it regardless of mount options.  Rebuild the
# filesystem as writable using mkfs.btrfs --rootdir, preserving UUIDs.
prepare_writable_rootfs() {
  local root_item root_bytes root_uuid root_dev_uuid root_label
  local srcmnt root_tmp new_bytes

  root_item="$(
    btrfs inspect-internal dump-tree -t root "$ROOTPART" 2>/dev/null |
      awk '
        /key \(FS_TREE ROOT_ITEM 0\)/ { found=1 }
        found && /flags / { print; exit }
      '
  )"

  if [[ "$root_item" != *"(RDONLY)"* ]]; then
    log "Rootfs FS_TREE is already writable"
    return 0
  fi

  log "Rootfs FS_TREE is RDONLY — rebuilding as writable Btrfs"

  srcmnt="$WORKDIR/rootfs-ro-source"
  root_tmp="$WORKDIR/rootfs-writable.img"

  mkdir -p "$srcmnt"
  rm -f "$root_tmp"

  root_bytes="$(blockdev --getsize64 "$ROOTPART")"
  root_uuid="$(blkid -s UUID -o value "$ROOTPART")"
  root_dev_uuid="$(blkid -s UUID_SUB -o value "$ROOTPART" || true)"
  root_label="$(blkid -s LABEL -o value "$ROOTPART" || true)"

  log "  Size: $root_bytes bytes"
  log "  UUID: $root_uuid"
  log "  Device UUID: ${root_dev_uuid:-<none>}"
  log "  Label: ${root_label:-<none>}"

  # Source stays completely untouched.
  mount -o ro "$ROOTPART" "$srcmnt"

  log "Original rootfs Btrfs usage:"
  btrfs filesystem usage -T "$srcmnt" >&2 || true

  log "Source rootfs disk usage:"
  du -sh "$srcmnt" >&2 || true
  du -sh --apparent-size "$srcmnt" >&2 || true

  truncate -s "$root_bytes" "$root_tmp"

  local mkfs_args=(
    -f
    -K
    -U "$root_uuid"
    -d single
    -m single
    --compress zstd:3
    --rootdir "$srcmnt"
    --shrink
  )

  [[ -n "$root_label" ]] &&
    mkfs_args+=(-L "$root_label")

  [[ -n "$root_dev_uuid" ]] &&
    mkfs_args+=(--device-uuid "$root_dev_uuid")

  log "Creating writable replacement filesystem"
  mkfs.btrfs "${mkfs_args[@]}" "$root_tmp" \
    || die "Failed to rebuild writable Btrfs rootfs"

  umount "$srcmnt"

  new_bytes="$(stat -c '%s' "$root_tmp")"
  if (( new_bytes > root_bytes )); then
    die "Rebuilt rootfs image grew beyond partition size"
  fi

  log "Writing rebuilt filesystem back to rootfs-A"
  dd if="$root_tmp" of="$ROOTPART" \
    bs=16M conv=fsync status=progress \
    || die "Failed to replace rootfs-A"

  rm -f "$root_tmp"

  # Make sure userspace sees the newly written filesystem.
  udevadm settle
  btrfs device scan "$ROOTPART" >/dev/null 2>&1 || true

  # Offline verification before proceeding.
  root_item="$(
    btrfs inspect-internal dump-tree -t root "$ROOTPART" 2>/dev/null |
      awk '
        /key \(FS_TREE ROOT_ITEM 0\)/ { found=1 }
        found && /flags / { print; exit }
      '
  )"

  log "Rebuilt FS_TREE: $root_item"

  [[ "$root_item" != *"(RDONLY)"* ]] \
    || die "Rebuilt rootfs is unexpectedly still RDONLY"
}

# Mount rootfs (btrfs), efi-A, and home.
setup_mount_partitions() {
  log "Loop device RO: $(blockdev --getro "$LOOPDEV")"
  log "Root partition RO: $(blockdev --getro "$ROOTPART")"
  log "Mounting rootfs ($ROOTPART) → $MNT"
  mount -o compress-force=zstd:3 "$ROOTPART" "$MNT"
  log "Mounting efi ($EFIPART) → $EFIMNT"
  mount "$EFIPART" "$EFIMNT"
  log "Mounting home ($HOMEPART) → $HOMEMNT"
  mount "$HOMEPART" "$HOMEMNT"

  log "Rootfs mount options: $(findmnt -no OPTIONS "$MNT")"

  # Don't continue unless an actual write succeeds.
  local rw_test="$MNT/.steamos-nvidia-rw-test"
  if ! touch "$rw_test"; then
    warn "Rootfs source: $(findmnt -no SOURCE "$MNT")"
    warn "Rootfs filesystem: $(findmnt -no FSTYPE "$MNT")"
    warn "Rootfs options: $(findmnt -no OPTIONS "$MNT")"
    warn "Recent Btrfs kernel messages:"
    dmesg | grep -i btrfs | tail -30 >&2 || true
    die "Rootfs mount reports rw but an actual write failed"
  fi
  rm -f "$rw_test"
  log "Rootfs is writable"

  # One-time metadata verification: compare source image against mounted copy
  # to confirm reconstruction didn't strip capabilities, permissions, or ownership.
  local src_mnt="$WORKDIR/src-mnt"
  mkdir -p "$src_mnt"
  local src_rootpart
  for part in "${LOOPDEV}p"*; do
    [[ -b "$part" ]] || continue
    local pname
    pname="$(blkid -p -s PART_ENTRY_NAME -o value "$part" 2>/dev/null)" || true
    if [[ "$pname" == "rootfs-A" ]]; then
      src_rootpart="$part"
      break
    fi
  done
  if [[ -n "${src_rootpart:-}" ]]; then
    mount -o ro "$src_rootpart" "$src_mnt" 2>/dev/null || true
    if mountpoint -q "$src_mnt" 2>/dev/null; then
      log "Comparing source vs mounted metadata (caps, uid/gid, perms)..."
      getcap -r "$src_mnt" 2>/dev/null | sort > /tmp/caps.old || true
      getcap -r "$MNT"    2>/dev/null | sort > /tmp/caps.new || true
      if ! diff -u /tmp/caps.old /tmp/caps.new >/dev/null 2>&1; then
        warn "Capability differences detected:"
        diff -u /tmp/caps.old /tmp/caps.new >&2 || true
      else
        log "  Capabilities: identical"
      fi
      find "$src_mnt" -xdev -printf '%P\t%u\t%g\t%m\n' 2>/dev/null | sort > /tmp/meta.old || true
      find "$MNT"    -xdev -printf '%P\t%u\t%g\t%m\n' 2>/dev/null | sort > /tmp/meta.new || true
      if ! diff -u /tmp/meta.old /tmp/meta.new >/dev/null 2>&1; then
        warn "Metadata differences detected (uid/gid/perms):"
        diff -u /tmp/meta.old /tmp/meta.new | head -50 >&2 || true
      else
        log "  Metadata (uid/gid/perms): identical"
      fi
      umount "$src_mnt" 2>/dev/null || true
    fi
  fi
  rmdir "$src_mnt" 2>/dev/null || true
}

# Discover the neptune kernel, its installed pacman package, and the
# exact-match headers URL from Valve's pool.
setup_discover() {
  KVER=""
  for d in "$MNT/usr/lib/modules/"*neptune*; do
    [[ -d "$d" ]] && KVER="$(basename "$d")" && break
  done
  [[ -n "$KVER" ]] || die "No neptune kernel found in image"
  log "Image kernel: $KVER"

  # Find the package that owns this exact kernel version, rather than
  # independently globbing — avoids mismatch when multiple kernels exist.
  PACDB="$MNT/usr/lib/holo/pacmandb/local"
  KPKG_DIR=""
  for d in "$PACDB"/linux-neptune-*-[0-9]*; do
    [[ -d "$d" ]] || continue
    case "$(basename "$d")" in
      *-headers-*|*firmware*|*rtw*) continue ;;
    esac
    # Verify this package actually owns the discovered kernel directory.
    if grep -q "^usr/lib/modules/$KVER/$" "$d/files" 2>/dev/null; then
      KPKG_DIR="$d"; break
    fi
  done
  # Fallback to the old glob approach if file-list check didn't work.
  if [[ -z "$KPKG_DIR" ]]; then
    for d in "$PACDB"/linux-neptune-*-[0-9]*; do
      [[ -d "$d" ]] || continue
      case "$(basename "$d")" in
        *-headers-*|*firmware*|*rtw*) continue ;;
      esac
      KPKG_DIR="$d"; break
    done
  fi
  [[ -n "$KPKG_DIR" ]] || die "Could not find installed kernel package in pacman db"
  KPKG_FULL="$(basename "$KPKG_DIR")"
  KPKG_NAME="${KPKG_FULL%-*-*}"
  KPKG_VERREL="${KPKG_FULL#"$KPKG_NAME"-}"
  log "Kernel package: $KPKG_NAME $KPKG_VERREL"

  JUPITER_REPO="$(awk -F'[][]' '/^\[jupiter-/{print $2; exit}' "$MNT/etc/pacman.conf")"
  [[ -n "$JUPITER_REPO" ]] || die "No jupiter repo in image pacman.conf"
  MIRROR="$(awk '/^Server/{print $3; exit}' "$MNT/etc/pacman.d/mirrorlist")"
  HDR_URL="${MIRROR/\$repo/$JUPITER_REPO}"
  HDR_URL="${HDR_URL/\$arch/x86_64}/${KPKG_NAME}-headers-${KPKG_VERREL}-x86_64.pkg.tar.zst"
  curl_retry 3 -sfIL "$HDR_URL" -o /dev/null \
    || die "Exact-match headers not found in Valve's pool: $HDR_URL"
  log "Headers package: $(basename "$HDR_URL")"
}