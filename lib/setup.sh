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

# If the user didn't explicitly set --workdir, check disk vs RAM and pick
# whichever has more free space.  The build needs ~9 GB (decompressed image
# + overlay workspace + packages).
setup_resolve_workdir() {
  if [[ -n "${_WORKDIR_EXPLICIT:-}" ]]; then
    return 0  # user specified --workdir, don't override
  fi

  local disk_avail ram_avail
  disk_avail="$(df -m --output=avail "$(dirname "$OUT")" | tail -1 | tr -d ' ')"
  ram_avail="$(df -m --output=avail /dev/shm 2>/dev/null | tail -1 | tr -d ' ' || echo 0)"

  if (( disk_avail >= 9216 )); then
    log "Build workspace: disk (${disk_avail} MB free) — sufficient"
  elif (( ram_avail >= 9216 )); then
    WORKDIR="/dev/shm/nvidia-build"
    OUT="$WORKDIR/$(basename "$OUT")"
    mkdir -p "$WORKDIR"
    log "Build workspace: RAM (/dev/shm, ${ram_avail} MB free) — disk only has ${disk_avail} MB"
  else
    die "Not enough space anywhere: disk=${disk_avail} MB, RAM=${ram_avail} MB. Need ~9 GB."
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
  while read -r dev; do
    [[ -n "$dev" ]] || continue
    findmnt -rn -o TARGET,SOURCE 2>/dev/null \
      | awk -v l="$dev" '$2 ~ "^"l {print $1}' \
      | tac | while read -r m; do
          warn "Unmounting stale mount $m (from previous run)"
          umount -R "$m" 2>/dev/null || umount -Rl "$m" 2>/dev/null
        done
    warn "Detaching stale loop device $dev"
    losetup -d "$dev" 2>/dev/null
  done < <(losetup -J 2>/dev/null \
    | python3 -c "import json,sys
d=json.load(sys.stdin)
for d in d.get('loopdevices',[]):
    if d.get('back-file','')=='$OUT':
        print(d['name'])" 2>/dev/null || true)

  # Unmount stale overlay workspace (from a crashed build).
  if [[ -d "$WORKDIR/overlay-mnt" ]] && mountpoint -q "$WORKDIR/overlay-mnt" 2>/dev/null; then
    warn "Unmounting stale overlay workspace"
    umount -R "$WORKDIR/overlay-mnt" 2>/dev/null || umount -Rl "$WORKDIR/overlay-mnt" 2>/dev/null
  fi
  # Remove the overlay workspace image if it's not attached to any loop device.
  if [[ -f "$WORKDIR/overlay-work.img" ]]; then
    if ! losetup -j "$WORKDIR/overlay-work.img" >/dev/null 2>&1; then
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

# Keep udisks/desktop automounters away from loop partitions during the run.
setup_udev_guard() {
  mkdir -p /run/udev/rules.d
  echo 'SUBSYSTEM=="block", KERNEL=="loop*", ENV{UDISKS_IGNORE}="1"' > "$UDEV_RULE"
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
  if [[ -f "$OUT" && -f "$FINGERPRINT_FILE" ]]; then
    _prev_fp="$(cat "$FINGERPRINT_FILE")"
    if [[ "$_src_fp" == "$_prev_fp" ]]; then
      log "Reusing existing $(basename "$OUT") (source unchanged)"
      return 0
    fi
    log "Source changed — re-decompressing"
    rm -f "$OUT" "$FINGERPRINT_FILE"
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

  FSUUID="$(blkid -p -s UUID -o value "$ROOTPART")"
  if findmnt -rn -S "UUID=$FSUUID" >/dev/null 2>&1; then
    warn "UUID $FSUUID is already mounted — unmounting stale mount"
    umount -R "$(findmnt -rn -o TARGET -S "UUID=$FSUUID")" 2>/dev/null \
      || umount -Rl "$(findmnt -rn -o TARGET -S "UUID=$FSUUID")" 2>/dev/null
  fi
}

# Mount rootfs (btrfs), efi-A, and home; clear the btrfs RO property so we can
# write into the image rootfs.
setup_mount_partitions() {
  log "Mounting rootfs ($ROOTPART) → $MNT"
  mount -o compress-force=zstd:3 "$ROOTPART" "$MNT"
  log "Mounting efi ($EFIPART) → $EFIMNT"
  mount "$EFIPART" "$EFIMNT"
  log "Mounting home ($HOMEPART) → $HOMEMNT"
  mount "$HOMEPART" "$HOMEMNT"

  if [[ "$(btrfs property get "$MNT" ro)" == "ro=true" ]]; then
    log "Clearing btrfs read-only property"
    btrfs property set "$MNT" ro false
  fi
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

  PACDB="$MNT/usr/lib/holo/pacmandb/local"
  KPKG_DIR=""
  for d in "$PACDB"/linux-neptune-*-[0-9]*; do
    [[ -d "$d" ]] || continue
    case "$(basename "$d")" in
      *-headers-*|*firmware*|*rtw*) continue ;;
    esac
    KPKG_DIR="$d"; break
  done
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
  curl -sfIL "$HDR_URL" -o /dev/null \
    || die "Exact-match headers not found in Valve's pool: $HDR_URL"
  log "Headers package: $(basename "$HDR_URL")"
}