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

# Build/scratch mountpoints used across the whole run.
setup_dirs() {
  mkdir -p "$MNT" "$EFIMNT" "$HOMEMNT" "$UPPER" "$OVLWORK" "$MERGED"
}

# Clear stale mounts left by an interrupted previous run.
setup_clear_stale_mounts() {
  for m in "$MERGED" "$EFIMNT" "$HOMEMNT" "$MNT"; do
    if mountpoint -q "$m" 2>/dev/null; then
      warn "Stale mount from a previous run at $m — unmounting"
      umount -R "$m" 2>/dev/null || umount -Rl "$m"
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
setup_copy_image() {
  case "$IMG" in
    *.bz2)  log "Decompressing $(basename "$IMG") → $(basename "$OUT")"; bzip2  -dkc "$IMG" > "$OUT" ;;
    *.gz)   log "Decompressing $(basename "$IMG") → $(basename "$OUT")"; gzip   -dkc "$IMG" > "$OUT" ;;
    *.xz)   log "Decompressing $(basename "$IMG") → $(basename "$OUT")"; xz     -dkc "$IMG" > "$OUT" ;;
    *.zst)  log "Decompressing $(basename "$IMG") → $(basename "$OUT")"; zstd   -dk  "$IMG" -o "$OUT" ;;
    *)      log "Copying image → $(basename "$OUT") (~8 GB)"; cp --reflink=auto "$IMG" "$OUT" ;;
  esac
}

# Attach the output as a loop device and locate the SteamOS partitions.
setup_loop_mount() {
  LOOPDEV="$(losetup -f --show -P "$OUT")"
  log "Loop device: $LOOPDEV"

  ROOTPART="" EFIPART="" HOMEPART=""
  for part in "$LOOPDEV"p*; do
    case "$(blkid -p -s PART_ENTRY_NAME -o value "$part" 2>/dev/null)" in
      rootfs-A) ROOTPART="$part" ;;
      efi-A)    EFIPART="$part" ;;
      home)     HOMEPART="$part" ;;
    esac
  done
  [[ -n "$ROOTPART" && -n "$EFIPART" && -n "$HOMEPART" ]] \
    || die "rootfs-A/efi-A/home partitions not found — is this a SteamOS image?"

  FSUUID="$(blkid -p -s UUID -o value "$ROOTPART")"
  findmnt -rn -S "UUID=$FSUUID" >/dev/null 2>&1 \
    && die "A filesystem with UUID $FSUUID is already mounted (another copy of this image?). Unmount it first."
}

# Mount rootfs (btrfs), efi-A, and home; clear the btrfs RO property so we can
# write into the image rootfs.
setup_mount_partitions() {
  log "Mounting rootfs + efi + home"
  mount -o compress-force=zstd:3 "$ROOTPART" "$MNT"
  mount "$EFIPART" "$EFIMNT"
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