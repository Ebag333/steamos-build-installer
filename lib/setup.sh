#!/bin/bash
#
# steamos-build-installer — lib/setup.sh
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
    return 0 # user specified --workdir, don't override
  fi

  # If the user forced a location via config, honour it.
  if [[ "${WORKDIR_LOCATION:-auto}" == "ram" ]]; then
    # When RAM is forced, still validate the final destination has room for the
    # completed image, since it will be mv'd there at the end of the build.
    if [[ -n "${OUT_FINAL:-}" && "$OUT" != "$OUT_FINAL" ]]; then
      local final_avail
      final_avail="$(df -m --output=avail "$(dirname "$OUT_FINAL")" | tail -1 | tr -d ' ')"
      # need_mb may not be computed yet; estimate conservatively from the
      # decompressed image (~8 GB) + 15 GB headroom = ~23 GB.
      local final_need="${need_mb:-23552}"
      if ((final_avail < final_need)); then
        die "Final destination $(dirname "$OUT_FINAL") only has ${final_avail} MB free, need ~${final_need} MB for the completed image."
      fi
      log "Final destination: ${final_avail} MB free on $(dirname "$OUT_FINAL"), need ~${final_need} MB — OK"
    fi
    WORKDIR="/dev/shm/steamos-build"
    OUT="$WORKDIR/$(basename "$OUT")"
    mkdir -p "$WORKDIR" || die "Failed to create work directory: $WORKDIR"
    log "Build workspace: RAM (forced by config)"
    return 0
  fi

  local disk_avail ram_avail need_mb

  disk_avail="$(df -m --output=avail "$(dirname "$OUT")" | tail -1 | tr -d ' ')"
  ram_avail="$(df -m --output=avail /dev/shm 2>/dev/null | tail -1 | tr -d ' ')"
  ram_avail="${ram_avail:-0}"

  # Get the actual decompressed image size from the GPT header, and also
  # find rootfs-A's partition size so we can project the image growth when
  # ROOTFS_SIZE is set.  Only reads the first 1 MiB of the decompressed
  # stream — fast even for compressed images.
  local gpt_out img_bytes rootfs_a_bytes=0
  local gpt_parser='
import sys, struct
d = sys.stdin.buffer.read()
if len(d) >= 596 and d[512:520] == b"EFI PART":
    last_lba = struct.unpack_from("<Q", d, 512 + 32)[0]
    print((last_lba + 1) * 512)
    entry_start_lba = struct.unpack_from("<Q", d, 512 + 72)[0]
    num_entries = struct.unpack_from("<I", d, 512 + 80)[0]
    entry_size = struct.unpack_from("<I", d, 512 + 84)[0]
    entry_start = entry_start_lba * 512
    for i in range(num_entries):
        off = entry_start + i * entry_size
        e = d[off:off + entry_size]
        if len(e) < entry_size or e[0:16] == b"\x00" * 16:
            continue
        first = struct.unpack_from("<Q", e, 32)[0]
        last = struct.unpack_from("<Q", e, 40)[0]
        name_raw = e[56:128]
        try:
            name = name_raw.decode("utf-16-le").rstrip("\x00")
        except Exception:
            name = ""
        if name == "rootfs-A":
            print((last - first + 1) * 512)
            break
'
  if [[ -f "$IMG" ]]; then
    case "$IMG" in
      *.bz2) gpt_out="$(bzip2 -dc "$IMG" 2>/dev/null | head -c 1M | python3 -c "$gpt_parser" 2>/dev/null || true)" ;;
      *.gz) gpt_out="$(gzip -dc "$IMG" 2>/dev/null | head -c 1M | python3 -c "$gpt_parser" 2>/dev/null || true)" ;;
      *.xz) gpt_out="$(xz -dc "$IMG" 2>/dev/null | head -c 1M | python3 -c "$gpt_parser" 2>/dev/null || true)" ;;
      *.zst) gpt_out="$(zstd -dc "$IMG" 2>/dev/null | head -c 1M | python3 -c "$gpt_parser" 2>/dev/null || true)" ;;
      *) gpt_out="$(head -c 1M "$IMG" | python3 -c "$gpt_parser" 2>/dev/null || true)" ;;
    esac
    img_bytes="$(printf '%s\n' "$gpt_out" | head -1)"
    rootfs_a_bytes="$(printf '%s\n' "$gpt_out" | tail -1)"
    [[ "$rootfs_a_bytes" == "$img_bytes" ]] && rootfs_a_bytes=0 # only one line = no rootfs-A found
  fi

  # Fall back to compressed size × 3 if GPT parsing failed.
  if [[ -z "$img_bytes" || "$img_bytes" == "0" ]]; then
    local compressed_mb
    compressed_mb=$(($(stat -c '%s' "$IMG") / 1048576))
    need_mb=$((compressed_mb * 3))
    ((need_mb < 12288)) && need_mb=12288
    log "Could not read GPT header — estimating ${need_mb} MB from compressed size"
  else
    local img_mb=$((img_bytes / 1048576))
    need_mb=$((img_mb + 15360))

    # If ROOTFS_SIZE is set and we found rootfs-A, project the growth.
    if [[ -n "${ROOTFS_SIZE:-}" ]] && ((ROOTFS_SIZE > 0 && rootfs_a_bytes > 0)); then
      local rootfs_a_mib=$((rootfs_a_bytes / 1048576))
      local growth_mib=$((ROOTFS_SIZE - rootfs_a_mib))
      if ((growth_mib > 0)); then
        local growth_mb=$((growth_mib))
        need_mb=$((need_mb + growth_mb))
        log "Decompressed image: ${img_mb} MB, rootfs-A: ${rootfs_a_mib} MiB → ${ROOTFS_SIZE} MiB (+${growth_mb} MB), need ~${need_mb} MB"
      else
        log "Decompressed image: ${img_mb} MB, rootfs-A already ${rootfs_a_mib} MiB, need ~${need_mb} MB"
      fi
    else
      log "Decompressed image: ${img_mb} MB, need ~${need_mb} MB (image + 15 GB headroom)"
    fi
  fi

  if [[ "${WORKDIR_LOCATION:-auto}" == "disk" ]]; then
    ((disk_avail >= need_mb)) || die "Disk only has ${disk_avail} MB free, need ~${need_mb} MB."
    log "Build workspace: disk (forced by config, ${disk_avail} MB free)"
    return 0
  fi

  # Auto: prefer RAM if it has enough headroom, otherwise disk.
  if ((ram_avail >= need_mb)); then
    # RAM is sufficient for the build workspace, but we also need to verify
    # the final destination filesystem has room for the completed image.
    local final_ok=1
    if [[ -n "${OUT_FINAL:-}" && "$OUT" != "$OUT_FINAL" ]]; then
      local final_avail
      final_avail="$(df -m --output=avail "$(dirname "$OUT_FINAL")" | tail -1 | tr -d ' ')"
      if ((final_avail < need_mb)); then
        log "RAM has enough workspace (${ram_avail} MB), but final destination $(dirname "$OUT_FINAL") only has ${final_avail} MB free (need ~${need_mb} MB) — falling back to disk"
        final_ok=0
      fi
    fi
    if ((final_ok)); then
      WORKDIR="/dev/shm/steamos-build"
      OUT="$WORKDIR/$(basename "$OUT")"
      mkdir -p "$WORKDIR" || die "Failed to create work directory: $WORKDIR"
      log "Build workspace: RAM (/dev/shm, ${ram_avail} MB free, need ~${need_mb})"
    elif ((disk_avail >= need_mb)); then
      log "Build workspace: disk (${disk_avail} MB free, final destination needs ~${need_mb} MB)"
    else
      die "Not enough space: RAM=${ram_avail} MB, disk=${disk_avail} MB. Final destination needs ~${need_mb} MB."
    fi
  elif ((disk_avail >= need_mb)); then
    log "Build workspace: disk (${disk_avail} MB free, RAM only ${ram_avail} MB)"
  else
    die "Not enough space: RAM=${ram_avail} MB, disk=${disk_avail} MB. Need ~${need_mb} MB."
  fi
}

# Build/scratch mountpoints used across the whole run.
setup_dirs() {
  log "Creating build directories under $WORKDIR"
  mkdir -p "$MNT" "$EFIMNT" "$HOMEMNT" "$OVLWORK" "$MERGED" \
    || die "Failed to create build directories under $WORKDIR"
  mkdir -p "${OVL_MNT:-$WORKDIR/overlay-mnt}"
  log "  MERGED=$MERGED (exists: $([[ -d "$MERGED" ]] && echo yes || echo no))"
}

setup_udev_guard() {
  if [[ -z "${LOOPDEV:-}" ]]; then
    warn "setup_udev_guard called before LOOPDEV exists; skipping guard"
    return 0
  fi

  mkdir -p /run/udev/rules.d

  local loop_name="${LOOPDEV#/dev/}"

  cat >"$UDEV_RULE" <<EOF
# steamos-build build-loop quarantine.
#
# SteamOS recovery images contain the same GPT PARTUUIDs as the running
# recovery environment.  Never allow partitions belonging to our build loop
# to participate in SteamOS partset discovery.
SUBSYSTEM=="block", KERNEL=="${loop_name}p*", ENV{UDISKS_IGNORE}="1", ENV{SYSTEMD_READY}="0", ENV{ID_PART_ENTRY_UUID}=""
EOF

  udevadm control --reload-rules || warn "Failed to reload udev rules — quarantine may not be active"
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
    *.bz2 | *.gz | *.xz | *.zst)
      _src_fp="$(stat -c '%s:%Y' "$IMG"):$(sha256sum "$IMG" | cut -d' ' -f1)"
      ;;
    *)
      _src_fp="$(stat -c '%s:%Y' "$IMG"):plain"
      ;;
  esac

  # Resume support: if both $OUT and the fingerprint file exist and the
  # stored fingerprint matches the current source, skip decompression.
  # This allows interrupted builds to resume without re-decompressing.
  if [[ -f "$OUT" && -f "$FINGERPRINT_FILE" ]]; then
    local stored_fp
    stored_fp="$(cat "$FINGERPRINT_FILE" 2>/dev/null || true)"
    if [[ "$stored_fp" == "$_src_fp" ]]; then
      log "Resuming from existing working copy (fingerprint matches)"
      return 0
    fi
    log "Source changed (fingerprint mismatch) — removing stale working copy"
    rm -f "$OUT" "$FINGERPRINT_FILE"
  elif [[ -f "$OUT" || -f "$FINGERPRINT_FILE" ]]; then
    # One exists without the other — incomplete state, remove both.
    log "Removing previous incomplete working copy"
    rm -f "$OUT" "$FINGERPRINT_FILE"
  fi

  # Space check: decompressed image is ~8 GB, packages ~0.5 GB.
  # The overlay workspace is a sparse file (doesn't consume upfront).
  _avail_mb="$(df -m --output=avail "$(dirname "$OUT")" | tail -1 | tr -d ' ')"
  if ((_avail_mb < 9216)); then
    die "Not enough disk space: ${_avail_mb} MB free, need ~9 GB. Use --workdir /dev/shm to build in RAM."
  fi

  log "Decompressing $(basename "$IMG") → $(basename "$OUT") (~8 GB, several minutes)"

  # Start decompression in background so we can track progress.
  case "$IMG" in
    *.bz2) bzip2 -dkc "$IMG" >"$OUT" & ;;
    *.gz) gzip -dkc "$IMG" >"$OUT" & ;;
    *.xz) xz -dkc "$IMG" >"$OUT" & ;;
    *.zst) zstd -dkc "$IMG" >"$OUT" & ;;
    *) cp --reflink=auto "$IMG" "$OUT" & ;;
  esac
  local decomp_pid=$!

  # Emit 1% immediately so the bar moves right away.
  printf '%s\n' "@@PROGRESS:1@@"

  # +1% per GB of output, capped at 19% (progress_emit decompress sets 20%).
  local last_pct=1
  while kill -0 "$decomp_pid" 2>/dev/null; do
    local written
    written="$(stat -c '%s' "$OUT" 2>/dev/null || echo 0)"
    local gb=$((written / 1073741824))
    local pct=$((1 + gb))
    if ((pct > last_pct && pct <= 19)); then
      last_pct=$pct
      printf '%s\n' "@@PROGRESS:$pct@@"
    fi
    sleep 2
  done

  wait "$decomp_pid" || die "Decompression failed"

  # Save the fingerprint for next run.
  echo "$_src_fp" >"$FINGERPRINT_FILE"
}

# Attach the output as a loop device and locate the SteamOS partitions.
setup_loop_mount() {
  # Attach the image WITHOUT scanning its partition table yet.
  # We need our udev quarantine rule installed before loopXpN devices appear.
  LOOPDEV="$(losetup -f --show "$OUT")" || die "Failed to attach loop device for $OUT"
  log "Loop device: $LOOPDEV"

  setup_udev_guard

  # Now expose the partitions, with the guard already active.
  partx -a "$LOOPDEV" || die "Failed to register partition devices on $LOOPDEV"
  udevadm settle --timeout=10

  local checked=0 passed=0
  for part in "$LOOPDEV"p*; do
    [[ -b "$part" ]] || continue
    ((++checked))

    local props
    props="$(udevadm info -q property -n "$part" 2>/dev/null)" || true

    if echo "$props" | grep -q 'UDISKS_IGNORE=1' \
      && echo "$props" | grep -q 'SYSTEMD_READY=0'; then
      ((++passed))
    else
      warn "udev quarantine FAILED for $part:"
      echo "$props" \
        | grep -E 'ID_PART_ENTRY_(UUID|NAME)|UDISKS_IGNORE|SYSTEMD_READY' \
        | while IFS="" read -r line; do
          warn "  $line"
        done || true
    fi
  done
  log "udev quarantine: $passed/$checked image partitions protected"

  # A build-loop partition must NEVER own a SteamOS partset link.
  local link target collision=0

  # Check where the currently active by-partsets symlinks resolve.
  while IFS="" read -r link; do
    target="$(readlink -f "$link" 2>/dev/null || true)"
    [[ -n "$target" ]] || continue

    if [[ "$target" == "$LOOPDEV"p* ]]; then
      warn "DANGEROUS partset collision: $link -> $target"
      collision=1
    fi
  done < <(find /dev/disk/by-partsets -type l 2>/dev/null)

  # Also check whether udev thinks any build-loop partition owns a
  # by-partsets DEVLINK, even if that link currently resolves elsewhere.
  for part in "$LOOPDEV"p*; do
    [[ -b "$part" ]] || continue

    if udevadm info -q symlink -n "$part" 2>/dev/null \
      | tr ' ' '\n' \
      | grep -q '^disk/by-partsets/'; then
      warn "DANGEROUS: $part owns a SteamOS partset DEVLINK"
      udevadm info -q symlink -n "$part" >&2 || true
      collision=1
    fi
  done

  ((collision == 0)) \
    || die "Build loop claimed a live SteamOS /dev/disk/by-partsets link; refusing to continue"

  log "Scanning partitions on $LOOPDEV"

  ROOTPART="" EFIPART="" HOMEPART="" VARPART=""
  local _pname=""
  for part in "$LOOPDEV"p*; do
    [[ -b "$part" ]] || {
      warn "No partition devices found on $LOOPDEV — image may be corrupt"
      break
    }
    _pname="$(blkid -p -s PART_ENTRY_NAME -o value "$part" 2>/dev/null)" || true
    log "  $part: ${_pname:-<unknown>}"
    case "$_pname" in
      rootfs-A) ROOTPART="$part" ;;
      efi-A) EFIPART="$part" ;;
      home) HOMEPART="$part" ;;
      # SteamOS exposes this at boot as /dev/disk/by-partsets/self/var.
      # Repair images normally call the A-slot partition var-A; accept var
      # too so the code works with images that use an unsuffixed label.
      var-A | var) VARPART="$part" ;;
    esac
  done
  log "rootfs=$ROOTPART efi=$EFIPART home=$HOMEPART var=${VARPART:-<not found>}"
  [[ -n "$ROOTPART" && -n "$EFIPART" && -n "$HOMEPART" ]] \
    || die "rootfs-A/efi-A/home partitions not found on $LOOPDEV — is this a SteamOS image?"
  [[ -n "$VARPART" ]] \
    || warn "SteamOS var-A/var partition not found; runtime overlay cleanup will be skipped"

  # Diagnostic: check if this is a Btrfs seeding filesystem.
  log "Rootfs superblock flags:"
  btrfs inspect-internal dump-super "$ROOTPART" 2>/dev/null | grep -E 'flags|fsid|metadata_uuid' || true
  log "Inspecting Btrfs FS_TREE root item"
  btrfs inspect-internal dump-tree -t root "$ROOTPART" 2>/dev/null \
    | grep -A12 -B2 'key (FS_TREE ROOT_ITEM 0)' || true
  log "mkfs.btrfs version: $(mkfs.btrfs --version 2>/dev/null || echo 'unknown')"

  # Unmount any stale mounts backed by our loop partition (use the device,
  # not the UUID — cloned images may share UUIDs).
  while IFS="" read -r target; do
    [[ -n "$target" ]] || continue
    strict_unmount "$target" "stale mount backed by $ROOTPART" \
      || die "Cannot unmount stale mount $target"
  done < <(findmnt -rn -o TARGET -S "$ROOTPART" 2>/dev/null || true)
}

# Mount rootfs (btrfs), efi-A, and home.
setup_mount_partitions() {
  log "Loop device RO: $(blockdev --getro "$LOOPDEV")"
  log "Root partition RO: $(blockdev --getro "$ROOTPART")"
  log "Mounting rootfs ($ROOTPART) → $MNT"
  mount -o compress-force=zstd:3 "$ROOTPART" "$MNT" \
    || die "Failed to mount rootfs: $ROOTPART → $MNT"
  track_mount "$MNT"
  log "Mounting efi ($EFIPART) → $EFIMNT"
  mount "$EFIPART" "$EFIMNT" \
    || die "Failed to mount EFI partition: $EFIPART → $EFIMNT"
  track_mount "$EFIMNT"
  log "Mounting home ($HOMEPART) → $HOMEMNT"
  mount "$HOMEPART" "$HOMEMNT" \
    || die "Failed to mount home partition: $HOMEPART → $HOMEMNT"
  track_mount "$HOMEMNT"

  log "Rootfs mount options: $(findmnt -no OPTIONS "$MNT")"

  # Don't continue unless an actual write succeeds.
  local rw_test="$MNT/.steamos-build-rw-test"
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
}

# Discover the neptune kernel, its installed pacman package, and the
# exact-match headers URL from Valve's pool.
setup_discover() {
  discover_neptune_kver "$MNT"
  log "Image kernel: $KVER"

  discover_kernel_pkg "$MNT"
  log "Kernel package: $KPKG_NAME $KPKG_VERREL"

  construct_hdr_url "$MNT"
  curl_retry 3 -sfIL "$HDR_URL" -o /dev/null \
    || die "Exact-match headers not found in Valve's pool: $HDR_URL"
  log "Headers package: $(basename "$HDR_URL")"
}
