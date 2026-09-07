
  # --- expand rootfs partitions to fill their (possibly larger) partitions ---
  if [[ -n "${STEAMOS_ROOTFS_SIZE:-}" ]]; then
    for _root_part_num in $FS_ROOT_A $FS_ROOT_B; do
      _root_part="$(diskpart $_root_part_num)"
      estat "Expanding btrfs on $_root_part to fill partition"
      _tmpmnt="$(mktemp -d /tmp/resize-btrfs.XXXXXX)"
      mount -o compress-force=zstd:3 "$_root_part" "$_tmpmnt"
      if [[ "$(btrfs property get "$_tmpmnt" ro)" == "ro=true" ]]; then
        btrfs property set "$_tmpmnt" ro false
      fi
      btrfs filesystem resize max "$_tmpmnt"
      umount "$_tmpmnt"
      rmdir "$_tmpmnt"
    done
  fi
