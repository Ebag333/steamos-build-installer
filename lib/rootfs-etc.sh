#!/bin/bash
#
# steamos-build-installer — lib/rootfs-etc.sh
# Btrfs rootfs rebuild and /etc overlay management.
#
# Handles two writable-rootfs strategies: a native in-place Btrfs ro-property
# transition (preferred, preserves original Btrfs topology) and a legacy
# mkfs.btrfs rebuild fallback (produces a writable rootfs but uses its own
# data/metadata profiles rather than preserving the source's).
# Also manages /etc overlay preservation for the rebuild path and mounts the
# effective /etc for initramfs configuration work.
#
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/rootfs-etc.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ── Internal helpers ────────────────────────────────────────────────────────

# Query the FS_TREE ROOT_ITEM flags from a Btrfs partition.
# Args: $1 = block device
# Prints the flags line; callers check for "(RDONLY)".
query_btrfs_root_item() {
  btrfs inspect-internal dump-tree -t root "${1:?}" 2>/dev/null \
    | awk '
      /key \(FS_TREE ROOT_ITEM 0\)/ { found=1 }
      found && /flags / { print; exit }
    '
}

# Collect blkid identity for a block device into globals.
# Args: $1 = block device
# Sets: PIDENT_UUID, PIDENT_UUID_SUB, PIDENT_LABEL, PIDENT_PARTUUID
collect_partition_identity() {
  local dev="${1:?collect_partition_identity: missing device}"
  # shellcheck disable=SC2034
  PIDENT_UUID="$(blkid -s UUID -o value "$dev")"
  # shellcheck disable=SC2034
  PIDENT_UUID_SUB="$(blkid -s UUID_SUB -o value "$dev" || true)"
  # shellcheck disable=SC2034
  PIDENT_LABEL="$(blkid -s LABEL -o value "$dev" || true)"
  # shellcheck disable=SC2034
  PIDENT_PARTUUID="$(blkid -s PARTUUID -o value "$dev" || true)"
}

# Parse sgdisk partition info into globals.
# Args: $1 = partition number, $2 = disk device
# Sets: SGDINFO_START (first sector), SGDINFO_SIZE (sectors),
#        SGDINFO_TYPE_GUID, SGDINFO_PARTUUID, SGDINFO_NAME
sgdisk_partition_info() {
  local pnum="${1:?}" disk="${2:?}"
  local raw
  raw="$(sgdisk -i "$pnum" "$disk" 2>/dev/null)"
  # shellcheck disable=SC2034
  SGDINFO_START="$(printf '%s\n' "$raw" | sed -n 's/^First sector: *\([0-9][0-9]*\).*/\1/p')"
  # shellcheck disable=SC2034
  SGDINFO_SIZE="$(printf '%s\n' "$raw" | sed -n 's/^Partition size: *\([0-9][0-9]*\) sectors.*/\1/p')"
  # shellcheck disable=SC2034
  SGDINFO_TYPE_GUID="$(printf '%s\n' "$raw" | sed -n 's/^Partition GUID code: *\([0-9a-fA-F-]*\).*/\1/p')"
  # shellcheck disable=SC2034
  SGDINFO_PARTUUID="$(printf '%s\n' "$raw" | sed -n 's/^Partition unique GUID: *\([0-9a-fA-F-]*\).*/\1/p')"
  # shellcheck disable=SC2034
  SGDINFO_NAME="$(printf '%s\n' "$raw" | sed -n "s/^Partition name: *'\(.*\)'$/\1/p")"
}

# Extract UUID, Parent UUID, and Received UUID from a mounted Btrfs subvolume.
# Args: $1 = mountpoint
# Sets: SUBVOL_UUID, SUBVOL_PARENT_UUID, SUBVOL_RECEIVED_UUID (or "-" if empty)
collect_subvolume_uuids() {
  local mnt="${1:?collect_subvolume_uuids: missing mountpoint}" show
  show="$(btrfs subvolume show "$mnt" 2>/dev/null || true)"
  SUBVOL_UUID="$(
    printf '%s\n' "$show" | sed -n 's/^[[:space:]]*UUID:[[:space:]]*//p' | head -n1
  )"
  SUBVOL_PARENT_UUID="$(
    printf '%s\n' "$show" | sed -n 's/^[[:space:]]*Parent UUID:[[:space:]]*//p' | head -n1
  )"
  SUBVOL_RECEIVED_UUID="$(
    printf '%s\n' "$show" | sed -n 's/^[[:space:]]*Received UUID:[[:space:]]*//p' | head -n1
  )"
  [[ -n "$SUBVOL_UUID" ]] || SUBVOL_UUID="-"
  [[ -n "$SUBVOL_PARENT_UUID" ]] || SUBVOL_PARENT_UUID="-"
  [[ -n "$SUBVOL_RECEIVED_UUID" ]] || SUBVOL_RECEIVED_UUID="-"
}

# Print the raw Btrfs device size for a mounted filesystem.
# Args: $1 = mountpoint
get_btrfs_device_size() {
  btrfs filesystem show --raw "$1" 2>/dev/null \
    | awk '
      $1 == "devid" {
        for (i = 1; i <= NF; i++) {
          if ($i == "size") { print $(i + 1); exit }
        }
      }
    '
}

# Log Btrfs details that may explain behavior differences between the stock
# repair image and the reconstructed rootfs.  Diagnostics are intentionally
# non-fatal: failure to query one property must not abort the build.
# Args: $1 = mounted Btrfs root path, $2 = human-readable label
log_rootfs_btrfs_diagnostics() {
  local root="${1:?log_rootfs_btrfs_diagnostics: missing root}"
  local label="${2:-rootfs}"

  debug_cmd findmnt -T "$root" -o TARGET,SOURCE,FSTYPE,OPTIONS \
    >>"${BTRFS_DEBUG_LOG}" 2>&1 || true

  debug_cmd btrfs filesystem usage -T "$root" \
    >>"${BTRFS_DEBUG_LOG}" 2>&1 || true

  debug_cmd btrfs subvolume list "$root" \
    >>"${BTRFS_DEBUG_LOG}" 2>&1 || true

  log "$label: default subvolume"
  btrfs subvolume get-default "$root" >&2 || true

  debug_cmd btrfs subvolume show "$root" \
    >>"${BTRFS_DEBUG_LOG}" 2>&1 || true

  log "$label: read-only property"
  btrfs property get -ts "$root" ro >&2 || true
}

# Save the *effective* /etc before rebuilding rootfs.
# This reads through the existing SteamOS overlay so we preserve its
# configuration, whiteouts, replacements, symlinks, etc. semantically,
# without copying OverlayFS's internal metadata.
#
# Args: $1 = path to the current (old) rootfs mount (e.g. $srcmnt)
# Sets: ETC_SNAPSHOT_VALID=1 if a snapshot was taken
snapshot_runtime_etc() {
  local src_root="${1:?snapshot_runtime_etc: missing source root}"

  ETC_SNAPSHOT_VALID=0
  ETC_SNAPSHOT="$WORKDIR/etc-effective"
  ETC_VAR_MNT="$WORKDIR/etc-var-mnt"
  ETC_MERGED="$WORKDIR/etc-merged"

  rm -rf "$ETC_SNAPSHOT"
  mkdir -p "$ETC_SNAPSHOT" "$ETC_VAR_MNT" "$ETC_MERGED"

  # Defensive: clean stale mounts from a prior interrupted run.
  ensure_unmounted "$ETC_MERGED" "stale /etc overlay"
  ensure_unmounted "$ETC_VAR_MNT" "stale var mount"

  [[ -n "${VARPART:-}" && -b "$VARPART" ]] || {
    warn "No var partition; cannot snapshot runtime /etc overlay"
    return 0
  }

  log "Mounting $VARPART to inspect the existing runtime /etc overlay"
  mount -o rw "$VARPART" "$ETC_VAR_MNT" \
    || die "Failed to mount SteamOS var partition"

  local ovl="$ETC_VAR_MNT/lib/overlays/etc"
  local upper="$ovl/upper"
  local work="$ovl/work"

  log "Runtime /etc overlay paths:"
  log "  overlay root: $ovl"
  log "  upper: $upper"
  log "  work:  $work"

  if [[ ! -d "$upper" && ! -d "$work" ]]; then
    log "No existing runtime /etc overlay to preserve; using lower-only /etc"
    strict_unmount "$ETC_VAR_MNT" "var after /etc overlay check" \
      || die "Failed to unmount var after /etc overlay check"
    return 0
  fi

  if [[ ! -d "$upper" || ! -d "$work" ]]; then
    local upper_state="missing" work_state="missing"
    [[ -d "$upper" ]] && upper_state="present"
    [[ -d "$work" ]] && work_state="present"
    strict_unmount "$ETC_VAR_MNT" "var after incomplete /etc overlay check" \
      || die "Failed to unmount var after incomplete /etc overlay check"
    die "Incomplete SteamOS /etc overlay state (upper=$upper_state, work=$work_state)"
  fi

  log "Existing /etc upper:"
  count_dir_entries "$upper"

  log "Potentially relevant files in the original /etc upper:"
  find "$upper" -mindepth 1 -printf '%P\n' 2>/dev/null \
    | grep -Ei '(^|/)(steam|steamos|oobe|rauc|atom|mkinit|modprobe|systemd|network|fstab|os-release)' \
    | sort \
    | sed 's/^/  /' >&2 || true

  log "Snapshotting effective runtime /etc"

  if ! mount -t overlay overlay \
    -o "lowerdir=$src_root/etc,upperdir=$upper,workdir=$work" \
    "$ETC_MERGED"; then
    strict_unmount "$ETC_VAR_MNT" "var after failed /etc overlay mount" || true
    die "Failed to mount original /etc overlay"
  fi

  log "Original effective /etc mount:"
  findmnt -T "$ETC_MERGED" -o TARGET,SOURCE,FSTYPE,OPTIONS >&2 || true

  # Verify the snapshot itself before destroying the old lower filesystem.
  # --checksum is cheap for /etc and catches same-size/same-mtime content drift.
  rsync_verified "$ETC_MERGED/" "$ETC_SNAPSHOT/" "snapshot effective /etc" \
    "$ETC_MERGED" "$ETC_VAR_MNT"

  log "Effective /etc snapshot verified:"
  count_dir_entries "$ETC_SNAPSHOT"

  strict_unmount "$ETC_MERGED" "original /etc overlay" \
    || die "Failed to unmount original /etc overlay"

  strict_unmount "$ETC_VAR_MNT" "var after /etc snapshot" \
    || die "Failed to unmount var after /etc snapshot"

  ETC_SNAPSHOT_VALID=1
}

# Rebuild the /etc overlay against the NEW rootfs.
# The old upper/work metadata refers to the old Btrfs inode/file handles,
# so recreate the overlay and replay the effective /etc through OverlayFS.
restore_runtime_etc() {
  [[ "${ETC_SNAPSHOT_VALID:-0}" == 1 ]] || {
    log "No runtime /etc snapshot to restore"
    return 0
  }

  [[ -n "${VARPART:-}" && -b "$VARPART" ]] \
    || die "Runtime /etc snapshot exists but no var partition is available for restore"

  local rootmnt="$WORKDIR/etc-new-root"
  local varmnt="$WORKDIR/etc-var-mnt"
  local merged="$WORKDIR/etc-merged"

  mkdir -p "$rootmnt" "$varmnt" "$merged"

  # Defensive: clean stale mounts from a prior interrupted run.
  ensure_unmounted "$merged" "stale rebuilt /etc overlay"
  ensure_unmounted "$rootmnt" "stale rootfs mount"
  ensure_unmounted "$varmnt" "stale var mount"

  mount -o ro "$ROOTPART" "$rootmnt" \
    || die "Failed to mount rebuilt rootfs"

  if ! mount -o rw "$VARPART" "$varmnt"; then
    strict_unmount "$rootmnt" "rebuilt rootfs after failed var mount" || true
    die "Failed to mount SteamOS var partition"
  fi

  local ovl="$varmnt/lib/overlays/etc"
  local upper="$ovl/upper"
  local work="$ovl/work"

  log "Recreating runtime /etc overlay"
  log "  lower: $rootmnt/etc"
  log "  overlay root: $ovl"
  log "  upper: $upper"
  log "  work:  $work"

  if [[ -d "$ovl" ]]; then
    log "Preserving non-upper/work entries under the /etc overlay root:"
    find "$ovl" -mindepth 1 -maxdepth 1 \
      ! -name upper ! -name work -printf '  %f\n' 2>/dev/null | sort >&2 || true
  fi

  # Discard only the OverlayFS upper/work state that refers to the old lower.
  # Preserve unknown sibling metadata Valve may keep under lib/overlays/etc.
  rm -rf "$upper" "$work" \
    || die "Failed to remove stale runtime /etc upper/work state"
  mkdir -p "$upper" "$work"

  if ! mount -t overlay overlay \
    -o "lowerdir=$rootmnt/etc,upperdir=$upper,workdir=$work" \
    "$merged"; then
    strict_unmount "$varmnt" "var after failed rebuilt /etc overlay mount" || true
    strict_unmount "$rootmnt" "rebuilt rootfs after failed /etc overlay mount" || true
    die "Failed to mount fresh /etc overlay"
  fi

  log "Fresh effective /etc mount:"
  findmnt -T "$merged" -o TARGET,SOURCE,FSTYPE,OPTIONS >&2 || true

  # Replay the old effective filesystem through the NEW overlay.
  # --delete is important: if the stock upper contained a whiteout for a
  # lower file, rsync removing that file through the mounted overlay causes
  # OverlayFS to create a new valid whiteout.
  rsync_verified "$ETC_SNAPSHOT/" "$merged/" "rebuild runtime /etc" \
    "$merged" "$varmnt" "$rootmnt"

  log "Runtime /etc snapshot verified"
  log "Rebuilt /etc upper:"
  count_dir_entries "$upper"

  sync

  strict_unmount "$merged" "rebuilt /etc overlay" \
    || die "Failed to unmount rebuilt /etc overlay"

  strict_unmount "$varmnt" "var after rebuilt /etc overlay" \
    || die "Failed to unmount var"

  strict_unmount "$rootmnt" "rebuilt rootfs after /etc overlay restore" \
    || die "Failed to unmount rebuilt rootfs"

  rm -rf "$ETC_SNAPSHOT"
  rmdir "$merged" "$varmnt" "$rootmnt" 2>/dev/null || true

  ETC_SNAPSHOT_VALID=0
  log "Runtime /etc overlay rebuilt successfully"
}

# Legacy/fallback method: rebuild the SteamOS rootfs as a new writable Btrfs
# filesystem using mkfs.btrfs --rootdir.  This remains available for A/B
# testing against the native in-place method below.
prepare_writable_rootfs_rebuild() {
  local root_item root_bytes root_uuid root_dev_uuid root_label
  local srcmnt root_tmp new_bytes

  root_item="$(query_btrfs_root_item "$ROOTPART")"

  log "Detected FS_TREE root item: ${root_item:-<not found>}"

  [[ -n "$root_item" ]] \
    || die "Could not read FS_TREE root item from $ROOTPART"

  if [[ "$root_item" != *"(RDONLY)"* ]]; then
    log "Rootfs FS_TREE is already writable; preserving the original filesystem and overlay state"
    log "No rootfs-internal overlay cleanup is performed on the already-writable path"
    return 0
  fi

  log "Rootfs FS_TREE is RDONLY — rebuilding as writable Btrfs"

  srcmnt="$WORKDIR/rootfs-ro-source"
  root_tmp="$WORKDIR/rootfs-writable.img"

  mkdir -p "$srcmnt"
  ensure_unmounted "$srcmnt" "stale rootfs source mount"
  rm -f "$root_tmp"

  root_bytes="$(blockdev --getsize64 "$ROOTPART")"
  collect_partition_identity "$ROOTPART"
  local root_uuid="$PIDENT_UUID"
  local root_dev_uuid="$PIDENT_UUID_SUB"
  local root_label="$PIDENT_LABEL"

  log "Original rootfs identity:"
  log "  Size: $root_bytes bytes"
  log "  UUID: $root_uuid"
  log "  Device UUID: ${root_dev_uuid:-<none>}"
  log "  Label: ${root_label:-<none>}"

  # Source stays completely untouched.
  mount -o ro "$ROOTPART" "$srcmnt" \
    || die "Failed to mount original rootfs read-only"

  log_rootfs_btrfs_diagnostics "$srcmnt" "Original rootfs"

  log "Original rootfs disk usage:"
  debug_cmd du -sh "$srcmnt" >&2 || true
  debug_cmd du -sh --apparent-size "$srcmnt" >&2 || true

  # Snapshot the effective /etc BEFORE mkfs destroys the old lower filesystem.
  snapshot_runtime_etc "$srcmnt"

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

  [[ -n "$root_label" ]] \
    && mkfs_args+=(-L "$root_label")

  [[ -n "$root_dev_uuid" ]] \
    && mkfs_args+=(--device-uuid "$root_dev_uuid")

  log "Creating writable replacement filesystem"
  log "  mkfs.btrfs args: ${mkfs_args[*]} $root_tmp"
  if ! mkfs.btrfs "${mkfs_args[@]}" "$root_tmp"; then
    strict_unmount "$srcmnt" "original rootfs after failed rebuild" || true
    die "Failed to rebuild writable Btrfs rootfs"
  fi

  # The replacement intentionally reuses the original Btrfs identity.
  # Never expose it to Btrfs while the original filesystem is mounted.
  strict_unmount "$srcmnt" "original rootfs source" \
    || die "Failed to unmount original rootfs source"

  # mkfs.btrfs --rootdir copies any hidden /var/lib/overlays state contained
  # in rootfs-A.  When a separate SteamOS var partition exists, runtime state
  # lives there and the hidden rootfs copy must not survive reconstruction.
  # Without a verified VARPART, preserve it rather than guessing.
  if [[ -n "${VARPART:-}" && -b "$VARPART" ]]; then
    log "Clearing hidden rootfs-internal overlay state from rebuilt filesystem"
    local ovl_tmp="$WORKDIR/ovl-clean-mnt"
    mkdir -p "$ovl_tmp"
    ensure_unmounted "$ovl_tmp" "stale rebuilt-root overlay cleanup mount"
    mount -o loop "$root_tmp" "$ovl_tmp" \
      || die "Failed to mount rebuilt rootfs for overlay cleanup"
    clean_overlay_state "$ovl_tmp"
    strict_unmount "$ovl_tmp" "rebuilt rootfs overlay cleanup" \
      || die "Failed to unmount rebuilt rootfs after overlay cleanup"
    rmdir "$ovl_tmp" 2>/dev/null || true
  else
    warn "No verified var partition; preserving any rootfs-internal /var/lib/overlays state"
  fi

  new_bytes="$(stat -c '%s' "$root_tmp")"
  log "Rebuilt rootfs image size: $new_bytes bytes (partition: $root_bytes bytes)"
  if ((new_bytes > root_bytes)); then
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

  # --shrink trimmed the image to minimum size; expand back to fill the partition.
  if ((new_bytes < root_bytes)); then
    log "Expanding rebuilt rootfs to fill partition (${new_bytes} → ${root_bytes} bytes)"
    local resize_mnt="$WORKDIR/rootfs-resize"
    mkdir -p "$resize_mnt"
    ensure_unmounted "$resize_mnt" "stale rootfs resize mount"
    mount -o compress-force=zstd:3 "$ROOTPART" "$resize_mnt" \
      || die "Failed to mount rebuilt rootfs for resize"
    if ! btrfs filesystem resize max "$resize_mnt"; then
      strict_unmount "$resize_mnt" "rebuilt rootfs after failed resize" || true
      die "Failed to expand rebuilt rootfs to fill partition"
    fi
    strict_unmount "$resize_mnt" "rebuilt rootfs resize mount" \
      || die "Failed to unmount rebuilt rootfs after resize"
    rmdir "$resize_mnt" 2>/dev/null || true
  fi

  # Rebuilding the lower rootfs invalidates OverlayFS origin/file-handle state
  # stored on SteamOS's separate /var partition.  Snapshot the effective /etc
  # before the rebuild and replay it through a fresh overlay afterward, so
  # configuration is preserved without carrying stale OverlayFS metadata.
  restore_runtime_etc

  # Offline verification before proceeding.
  root_item="$(query_btrfs_root_item "$ROOTPART")"

  log "Rebuilt FS_TREE: ${root_item:-<not found>}"

  [[ "$root_item" != *"(RDONLY)"* ]] \
    || die "Rebuilt rootfs is unexpectedly still RDONLY"

  local diag_mnt="$WORKDIR/rootfs-post-rebuild-diag"
  mkdir -p "$diag_mnt"
  ensure_unmounted "$diag_mnt" "stale post-rebuild diagnostic mount"
  if mount -o ro "$ROOTPART" "$diag_mnt"; then
    log_rootfs_btrfs_diagnostics "$diag_mnt" "Rebuilt rootfs"
    strict_unmount "$diag_mnt" "post-rebuild diagnostic rootfs" \
      || die "Failed to unmount post-rebuild diagnostic rootfs"
  else
    warn "Could not mount rebuilt rootfs for post-rebuild diagnostics"
  fi
  rmdir "$diag_mnt" 2>/dev/null || true
}

# Preferred/native method: make the existing top-level SteamOS Btrfs subvolume
# writable in place by clearing its ro property.  Unlike the rebuild method,
# this does not create a new filesystem, copy files, rewrite the partition, or
# recreate the runtime /etc OverlayFS.  The original Btrfs topology, inode
# identities, filesystem UUID/device UUID, and Valve's existing overlay state
# remain in place.
#
# The top-level Btrfs subvolume is always subvolid=5.  Mount it explicitly so a
# non-default subvolume can never cause us to change the wrong tree.  The Btrfs
# ro property is backed by BTRFS_IOC_SUBVOL_GETFLAGS/SETFLAGS; the kernel accepts
# the ioctl on a subvolume-root inode (256), including the top-level FS_TREE.
#
# A received read-only subvolume requires `btrfs property set -f` when changing
# ro=true -> ro=false.  btrfs-progs resets received_uuid in that case by design.
# We log that transition prominently because it is the only expected metadata
# identity change in this method.
#
# Args: none
prepare_writable_rootfs_native() {
  local root_item mnt rootid
  local ro_before ro_after
  local default_before default_after etc_stat_before etc_stat_after
  local write_test

  [[ -n "${ROOTPART:-}" && -b "$ROOTPART" ]] \
    || die "prepare_writable_rootfs_native: ROOTPART is not a block device"

  root_item="$(query_btrfs_root_item "$ROOTPART")"

  log "Native writable-rootfs method selected"
  log "Detected FS_TREE root item: ${root_item:-<not found>}"

  [[ -n "$root_item" ]] \
    || die "Could not read FS_TREE root item from $ROOTPART"

  # Preserve the exact behavior of the legacy method for an already-writable
  # image: do nothing to the filesystem or its overlay state.
  if [[ "$root_item" != *"(RDONLY)"* ]]; then
    log "Rootfs FS_TREE is already writable; no conversion required"
    return 0
  fi

  mnt="$WORKDIR/rootfs-native-rw"
  mkdir -p "$mnt"

  ensure_unmounted "$mnt" "stale native rootfs mount"

  collect_partition_identity "$ROOTPART"
  local root_uuid="$PIDENT_UUID"
  local root_dev_uuid="$PIDENT_UUID_SUB"
  local root_label="$PIDENT_LABEL"
  local root_partuuid="$PIDENT_PARTUUID"

  log "Native rootfs identity before conversion:"
  log "  partition: $ROOTPART"
  log "  UUID: $root_uuid"
  log "  Device UUID: ${root_dev_uuid:-<none>}"
  log "  Label: ${root_label:-<none>}"
  log "  PARTUUID: ${root_partuuid:-<none>}"

  # Compact superblock fingerprint for before/after comparison.
  local super_before
  super_before="$(btrfs inspect-internal dump-super "$ROOTPART" 2>/dev/null \
    | grep -E '^(magic|generation|flags|root |total_bytes|bytes_used|nodesize|sectorsize|fsid|dev_item\.fsid)' \
    | sort)" || true
  debug_cmd log "Native rootfs superblock before conversion:"
  debug_cmd printf '%s\n' "$super_before" >&2

  # A read-only subvolume can still live on a filesystem mounted rw.  The
  # subvolume ro property is what rejects writes, so mount the top-level tree
  # explicitly and change that property through Btrfs itself.
  mount -o rw,subvolid=5 "$ROOTPART" "$mnt" \
    || die "Failed to mount top-level rootfs subvolume for native conversion"

  rootid="$(btrfs inspect-internal rootid "$mnt" 2>/dev/null || true)"
  log "Mounted native conversion rootid: ${rootid:-<unknown>}"
  if [[ "$rootid" != "5" ]]; then
    strict_unmount "$mnt" "native rootfs after unexpected rootid" || true
    die "Native rootfs conversion mounted rootid ${rootid:-unknown}, expected 5"
  fi

  log_rootfs_btrfs_diagnostics "$mnt" "Original rootfs (native method)"

  if ! ro_before="$(btrfs property get -ts "$mnt" ro 2>&1)"; then
    strict_unmount "$mnt" "native rootfs after failed ro-property query" || true
    die "Could not read rootfs Btrfs ro property: $ro_before"
  fi
  log "Native rootfs property before conversion: $ro_before"

  collect_subvolume_uuids "$mnt"
  local subvol_uuid_before="$SUBVOL_UUID"
  local parent_uuid_before="$SUBVOL_PARENT_UUID"
  local received_before="$SUBVOL_RECEIVED_UUID"
  log "Native rootfs subvolume UUID before conversion: $subvol_uuid_before"
  log "Native rootfs parent UUID before conversion: $parent_uuid_before"
  log "Native rootfs received UUID before conversion: $received_before"

  default_before="$(
    btrfs subvolume get-default "$mnt" 2>/dev/null \
      | awk '$1 == "ID" { print $2; exit }' || true
  )"
  log "Native rootfs default subvolume ID before conversion: ${default_before:-<unknown>}"

  etc_stat_before="$(stat -Lc 'dev=%d inode=%i mode=%f uid=%u gid=%g' "$mnt/etc" 2>/dev/null || true)"
  log "Native rootfs /etc identity before conversion: ${etc_stat_before:-<unavailable>}"

  # If the property already claims writable despite the offline FS_TREE flag,
  # do not blindly force another metadata transition.  Test actual writability
  # first; if it still fails, stop with diagnostics rather than guessing.
  if [[ "$ro_before" == *"ro=false"* ]]; then
    warn "FS_TREE reports RDONLY but btrfs property reports ro=false; testing actual writability"
  else
    log "Clearing top-level Btrfs ro property in place"

    if [[ "$received_before" != "-" ]]; then
      warn "Rootfs has received_uuid=$received_before"
      warn "Changing a received subvolume to writable requires --force and will reset received_uuid"
      if ! btrfs property set -f -ts "$mnt" ro false; then
        strict_unmount "$mnt" "native rootfs after failed forced ro transition" || true
        die "Failed to clear rootfs ro property with received_uuid reset"
      fi
    else
      if ! btrfs property set -ts "$mnt" ro false; then
        strict_unmount "$mnt" "native rootfs after failed ro transition" || true
        die "Failed to clear rootfs ro property in place"
      fi
    fi
  fi

  if ! ro_after="$(btrfs property get -ts "$mnt" ro 2>&1)"; then
    strict_unmount "$mnt" "native rootfs after failed post-change ro query" || true
    die "Could not verify rootfs ro property after conversion: $ro_after"
  fi
  log "Native rootfs property after conversion: $ro_after"

  if [[ "$ro_after" != *"ro=false"* ]]; then
    strict_unmount "$mnt" "native rootfs after ro-property verification failure" || true
    die "Native conversion did not produce ro=false"
  fi

  # A property report alone is not enough.  Prove a real create+unlink works
  # through the same top-level tree that the finished image will use.
  write_test="$mnt/.steamos-build-native-rw-test.$$"
  if ! touch "$write_test" 2>/dev/null; then
    log "Native rootfs mount after failed write test:"
    findmnt -T "$mnt" -o TARGET,SOURCE,FSTYPE,OPTIONS >&2 || true
    log "Recent Btrfs kernel messages:"
    dmesg | grep -i btrfs | tail -50 >&2 || true
    strict_unmount "$mnt" "native rootfs after failed write test" || true
    die "Rootfs ro property is false but an actual write still failed"
  fi
  rm -f "$write_test" \
    || die "Native rootfs write test succeeded but cleanup failed"
  log "Native rootfs write test: success"

  sync -f "$mnt" 2>/dev/null || sync

  collect_subvolume_uuids "$mnt"
  local subvol_uuid_after="$SUBVOL_UUID"
  local parent_uuid_after="$SUBVOL_PARENT_UUID"
  local received_after="$SUBVOL_RECEIVED_UUID"

  log "Native rootfs subvolume UUID after conversion: $subvol_uuid_after"
  log "Native rootfs parent UUID after conversion: $parent_uuid_after"
  log "Native rootfs received UUID after conversion: $received_after"

  [[ "$subvol_uuid_after" == "$subvol_uuid_before" ]] || {
    strict_unmount "$mnt" "native rootfs after subvolume UUID change" || true
    die "Native conversion unexpectedly changed the root subvolume UUID"
  }
  [[ "$parent_uuid_after" == "$parent_uuid_before" ]] || {
    strict_unmount "$mnt" "native rootfs after parent UUID change" || true
    die "Native conversion unexpectedly changed the root subvolume parent UUID"
  }

  if [[ "$received_before" != "$received_after" ]]; then
    if [[ "$received_before" != "-" && "$received_after" == "-" ]]; then
      warn "Native conversion cleared received_uuid as expected for forced ro->rw: $received_before -> -"
    else
      strict_unmount "$mnt" "native rootfs after unexpected received UUID change" || true
      die "Native conversion unexpectedly changed received_uuid: $received_before -> $received_after"
    fi
  fi

  default_after="$(
    btrfs subvolume get-default "$mnt" 2>/dev/null \
      | awk '$1 == "ID" { print $2; exit }' || true
  )"
  log "Native rootfs default subvolume ID after conversion: ${default_after:-<unknown>}"
  if [[ -n "$default_before" && -n "$default_after" && "$default_before" != "$default_after" ]]; then
    strict_unmount "$mnt" "native rootfs after default-subvolume change" || true
    die "Native conversion unexpectedly changed the default Btrfs subvolume"
  fi

  etc_stat_after="$(stat -Lc 'dev=%d inode=%i mode=%f uid=%u gid=%g' "$mnt/etc" 2>/dev/null || true)"
  log "Native rootfs /etc identity after conversion: ${etc_stat_after:-<unavailable>}"
  if [[ -n "$etc_stat_before" && -n "$etc_stat_after" && "$etc_stat_before" != "$etc_stat_after" ]]; then
    warn "Native conversion changed /etc stat identity:"
    warn "  before: $etc_stat_before"
    warn "  after:  $etc_stat_after"
  fi

  log_rootfs_btrfs_diagnostics "$mnt" "Writable rootfs (native method)"

  strict_unmount "$mnt" "native writable rootfs" \
    || die "Failed to unmount rootfs after native conversion"
  rmdir "$mnt" 2>/dev/null || true

  udevadm settle

  # Verify the on-disk root item after the transaction has been committed and
  # the filesystem is unmounted.  This directly checks the condition that made
  # the stock image unwritable in the first place.
  root_item="$(query_btrfs_root_item "$ROOTPART")"
  log "Native post-conversion FS_TREE: ${root_item:-<not found>}"

  if [[ -z "$root_item" ]]; then
    die "Could not verify FS_TREE root item after native conversion"
  fi
  [[ "$root_item" != *"(RDONLY)"* ]] \
    || die "Native conversion completed but FS_TREE is still RDONLY"

  # The native method should preserve the filesystem's block-level identity.
  collect_partition_identity "$ROOTPART"
  local after_uuid="$PIDENT_UUID"
  local after_dev_uuid="$PIDENT_UUID_SUB"
  local after_label="$PIDENT_LABEL"
  local after_partuuid="$PIDENT_PARTUUID"

  log "Native rootfs identity after conversion:"
  log "  UUID: $after_uuid"
  log "  Device UUID: ${after_dev_uuid:-<none>}"
  log "  Label: ${after_label:-<none>}"
  log "  PARTUUID: ${after_partuuid:-<none>}"

  [[ "$after_uuid" == "$root_uuid" ]] \
    || die "Native conversion unexpectedly changed filesystem UUID"
  [[ "$after_dev_uuid" == "$root_dev_uuid" ]] \
    || die "Native conversion unexpectedly changed device UUID"
  [[ "$after_label" == "$root_label" ]] \
    || die "Native conversion unexpectedly changed filesystem label"
  [[ "$after_partuuid" == "$root_partuuid" ]] \
    || die "Native conversion unexpectedly changed PARTUUID"

  # Compare superblock fingerprints.
  local super_after
  super_after="$(btrfs inspect-internal dump-super "$ROOTPART" 2>/dev/null \
    | grep -E '^(magic|generation|flags|root |total_bytes|bytes_used|nodesize|sectorsize|fsid|dev_item\.fsid)' \
    | sort)" || true
  debug_cmd log "Native rootfs superblock after conversion:"
  debug_cmd printf '%s\n' "$super_after" >&2

  if [[ "$super_before" != "$super_after" ]]; then
    debug_cmd log "Native rootfs superblock diff (expected: generation may change):"
    debug_cmd diff <(printf '%s\n' "$super_before") <(printf '%s\n' "$super_after") >&2 || true
  else
    debug_cmd log "Native rootfs superblock: identical"
  fi

  log "Native writable-rootfs conversion completed without rebuilding the filesystem"
}

# Prepare the recovery image so rootfs-A is exactly ROOTFS_SIZE.
# Extends the raw image, relocates trailing partitions, and grows rootfs-A.
# Must be called after setup_loop_mount (LOOPDEV, ROOTPART, etc. must exist).
#
# Args: $1 = requested rootfs size in MiB
# Sets: ROOTFS_GROWTH_BYTES, PROJECTED_IMAGE_BYTES
prepare_image_rootfs_size() {
  local requested_mib="${1:?prepare_image_rootfs_size: missing size}"

  [[ -n "${LOOPDEV:-}" && -b "${LOOPDEV:-}" ]] \
    || die "prepare_image_rootfs_size: LOOPDEV is not set or not a block device"
  [[ -n "${ROOTPART:-}" && -b "${ROOTPART:-}" ]] \
    || die "prepare_image_rootfs_size: ROOTPART is not set or not a block device"
  command -v sgdisk >/dev/null 2>&1 \
    || die "sgdisk not found — install gptfdisk"
  command -v sfdisk >/dev/null 2>&1 \
    || die "sfdisk not found — install util-linux"
  command -v partx >/dev/null 2>&1 \
    || die "partx not found — install util-linux"

  : >"$PARTITION_DEBUG_LOG"

  # ── 1. Capture original geometry ──────────────────────────────────────

  local disk_guid image_bytes logical_sector
  disk_guid="$(
    sgdisk -p "$LOOPDEV" 2>/dev/null \
      | sed -n 's/^Disk identifier (GUID):[[:space:]]*//p'
  )"
  [[ -n "$disk_guid" ]] \
    || die "Could not read GPT disk GUID from $LOOPDEV"
  image_bytes="$(blockdev --getsize64 "$LOOPDEV")"
  logical_sector="$(blockdev --getss "$LOOPDEV")"

  ROOTFS_GROWTH_BYTES=0
  PROJECTED_IMAGE_BYTES="$image_bytes"

  # Find rootfs-A by GPT partition name.
  local root_partnum root_start root_size_sectors root_partuuid
  local root_type_guid root_fs_uuid
  local part
  for part in "$LOOPDEV"p*; do
    [[ -b "$part" ]] || continue
    local pnum="${part##*p}"
    sgdisk_partition_info "$pnum" "$LOOPDEV"
    if [[ "$SGDINFO_NAME" == "rootfs-A" ]]; then
      root_partnum="$pnum"
      root_start="$SGDINFO_START"
      root_size_sectors="$SGDINFO_SIZE"
      root_type_guid="$SGDINFO_TYPE_GUID"
      root_partuuid="$SGDINFO_PARTUUID"
      # FS UUID comes from the Btrfs superblock, not the GPT.
      root_fs_uuid="$(blkid -s UUID -o value "$part" 2>/dev/null)" \
        || die "Could not read Btrfs UUID from $part"
      break
    fi
  done

  [[ -n "$root_partnum" ]] \
    || die "rootfs-A partition not found on $LOOPDEV"
  [[ -n "$root_start" && -n "$root_size_sectors" ]] \
    || die "Could not read rootfs-A geometry from sgdisk (start=$root_start size=$root_size_sectors)"

  local current_mib=$((root_size_sectors * logical_sector / 1048576))

  # ── 2. Validate requested size ────────────────────────────────────────

  if ((requested_mib < current_mib)); then
    die "Source rootfs-A is ${current_mib} MiB but ROOTFS_SIZE is ${requested_mib} MiB. Shrinking is not supported. Set ROOTFS_SIZE to at least ${current_mib}M."
  fi

  if ((requested_mib == current_mib)); then
    log "Rootfs-A already ${current_mib} MiB; no partition changes needed"
    return 0
  fi

  local delta_mib=$((requested_mib - current_mib))
  local sectors_per_mib=$((1048576 / logical_sector))
  local delta_sectors=$((delta_mib * sectors_per_mib))
  local target_root_sectors=$((root_size_sectors + delta_sectors))
  local root_end=$((root_start + root_size_sectors - 1))

  # ── 3. Identify trailing partitions ───────────────────────────────────

  # Collect partitions that start after rootfs-A ends.
  # Store as: partnum:start
  local -a trailing=()
  for part in "$LOOPDEV"p*; do
    [[ -b "$part" ]] || continue
    local pnum="${part##*p}"
    [[ "$pnum" == "$root_partnum" ]] && continue
    sgdisk_partition_info "$pnum" "$LOOPDEV"
    local p_start="$SGDINFO_START"
    [[ -n "$p_start" ]] || continue
    if ((p_start > root_end)); then
      trailing+=("$pnum:$p_start")
    fi
  done

  # Sort by start sector descending (move last partition first).
  if ((${#trailing[@]} > 0)); then
    mapfile -t trailing < <(
      printf '%s\n' "${trailing[@]}" | sort -t: -k2,2nr
    )
  fi

  # ── 4. Plan report ────────────────────────────────────────────────────

  local new_image_bytes=$((image_bytes + delta_mib * 1048576))
  local new_image_mib=$((new_image_bytes / 1048576))
  # shellcheck disable=SC2034
  PROJECTED_IMAGE_BYTES="$new_image_bytes"
  # shellcheck disable=SC2034
  ROOTFS_GROWTH_BYTES=$((delta_mib * 1048576))

  log "=== Recovery image rootfs growth plan ==="
  log "Source image:            $((image_bytes / 1048576)) MiB"
  log "Source rootfs-A:         ${current_mib} MiB"
  log "Requested ROOTFS_SIZE:   ${requested_mib} MiB"
  log "Growth required:         ${delta_mib} MiB"
  log ""
  if ((${#trailing[@]} > 0)); then
    log "Partitions to relocate:"
    local entry
    for entry in "${trailing[@]}"; do
      local pnum="${entry%%:*}"
      local p_lbl
      p_lbl="$(blkid -s PARTLABEL -o value "${LOOPDEV}p${pnum}" 2>/dev/null || echo "part$pnum")"
      log "  ${p_lbl} (p${pnum}): +${delta_mib} MiB"
    done
  fi
  log ""
  log "Projected image size:    ${new_image_mib} MiB"
  log "rootfs-A start:          unchanged"
  log "rootfs-A end:            +${delta_mib} MiB"

  # ── 5. Pre-flight checks ──────────────────────────────────────────────

  for part in "$LOOPDEV"p*; do
    [[ -b "$part" ]] || continue
    if findmnt -rn -S "$part" >/dev/null 2>&1; then
      die "$part is mounted; refusing to alter image partition geometry"
    fi
  done

  # ── 6. Backup GPT ─────────────────────────────────────────────────────

  log "Backing up GPT"
  sgdisk --backup="$WORKDIR/gpt-before-rootfs-grow.bin" "$LOOPDEV" \
    || die "Failed to backup GPT"
  sgdisk -p "$LOOPDEV" >"$WORKDIR/partitions-before-rootfs-grow.txt" 2>/dev/null || true

  # ── 7. Hash and capture trailing partition identity ────────────────────

  local -A part_hashes_before=()
  local -A part_uuids=()
  local -A part_type_guids=()
  local -A part_labels=()
  local -A part_fs_uuids=()
  local -A part_size_bytes=()
  local -A part_size_sectors=()
  local -A part_start_old=()
  for entry in "${trailing[@]}"; do
    local pnum="${entry%%:*}"
    local pdev="${LOOPDEV}p${pnum}"
    [[ -b "$pdev" ]] || die "Partition device $pdev not found"

    # shellcheck disable=SC2034
    part_start_old[$pnum]="${entry#*:}"
    part_size_bytes[$pnum]="$(blockdev --getsize64 "$pdev")"
    ((part_size_bytes[$pnum] % logical_sector == 0)) \
      || die "Partition $pnum size (${part_size_bytes[$pnum]} bytes) is not sector-aligned"
    part_size_sectors[$pnum]="$((part_size_bytes[$pnum] / logical_sector))"

    log "Hashing partition $pnum before move..."
    part_hashes_before[$pnum]="$(sha256sum "$pdev" | cut -d' ' -f1)" \
      || die "Failed to hash partition $pnum"
    # GPT identity from sgdisk (kernel-independent).
    sgdisk_partition_info "$pnum" "$LOOPDEV"
    part_uuids[$pnum]="$SGDINFO_PARTUUID"
    part_labels[$pnum]="$SGDINFO_NAME"
    part_type_guids[$pnum]="$SGDINFO_TYPE_GUID"
    # FS identity from Btrfs superblock.
    part_fs_uuids[$pnum]="$(blkid -s UUID -o value "$pdev" 2>/dev/null)" \
      || die "Could not read FS UUID from $pdev"
  done

  # ── 8. Extend raw image ───────────────────────────────────────────────

  log "Extending image by ${delta_mib} MiB"
  truncate -s "$new_image_bytes" "$OUT"
  losetup -c "$LOOPDEV" \
    || die "Failed to refresh loop device after image extension"

  sgdisk --move-second-header "$LOOPDEV" \
    || die "Failed to relocate backup GPT after image extension"
  sgdisk -v "$LOOPDEV" >/dev/null 2>&1 \
    || die "GPT verification failed after image extension"

  # ── 9. Move trailing partitions (last-to-first) ───────────────────────

  for entry in "${trailing[@]}"; do
    local pnum="${entry%%:*}"
    local old_start="${entry#*:}"
    local new_start=$((old_start + delta_sectors))
    local psize_sectors="${part_size_sectors[$pnum]}"
    local pdev="${LOOPDEV}p${pnum}"
    local p_lbl="${part_labels[$pnum]:-part$pnum}"

    log "Moving ${p_lbl} (partition ${pnum}): start ${old_start} → ${new_start}"
    if ! printf 'start=%s, size=%s\n' "$new_start" "$psize_sectors" \
      | sfdisk --move-data --move-use-fsync -N "$pnum" "$LOOPDEV" \
        >>"$PARTITION_DEBUG_LOG" 2>&1; then
      cat "$PARTITION_DEBUG_LOG" >&2
      die "Failed to move partition ${pnum} (${p_lbl})"
    fi

    # Verify GPT geometry first — this is the authoritative on-disk value.
    sgdisk_partition_info "$pnum" "$LOOPDEV"
    [[ "$SGDINFO_START" == "$new_start" ]] \
      || die "Partition $pnum GPT start mismatch: expected $new_start, got $SGDINFO_START"

    # See whether the kernel mapping already followed the sfdisk operation.
    local kernel_start
    kernel_start="$(lsblk -ndo START "$pdev" 2>/dev/null || true)"

    if [[ "$kernel_start" != "$new_start" ]]; then
      log "  Refreshing stale kernel geometry for $pdev"
      partx -u -n "$pnum" "$LOOPDEV" 2>/dev/null || true
      udevadm settle --timeout=10 2>/dev/null || true
      kernel_start="$(lsblk -ndo START "$pdev" 2>/dev/null || true)"
    fi

    [[ "$kernel_start" == "$new_start" ]] \
      || die "Kernel has stale geometry for $pdev: expected $new_start, got ${kernel_start:-<missing>}"

    log "    ✓ kernel geometry updated"

    # Verify identity — GPT from sgdisk, FS from blkid.
    sgdisk_partition_info "$pnum" "$LOOPDEV"
    local chk_fs_uuid
    chk_fs_uuid="$(blkid -s UUID -o value "$pdev" 2>/dev/null)" \
      || die "Could not read FS UUID from $pdev after relocation"
    local new_size
    new_size="$(blockdev --getsize64 "$pdev")"

    [[ "$SGDINFO_PARTUUID" == "${part_uuids[$pnum]}" ]] \
      || die "Partition $pnum PARTUUID changed: ${part_uuids[$pnum]} → $SGDINFO_PARTUUID"
    [[ "$SGDINFO_TYPE_GUID" == "${part_type_guids[$pnum]}" ]] \
      || die "Partition $pnum type GUID changed: ${part_type_guids[$pnum]} → $SGDINFO_TYPE_GUID"
    [[ "$SGDINFO_NAME" == "${part_labels[$pnum]}" ]] \
      || die "Partition $pnum GPT name changed: ${part_labels[$pnum]} → $SGDINFO_NAME"
    [[ "$chk_fs_uuid" == "${part_fs_uuids[$pnum]}" ]] \
      || die "Partition $pnum FS UUID changed: ${part_fs_uuids[$pnum]} → $chk_fs_uuid"
    [[ "$new_size" == "${part_size_bytes[$pnum]}" ]] \
      || die "Partition $pnum size changed: ${part_size_bytes[$pnum]} → $new_size"

    # Hash after move.
    log "Hashing partition $pnum after move..."
    local new_hash
    new_hash="$(sha256sum "$pdev" | cut -d' ' -f1)" \
      || die "Failed to hash partition $pnum after move"
    [[ "$new_hash" == "${part_hashes_before[$pnum]}" ]] \
      || die "Partition $pnum hash changed — data corrupted during move"

    log "  ✓ ${p_lbl} relocated byte-identically"
  done

  # ── 10. Grow rootfs-A partition ────────────────────────────────────────

  log "Growing rootfs-A: ${root_size_sectors} → ${target_root_sectors} sectors"

  if ! printf 'start=%s, size=%s\n' "$root_start" "$target_root_sectors" \
    | sfdisk -N "$root_partnum" "$LOOPDEV" \
      >>"$PARTITION_DEBUG_LOG" 2>&1; then
    cat "$PARTITION_DEBUG_LOG" >&2
    die "Failed to grow rootfs-A partition"
  fi

  udevadm settle --timeout=10 2>/dev/null || true

  sgdisk -v "$LOOPDEV" >/dev/null 2>&1 \
    || die "GPT verification failed after growing rootfs-A"

  # See whether the kernel mapping already followed the sfdisk operation.
  local expected_root_bytes=$((target_root_sectors * logical_sector))
  local kernel_root_bytes
  kernel_root_bytes="$(blockdev --getsize64 "$ROOTPART" 2>/dev/null || echo 0)"

  if [[ "$kernel_root_bytes" != "$expected_root_bytes" ]]; then
    log "  Refreshing stale kernel geometry for rootfs-A"
    partx -u -n "$root_partnum" "$LOOPDEV" 2>/dev/null || true
    udevadm settle --timeout=10 2>/dev/null || true
    kernel_root_bytes="$(blockdev --getsize64 "$ROOTPART" 2>/dev/null || echo 0)"
  fi

  [[ "$kernel_root_bytes" == "$expected_root_bytes" ]] \
    || die "Kernel rootfs geometry is stale: expected ${expected_root_bytes} bytes, got ${kernel_root_bytes}"

  log "    ✓ kernel geometry updated"

  # Verify trailing partitions weren't disturbed by the rootfs resize.
  # GPT properties from sgdisk (kernel-independent); FS UUID from blkid.
  for entry in "${trailing[@]}"; do
    local pnum="${entry%%:*}"
    local pdev="${LOOPDEV}p${pnum}"
    local p_lbl="${part_labels[$pnum]:-part$pnum}"
    local chk_partuuid chk_fs_uuid chk_size_sectors
    sgdisk_partition_info "$pnum" "$LOOPDEV"
    chk_partuuid="$SGDINFO_PARTUUID"
    chk_size_sectors="$SGDINFO_SIZE"
    chk_fs_uuid="$(blkid -s UUID -o value "$pdev" 2>/dev/null || true)"
    [[ "$chk_partuuid" == "${part_uuids[$pnum]}" ]] \
      || die "Post-grow: $p_lbl PARTUUID changed"
    [[ "$chk_fs_uuid" == "${part_fs_uuids[$pnum]}" ]] \
      || die "Post-grow: $p_lbl FS UUID changed"
    [[ "$chk_size_sectors" == "${part_size_sectors[$pnum]}" ]] \
      || die "Post-grow: $p_lbl size changed"
  done

  # ── 11. Verify final layout ────────────────────────────────────────────
  # GPT properties are read from the on-disk GPT via sgdisk (not affected by
  # stale kernel partition mappings).  FS properties come from the Btrfs
  # superblock via blkid.

  local final_disk_guid
  final_disk_guid="$(
    sgdisk -p "$LOOPDEV" 2>/dev/null \
      | sed -n 's/^Disk identifier (GUID):[[:space:]]*//p'
  )"
  sgdisk_partition_info "$root_partnum" "$LOOPDEV"
  local final_root_type_guid="$SGDINFO_TYPE_GUID"
  local final_root_partuuid="$SGDINFO_PARTUUID"
  local final_root_label="$SGDINFO_NAME"
  local final_root_start="$SGDINFO_START"
  local final_root_sectors="$SGDINFO_SIZE"

  local final_root_fs_uuid
  final_root_fs_uuid="$(blkid -s UUID -o value "$ROOTPART" 2>/dev/null)" \
    || die "Could not read final Btrfs UUID from $ROOTPART"

  local final_root_bytes final_root_mib
  final_root_bytes=$((final_root_sectors * logical_sector))
  final_root_mib=$((final_root_bytes / 1048576))

  [[ "$final_disk_guid" == "$disk_guid" ]] \
    || die "Disk GUID changed: $disk_guid → $final_disk_guid"
  [[ "$final_root_start" == "$root_start" ]] \
    || die "rootfs-A start sector changed: $root_start → $final_root_start"
  [[ "$final_root_partuuid" == "$root_partuuid" ]] \
    || die "rootfs-A PARTUUID changed: $root_partuuid → $final_root_partuuid"
  [[ "$final_root_type_guid" == "$root_type_guid" ]] \
    || die "rootfs-A type GUID changed: $root_type_guid → $final_root_type_guid"
  [[ "$final_root_label" == "rootfs-A" ]] \
    || die "rootfs-A GPT name changed: $final_root_label"
  [[ "$final_root_fs_uuid" == "$root_fs_uuid" ]] \
    || die "rootfs-A FS UUID changed: $root_fs_uuid → $final_root_fs_uuid"
  [[ "$final_root_mib" == "$requested_mib" ]] \
    || die "rootfs-A size mismatch: expected ${requested_mib} MiB, got ${final_root_mib} MiB"

  log "=== Rootfs-A partition growth complete ==="
  log "  Disk GUID:  ${final_disk_guid} (unchanged)"
  log "  rootfs-A:   ${current_mib} → ${requested_mib} MiB"
  log "  PARTUUID:   ${final_root_partuuid} (unchanged)"
  log "  type GUID:  ${final_root_type_guid} (unchanged)"
  log "  FS UUID:    ${final_root_fs_uuid} (unchanged)"
  log "  Image:      $((image_bytes / 1048576)) → ${new_image_mib} MiB"
  sgdisk -v "$LOOPDEV" >/dev/null 2>&1 \
    || die "Final GPT verification failed"
  log "  GPT:        primary ✓  backup ✓"
}

# Grow Btrfs rootfs to fill its partition.
# Called after prepare_writable_rootfs_{native,rebuild} has made the filesystem
# writable, and after prepare_image_rootfs_size may have enlarged the partition.
grow_rootfs_filesystem_to_partition() {
  local mnt="$WORKDIR/rootfs-grow"
  mkdir -p "$mnt"

  ensure_unmounted "$mnt" "stale rootfs grow mount"

  mount -o rw,subvolid=5 "$ROOTPART" "$mnt" \
    || die "Failed to mount rootfs for filesystem expansion"

  local partition_bytes before_bytes after_bytes
  partition_bytes="$(blockdev --getsize64 "$ROOTPART")"
  before_bytes="$(get_btrfs_device_size "$mnt")"

  log "Rootfs filesystem expansion:"
  log "  Partition: ${partition_bytes} bytes"
  log "  Btrfs before: ${before_bytes:-<unknown>} bytes"

  if [[ "$before_bytes" == "$partition_bytes" ]]; then
    log "Btrfs already fills partition — no resize needed"
  else
    log "Growing Btrfs rootfs to partition maximum"
    if ! btrfs filesystem resize max "$mnt"; then
      strict_unmount "$mnt" "rootfs after failed filesystem resize" || true
      die "Failed to grow Btrfs rootfs to fill partition"
    fi

    sync -f "$mnt" 2>/dev/null || sync

    after_bytes="$(get_btrfs_device_size "$mnt")"

    if [[ ! "$after_bytes" =~ ^[0-9]+$ ]]; then
      strict_unmount "$mnt" "rootfs after unverifiable resize" || true
      die "Could not determine Btrfs device size after resize"
    fi

    if [[ "$after_bytes" != "$partition_bytes" ]]; then
      strict_unmount "$mnt" "rootfs after incomplete resize" || true
      die "Btrfs does not fill rootfs partition: filesystem=$after_bytes partition=$partition_bytes"
    fi

    log "  Btrfs after:  ${after_bytes} bytes ✓"
  fi

  strict_unmount "$mnt" "rootfs after filesystem expansion" \
    || die "Failed to unmount rootfs after filesystem expansion"
  rmdir "$mnt" 2>/dev/null || true
}

# Stable entry point used by existing callers.  The optional first argument
# selects the implementation for one call; otherwise ROOTFS_WRITABLE_METHOD is
# used.  Default is the native/in-place method; set ROOTFS_WRITABLE_METHOD=rebuild
# to use the legacy mkfs.btrfs -> dd method instead.
#
# Examples:
#   prepare_writable_rootfs native
#   ROOTFS_WRITABLE_METHOD=native   # preferred/in-place method
#   ROOTFS_WRITABLE_METHOD=rebuild  # legacy mkfs.btrfs -> dd method
prepare_writable_rootfs() {
  local method="${1:-${ROOTFS_WRITABLE_METHOD:-native}}"

  # Grow the rootfs-A partition to ROOTFS_SIZE if requested.
  if [[ -n "${ROOTFS_SIZE:-}" ]] && ((ROOTFS_SIZE > 0)); then
    prepare_image_rootfs_size "$ROOTFS_SIZE"
  fi

  case "$method" in
    native | ideal | inplace | in-place)
      log "Writable rootfs implementation: native/in-place"
      prepare_writable_rootfs_native
      ;;
    rebuild | legacy | mkfs)
      log "Writable rootfs implementation: legacy rebuild"
      prepare_writable_rootfs_rebuild
      ;;
    *)
      die "Unknown ROOTFS_WRITABLE_METHOD '$method' (expected native or rebuild)"
      ;;
  esac

  grow_rootfs_filesystem_to_partition
}
