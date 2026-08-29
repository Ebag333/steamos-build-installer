#!/bin/bash
#
# steamos-build-installer — lib/pipelines/pipeline_rebuild.sh
# Rebuild (self-heal) workflow pipeline definition.
# Defines the phases for re-applying NVIDIA patches after an OS update.
#
# Sourced by repatch.sh — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/pipelines/pipeline_rebuild.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Pipeline Definition
# ---------------------------------------------------------------------------

register_rebuild_pipeline() {
  define_pipeline \
    "mount" \
    "discover" \
    "overlay" \
    "install" \
    "configure" \
    "reconcile"

  register_phase "mount" "phase_rebuild_mount" "Mount target rootfs"
  register_phase "discover" "phase_rebuild_discover" "Discover kernel and packages"
  register_phase "overlay" "phase_rebuild_overlay" "Create overlay chroot"
  register_phase "install" "phase_rebuild_install" "Install drivers and packages"
  register_phase "configure" "phase_rebuild_configure" "Configure system and GRUB"
  register_phase "reconcile" "phase_rebuild_reconcile" "Reconcile and verify"
}

# ---------------------------------------------------------------------------
# Cleanup Trap
# ---------------------------------------------------------------------------

# Cleanup function for repatch workflow.
# Tears down mounts, loop devices, and temporary directories.
repatch_cleanup() {
  local _had_e=0
  [[ -o errexit ]] && _had_e=1
  set +e

  # Overlay cleanup (tears down MERGED and chroot bind mounts)
  if declare -F overlay_cleanup >/dev/null 2>&1; then
    overlay_cleanup
  fi

  # Unmount chroot filesystems
  if declare -F umount_chroot_fs >/dev/null 2>&1; then
    umount_chroot_fs "$NEWROOT" 2>/dev/null
  fi

  # Unmount EFI if mounted
  if mountpoint -q "$NEWROOT/efi" 2>/dev/null; then
    umount -R "$NEWROOT/efi" 2>/dev/null || umount -Rl "$NEWROOT/efi" 2>/dev/null
  fi

  # Unmount workspace
  if [[ -n "${WORK:-}" ]] && mountpoint -q "$WORK" 2>/dev/null; then
    umount "$WORK" 2>/dev/null || umount -l "$WORK" 2>/dev/null
  fi

  # Detach workspace loop device
  if [[ -n "${WORK_LOOPDEV:-}" ]]; then
    losetup -d "$WORK_LOOPDEV" 2>/dev/null || true
    WORK_LOOPDEV=""
  fi

  # Unmount target rootfs
  if [[ -n "${NEWROOT:-}" ]] && mountpoint -q "$NEWROOT" 2>/dev/null; then
    umount -R "$NEWROOT" 2>/dev/null || umount -Rl "$NEWROOT" 2>/dev/null
  fi

  # Clean up temporary directories
  rmdir "$NEWROOT" "$WORK" 2>/dev/null || true

  # Remove workspace image if not attached
  if [[ -n "${WORKIMG:-}" ]] && [[ -z "$(losetup -j "$WORKIMG" 2>/dev/null)" ]]; then
    rm -f "$WORKIMG"
  elif [[ -n "${WORKIMG:-}" ]]; then
    warn "workspace image is still attached; leaving $WORKIMG in place"
  fi

  if [[ $_had_e -eq 1 ]]; then
    set -e
  else
    set +e
  fi
}

# Register cleanup trap
register_rebuild_cleanup() {
  trap 'set +e; repatch_cleanup; set -e' EXIT
}

# ---------------------------------------------------------------------------
# Phase Implementations
# ---------------------------------------------------------------------------

# Phase: Mount target rootfs
phase_rebuild_mount() {
  # Run boot diagnostics
  if declare -F diagnose_boot_layout >/dev/null 2>&1; then
    diagnose_boot_layout "$PARTSET"
  fi
  if declare -F diagnose_boot_state >/dev/null 2>&1; then
    diagnose_boot_state
  fi

  # Mount the inactive slot's rootfs partition
  step "Mounting $ROOTDEV"
  mount -o rw,compress-force=zstd:3 "$ROOTDEV" "$NEWROOT" \
    || {
      die "Could not mount $PARTSET rootfs"
      return 1
    }

  # Ensure rootfs is writable
  # A freshly staged SteamOS Btrfs image can have the root tree's subvolume-level
  # ro property set even while the VFS mount itself reports "rw".
  local vfs_opts btrfs_ro
  vfs_opts="$(findmnt -no OPTIONS "$NEWROOT" 2>/dev/null || true)"
  btrfs_ro="$(btrfs property get -ts "$NEWROOT" ro 2>/dev/null | awk -F= '/^ro=/{print $2}' || true)"
  log "Rootfs write state: VFS='${vfs_opts:-<unknown>}' Btrfs-ro='${btrfs_ro:-<unknown>}'"

  # Handle a genuinely read-only VFS mount first
  if printf '%s\n' "$vfs_opts" | tr ',' '\n' | grep -qx ro; then
    log "Remounting $PARTSET rootfs rw"
    mount -o remount,rw "$NEWROOT" \
      || {
        die "Could not remount $PARTSET rootfs read-write"
        return 1
      }
  fi

  # Handle the independent Btrfs subvolume property
  if [[ "$btrfs_ro" == "true" ]]; then
    log "Clearing Btrfs read-only property on staged rootfs"
    btrfs property set -ts "$NEWROOT" ro false \
      || {
        die "Could not clear Btrfs read-only property on $PARTSET rootfs"
        return 1
      }

    btrfs_ro="$(btrfs property get -ts "$NEWROOT" ro 2>/dev/null | awk -F= '/^ro=/{print $2}' || true)"
    [[ "$btrfs_ro" == "false" ]] \
      || {
        die "Btrfs rootfs still reports ro=${btrfs_ro:-<unknown>} after clearing property"
        return 1
      }
  fi

  # Verify writability
  if ! touch "$NEWROOT/.rw-test"; then
    warn "Rootfs diagnostics after failed write:"
    warn "  mount: $(findmnt -rn -o SOURCE,FSTYPE,OPTIONS,TARGET "$NEWROOT" 2>/dev/null || echo '<unknown>')"
    warn "  blockdev-ro: $(blockdev --getro "$ROOTDEV" 2>/dev/null || echo '<unknown>')"
    warn "  btrfs-ro: $(btrfs property get -ts "$NEWROOT" ro 2>/dev/null || echo '<unknown>')"
    die "$PARTSET rootfs is not writable"
    return 1
  fi
  rm -f "$NEWROOT/.rw-test"

  # Expand rootfs to fill partition
  log "Checking rootfs size"
  local part_bytes fs_bytes
  part_bytes="$(blockdev --getsize64 "$ROOTDEV" 2>/dev/null || echo 0)"
  fs_bytes="$(btrfs filesystem usage -b "$NEWROOT" 2>/dev/null | grep -oP '^\s+Device size:\s+\K[0-9]+' || echo 0)"

  ((part_bytes > 0)) || {
    die "Could not determine rootfs partition size"
    return 1
  }
  ((fs_bytes > 0)) || {
    die "Could not determine rootfs filesystem size"
    return 1
  }
  ((fs_bytes <= part_bytes)) \
    || {
      die "rootfs reports larger than its backing partition (${fs_bytes} > ${part_bytes})"
      return 1
    }

  if ((part_bytes > fs_bytes)); then
    log "Expanding rootfs to fill partition (${fs_bytes} → ${part_bytes} bytes)"
    btrfs filesystem resize max "$NEWROOT" \
      || {
        die "rootfs resize failed"
        return 1
      }

    local fs_bytes_after
    fs_bytes_after="$(btrfs filesystem usage -b "$NEWROOT" 2>/dev/null | grep -oP '^\s+Device size:\s+\K[0-9]+' || echo 0)"
    log "Rootfs size after resize: ${fs_bytes_after:-<unknown>} bytes"
    ((fs_bytes_after > 0)) || {
      die "Could not verify rootfs size after resize"
      return 1
    }
    ((fs_bytes_after >= part_bytes)) \
      || {
        die "rootfs resize did not consume the full partition (${fs_bytes_after} < ${part_bytes})"
        return 1
      }
  else
    log "Rootfs already fills partition"
  fi

  return 0
}

# Phase: Discover kernel and packages
phase_rebuild_discover() {
  # Discover kernel version
  step "Discovering target kernel"
  discover_neptune_kver "$NEWROOT"
  log "Target kernel: $KVER"

  # Load persisted build selections from user's config
  if [[ -r /home/.steamos-build/build.conf ]]; then
    # shellcheck disable=SC1091
    source /home/.steamos-build/build.conf
  else
    die "Build config not found at /home/.steamos-build/build.conf"
  fi

  : "${INITRAMFS_MODULES:=}"
  : "${HW_SUPPORT_ITEMS:=}"
  : "${GAMING_ITEMS:=}"

  # Derive build flags from GAMING_ITEMS (same as pipeline_build.sh)
  if [[ -n "${GAMING_ITEMS:-}" ]]; then
    [[ " $GAMING_ITEMS " == *" fix-keyring "* ]] && export FIX_KEYRING=1
    [[ " $GAMING_ITEMS " == *" skip-sigcheck "* ]] && export SKIP_SIG=1
  fi

  # Discover kernel package and headers URL
  discover_kernel_pkg "$NEWROOT"
  construct_hdr_url "$NEWROOT"
  log "Headers: $(basename "$HDR_URL")"
  curl -sfIL "$HDR_URL" -o /dev/null \
    || {
      die "matching headers not in Valve's pool: $HDR_URL"
      return 1
    }

  return 0
}

# Phase: Create overlay chroot
phase_rebuild_overlay() {
  # Prepare temporary ext4 overlay workspace
  log "Preparing temporary ext4 overlay workspace"

  # Clean up any stale workspace
  while IFS="" read -r stale_loop; do
    [[ -n "$stale_loop" ]] || continue
    while IFS="" read -r stale_mnt; do
      [[ -n "$stale_mnt" ]] || continue
      umount -R "$stale_mnt" 2>/dev/null \
        || umount -Rl "$stale_mnt" 2>/dev/null \
        || true
    done < <(findmnt -rn -o TARGET -S "$stale_loop" 2>/dev/null)
    losetup -d "$stale_loop" 2>/dev/null || true
  done < <(losetup -j "$WORKIMG" 2>/dev/null | cut -d: -f1)

  [[ -z "$(losetup -j "$WORKIMG" 2>/dev/null)" ]] \
    || {
      die "stale repatch workspace is still attached: $WORKIMG"
      return 1
    }

  rm -f "$WORKIMG"
  truncate -s 8G "$WORKIMG"
  mkfs.ext4 -q -F "$WORKIMG"
  WORK_LOOPDEV="$(losetup -f --show "$WORKIMG")" \
    || {
      die "Could not allocate loop device for repatch workspace"
      return 1
    }
  mount "$WORK_LOOPDEV" "$WORK" \
    || {
      die "Could not mount repatch workspace"
      return 1
    }

  # Create overlay
  step "Reconciling driver and hardware packages in overlay chroot"
  overlay_mount "$NEWROOT" "$WORK" "$WORK/merged"

  # Set up shared build helpers
  # shellcheck disable=SC2034 # MNT is read by functions in common_drivers.sh, grub.sh, finalize.sh, overlay.sh, etc.
  MNT="$NEWROOT"
  WORKDIR="$WORK"

  # Configure pacman
  if [[ "${SKIP_SIG:-0}" -eq 1 ]]; then
    warn "pacman signature verification DISABLED for repatch"
    setup_pacman_conf "$MERGED/tmp/pacman-repatch.conf" "Never"
  else
    setup_pacman_conf "$MERGED/tmp/pacman-repatch.conf" "Required DatabaseOptional"
  fi

  # Initialize keyring
  if [[ "${FIX_KEYRING:-0}" -eq 1 ]]; then
    log "Force-initialising pacman keyring with Arch Linux + Holo keys"
    overlay_init_keyring "archlinux holo"
  else
    overlay_init_keyring
  fi

  # Snapshot package state before overlay transaction
  snapshot_driver_packages "$WORK/before.txt"

  return 0
}

# Phase: Install drivers and packages
phase_rebuild_install() {
  # Clear transaction scratch files from any previous run
  : >"$WORKDIR/build-only-exclusions.txt"
  : >"$WORKDIR/custom-payload-files.txt"

  # Install kernel headers
  log "Downloading exact-match kernel headers"
  in_chroot "curl -sfL '$HDR_URL' -o /tmp/headers.pkg.tar.zst"

  log "Refreshing Valve package database for header dependencies"
  in_chroot "pacman --config '$PACCONF' -Sy"

  log "Installing exact-match kernel headers"
  in_chroot "pacman --config '$PACCONF' -U $PACOPTS /tmp/headers.pkg.tar.zst"

  # Install hardware packages (NVIDIA + optional)
  install_hw_libs
  patch_record "NVIDIA driver + hardware packages" "ok"

  # Add Thunderbolt support files
  local thunderbolt_dir=""
  if [[ -d "/home/.steamos-build/bundles/thunderbolt" ]]; then
    thunderbolt_dir="/home/.steamos-build/bundles/thunderbolt"
  fi
  if [[ -n "$thunderbolt_dir" ]]; then
    log "Adding thunderbolt support"
    if declare -F _install_thunderbolt_files >/dev/null 2>&1; then
      _install_thunderbolt_files "$thunderbolt_dir" "$MERGED"
      _install_thunderbolt_files "$thunderbolt_dir" "$NEWROOT"
      patch_record "Thunderbolt support" "ok"
    else
      warn "_install_thunderbolt_files not defined; skipping bundle install"
      patch_record "Thunderbolt support" "fail" "_install_thunderbolt_files not implemented"
    fi
  fi

  # Build custom kernel modules from hw-packages-build.conf
  local kernel_modules
  kernel_modules="$(get_build_items "kernel-module")"
  if [[ -n "$kernel_modules" ]]; then
    for module in $kernel_modules; do
      local recipe_name
      recipe_name="$(get_build_recipe "$module")" || recipe_name=""
      local recipe_dir=""
      if [[ -n "$recipe_name" ]]; then
        recipe_dir="$SCRIPT_DIR/lib/configs/build_recipes/$recipe_name"
      fi

      # Check for INSTALL_CMD (direct install mode)
      local _install_cmd=""
      if [[ -d "$recipe_dir" ]]; then
        _install_cmd="$(sed -n 's/^INSTALL_CMD=//p' "$recipe_dir/recipe.conf" 2>/dev/null | tr -d '"' | head -1)"
      fi

      if [[ -n "$_install_cmd" ]]; then
        # Direct install mode (e.g., logitech-hid)
        log "Building $module via recipe (direct install)"
        local _install_args=""
        _install_args="$(sed -n 's/^INSTALL_ARGS=//p' "$recipe_dir/recipe.conf" 2>/dev/null | tr -d '"' | head -1)"

        # Copy recipe sources into chroot
        mkdir -p "$MERGED/tmp/build/sources"
        if [[ -d "$recipe_dir/sources" ]]; then
          cp -a "$recipe_dir/sources/." "$MERGED/tmp/build/sources/"
        fi

        # Run the install script in chroot
        local _script_name
        _script_name="$(basename "$_install_cmd")"
        if [[ -f "$MERGED/tmp/build/sources/$_script_name" ]]; then
          chmod +x "$MERGED/tmp/build/sources/$_script_name"
          if in_chroot "cd /tmp/build/sources && ./${_script_name} ${_install_args}"; then
            log "$module built and installed via recipe"
            # Copy built modules from overlay to target
            if [[ -d "$MERGED/usr/lib/modules/$KVER/updates" ]]; then
              mkdir -p "$NEWROOT/usr/lib/modules/$KVER/updates"
              rsync -a "$MERGED/usr/lib/modules/$KVER/updates/" "$NEWROOT/usr/lib/modules/$KVER/updates/"
            fi
            register_built_module "updates/logitech/hid-logitech-dj.ko"
            register_built_module "updates/logitech/hid-logitech-hidpp.ko"
            verify_built_modules "$MERGED" "$KVER" die
            patch_record "$module" "ok"
          else
            warn "FAILED: $module build via recipe failed"
            patch_record "$module" "fail"
          fi
        else
          warn "Install script not found: $_script_name in $recipe_dir/sources/"
          patch_record "$module" "fail"
        fi
      elif declare -F "apply_${module//-/_}_rebuild" >/dev/null 2>&1; then
        # Legacy function mode (e.g., aotofu-vaapi)
        local _fn="apply_${module//-/_}_rebuild"
        log "Building $module via $_fn"
        if "$_fn"; then
          log "$module rebuilt successfully"
          patch_record "$module" "ok"
        else
          warn "FAILED: $module rebuild failed"
          patch_record "$module" "fail"
        fi
      else
        warn "No recipe or rebuild function found for $module"
        patch_record "$module" "fail"
      fi
    done
  fi

  # Install flatpak packages from hw-packages-build.conf
  step "Installing flatpak packages"
  install_flatpak_packages "$NEWROOT" patch_record

  # Copy payload
  step "Copying reconciled payload into $PARTSET rootfs"
  copy_driver_payload "$NEWROOT" "$WORK/before.txt" "$WORK"
  patch_record "Payload copy" "ok"

  # Ensure flatpak staging service is installed (idempotent)
  ensure_flatpak_service "$NEWROOT"

  return 0
}

# Phase: Configure system and GRUB
phase_rebuild_configure() {
  # Reconcile initramfs
  step "Restoring module autoloading in initramfs"
  reconcile_initramfs "$NEWROOT" "$KVER" "${INITRAMFS_MODULES:-}"
  patch_record "Initramfs modules" "ok"

  # Apply all customizations dynamically from config
  step "Reconciling target system configuration"
  local all_items
  all_items="$(get_all_customization_items)"
  if [[ -n "$all_items" ]]; then
    for _item in $all_items; do
      if apply_optimization_for_item "$_item" "rebuild" "$NEWROOT"; then
        patch_record "$_item" "ok"
      else
        patch_record "$_item" "fail"
      fi
    done
  fi

  # Enable nvidia power services
  if enable_nvidia_power_services "$NEWROOT"; then
    patch_record "nvidia-power" "ok"
  else
    patch_record "nvidia-power" "fail" "could not enable nvidia power services"
  fi

  return 0
}

# Phase: Reconcile and verify
phase_rebuild_reconcile() {
  # Propagate self-healing scripts from /home (latest) or /usr (fallback).
  # Persist project files to /home for later re-run
  ensure_project_persisted

  # Restore modprobe config
  install_nvidia_modprobe_conf "$NEWROOT"

  # Backup and restore updater
  backup_original_updater "$NEWROOT"
  cp -a /usr/bin/steamos-update "$NEWROOT/usr/bin/steamos-update"

  # Configure desktop session
  configure_desktop_session "$NEWROOT" "desktop"

  # Run custom script
  run_custom_script "$NEWROOT"

  # Run final diagnostics
  if declare -F diagnose_boot_state >/dev/null 2>&1; then
    diagnose_boot_state
  fi

  # Reconcile GRUB
  step "Reconciling GRUB configuration"
  reconcile_grub "$NEWROOT" "$EFIDEV" "$PARTSET"

  return 0
}
