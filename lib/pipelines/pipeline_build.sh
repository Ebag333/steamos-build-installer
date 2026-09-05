#!/bin/bash
#
# steamos-build-installer — lib/pipelines/pipeline_build.sh
# Build workflow pipeline definition.
# Defines the phases for creating a patched NVIDIA SteamOS image.
#
# Sourced by backend.sh — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/pipelines/pipeline_build.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Diagnostic helper — trace os-release VARIANT_ID through the build
# ---------------------------------------------------------------------------

_diag_os_release() {
  local label="${1:-checkpoint}"
  local osr="$MNT/etc/os-release"
  local variant_id="<missing>"
  if [[ -f "$osr" ]]; then
    variant_id="$(grep '^VARIANT_ID=' "$osr" 2>/dev/null || true)"
    variant_id="${variant_id:-<not set>}"
  fi
  log "DIAG os-release [$label]: $variant_id"
}

# ---------------------------------------------------------------------------
# Pipeline Definition
# ---------------------------------------------------------------------------

register_build_pipeline() {
  define_pipeline \
    "validate" \
    "setup" \
    "prepare" \
    "sysupgrade" \
    "overlay" \
    "build" \
    "configure" \
    "finalize"

  register_phase "validate" "phase_build_validate" "Validate build inputs"
  register_phase "setup" "phase_build_setup" "Set up build environment"
  register_phase "prepare" "phase_build_prepare" "Prepare rootfs and partitions"
  register_phase "sysupgrade" "phase_build_sysupgrade" "Prepare package state"
  register_phase "overlay" "phase_build_overlay" "Create build overlay"
  register_phase "build" "phase_build_build" "Build and install drivers"
  register_phase "configure" "phase_build_configure" "Configure system and GRUB"
  register_phase "finalize" "phase_build_finalize" "Finalize and publish image"
}

# ---------------------------------------------------------------------------
# Phase Implementations
# ---------------------------------------------------------------------------

# Phase: Validate build inputs
phase_build_validate() {
  stage_header "preparation"
  # Log condensed build configuration
  if [[ -n "${CONFIG_FILE:-}" && -f "$CONFIG_FILE" ]]; then
    log "Build config: $CONFIG_FILE"
  else
    log "Build config: (defaults — no config file)"
  fi

  local _hw_count=0 _nvidia="no"
  if [[ -n "${HW_SUPPORT_ITEMS:-}" ]]; then
    # shellcheck disable=SC2206
    local _hw_array=($HW_SUPPORT_ITEMS)
    _hw_count=${#_hw_array[@]}
    for _item in "${_hw_array[@]}"; do
      case "$_item" in
        nvidia* | *-nvidia*) _nvidia="yes" ;;
      esac
    done
  fi

  log "Build configuration:"
  log "  rootfs:         ${ROOTFS_SIZE:-5120} MiB"
  log "  variant:        ${TARGET_VARIANT:-steamdeck}"
  log "  update branch:  ${UPDATE_BRANCH:-stable}"
  log "  pacman repo:    ${PACMAN_REPO:-valve}"
  log "  session:        ${DEFAULT_SESSION:-game}"
  log "  update mode:    ${UPDATE_MODE:-selfheal}"
  log "  base OS mode:   ${BASE_OS_MODE:-additive}"
  log "  hardware items: ${_hw_count} selected"
  log "  NVIDIA:         ${_nvidia}"

  # Validate source image
  [[ -n "$IMG" ]] || {
    warn "No source image specified"
    return 1
  }
  [[ -f "$IMG" ]] || {
    warn "Source image not found: $IMG"
    return 1
  }

  # Check for already-patched image
  [[ "$(basename "$IMG")" != *-nvidia* ]] \
    || {
      warn "Input looks like an already-patched image"
      return 1
    }

  # Validate rootfs size
  if [[ -n "$ROOTFS_SIZE" ]]; then
    [[ "$ROOTFS_SIZE" =~ ^[0-9]+$ ]] || {
      warn "Invalid rootfs size: $ROOTFS_SIZE"
      return 1
    }
    ((ROOTFS_SIZE > 0)) || {
      warn "Rootfs size must be positive"
      return 1
    }
  fi

  # Validate session
  case "${DEFAULT_SESSION:-}" in
    "" | desktop | game) ;;
    *)
      warn "Invalid session: $DEFAULT_SESSION"
      return 1
      ;;
  esac

  # Validate update mode
  case "${UPDATE_MODE:-selfheal}" in
    selfheal | hold | stock) ;;
    *)
      warn "Invalid update mode: $UPDATE_MODE"
      return 1
      ;;
  esac

  # Validate base OS mode
  case "${BASE_OS_MODE:-additive}" in
    additive | upgrade) ;;
    *)
      warn "Invalid base OS mode: $BASE_OS_MODE"
      return 1
      ;;
  esac

  return 0
}

# Phase: Set up build environment
phase_build_setup() {
  # Resolve workdir
  setup_resolve_workdir

  # Set up directory structure
  MNT="$WORKDIR/mnt"
  # shellcheck disable=SC2034 # used by setup.sh, grub.sh, overlay.sh, finalize.sh, common.sh
  EFIMNT="$WORKDIR/efi"
  HOMEMNT="$WORKDIR/home"
  # shellcheck disable=SC2034 # used by overlay.sh, common_drivers.sh, common.sh
  UPPER="$WORKDIR/upper"
  # shellcheck disable=SC2034 # used by overlay.sh, common_drivers.sh, common.sh
  OVLWORK="$WORKDIR/ovlwork"
  MERGED="$WORKDIR/merged"
  # shellcheck disable=SC2034 # used by overlay.sh, common.sh
  OVL_IMG="$WORKDIR/overlay-work.img"
  # shellcheck disable=SC2034 # used by overlay.sh, common.sh
  OVL_MNT="$WORKDIR/overlay-mnt"
  # shellcheck disable=SC2034 # used by overlay.sh, common.sh
  OVL_LOOPDEV=""

  # Persistent mount tracking — survives killed processes.
  # shellcheck disable=SC2034 # MOUNTS_FILE used by common_system.sh track/untrack_mount helpers
  MOUNTS_FILE="$WORKDIR/mounts"

  # Clear stale state and create directories
  setup_clear_stale_state
  setup_dirs

  # Raw pacman output log — preserves complete stdout+stderr for diagnostics
  PACMAN_RAW_LOG="$WORKDIR/backend.pacman.log"
  : >"$PACMAN_RAW_LOG"

  # Snapshot system state before build for hygiene comparison
  # Use /tmp so the snapshot survives cleanup removing WORKDIR
  snapshot_system_state "/tmp/.steamos-build-state-before-$$"

  return 0
}

# Phase: Prepare rootfs and partitions
phase_build_prepare() {
  # Copy/decompress source image
  setup_copy_image
  progress_emit decompress

  # Loop mount
  setup_loop_mount

  # Prepare writable rootfs (btrfs specific)
  prepare_writable_rootfs
  progress_emit create_fs

  # Mount partitions
  setup_mount_partitions
  setup_discover
  progress_emit mount

  return 0
}

# Phase: Prepare package state (upgrade or additive db sync)
phase_build_sysupgrade() {
  # Derive build-flag items from GAMING_ITEMS
  if [[ -n "${GAMING_ITEMS:-}" ]]; then
    [[ " $GAMING_ITEMS " == *" fix-keyring "* ]] && export FIX_KEYRING=1
    [[ " $GAMING_ITEMS " == *" skip-sigcheck "* ]] && export SKIP_SIG=1
  fi

  # Generate machine-id if invalid — systemd-tmpfiles needs it to expand %m
  # EUCLEAN ("Structure needs cleaning") means invalid format, not just empty
  # This is temporary for build-time; restored during finalization
  local _machine_id="$MNT/etc/machine-id"
  _MACHINE_ID_WAS_EMPTY=0

  # Debug: log what Valve's image contains
  printf 'machine-id before package state prep: <%s>\n' "$(cat "$_machine_id" 2>/dev/null)" >&2

  if ! grep -Eq '^[0-9a-fA-F]{32}$' "$_machine_id" 2>/dev/null; then
    _MACHINE_ID_WAS_EMPTY=1
    log "Provisioning temporary build machine-id (current value invalid or missing)"
    : >"$_machine_id"
    if ! systemd-machine-id-setup --root="$MNT" 2>/dev/null; then
      # 16 random bytes = 128 bits = 32 hex characters
      od -An -N16 -tx1 /dev/urandom | tr -d ' \n' >"$_machine_id"
      printf '\n' >>"$_machine_id"
    fi
  fi

  system_upgrade_prepare

  local _ok=0 _attempt
  case "${BASE_OS_MODE:-additive}" in
    upgrade)
      step "Upgrading base OS"
      log "Base OS mode: upgrade"
      log "Running full system upgrade (pacman -Syu)"

      for _attempt in 1 2 3; do
        if system_upgrade; then
          _ok=1
          break
        fi
        warn "System upgrade attempt $_attempt failed"
        sleep "$((_attempt * 2))"
      done

      if ((_ok)); then
        log "System upgrade completed successfully"
      else
        die "System upgrade failed after retries; refusing to install current-repository hardware packages onto the old base"
      fi
      ;;

    additive)
      step "Refreshing package databases"
      log "Base OS mode: additive"
      log "Refreshing package databases only (pacman -Sy)"
      log "Base OS packages will not be proactively upgraded"

      for _attempt in 1 2 3; do
        if pacman_sync_db --root "$MNT"; then
          _ok=1
          break
        fi
        warn "Package database sync attempt $_attempt failed"
        sleep "$((_attempt * 2))"
      done

      if ((_ok)); then
        log "Package databases synchronized"
      else
        die "Package database sync failed after retries"
      fi
      ;;
  esac

  system_upgrade_cleanup

  # Discover kernel version — needed for NVIDIA/header installation in both modes
  discover_neptune_kver "$MNT"
  discover_kernel_pkg "$MNT"
  construct_hdr_url "$MNT"
  log "Build kernel: $KVER ($(basename "$HDR_URL"))"

  progress_emit sysupgrade

  return 0
}

# Phase: Create build overlay (on top of updated $MNT)
phase_build_overlay() {
  stage_header "build & install"
  # Create overlay filesystem for build environment
  # This overlay sits on top of the already-updated $MNT
  setup_overlay_chroot
  progress_emit setup_chroot

  return 0
}

# Phase: Build and install drivers
phase_build_build() {
  # Build framework setup
  source "$SCRIPT_DIR/lib/build/engine.sh"
  source "$SCRIPT_DIR/lib/build/repository.sh"
  source "$SCRIPT_DIR/lib/build/verify.sh"
  source "$SCRIPT_DIR/lib/build/backends/arch-devtools.sh"
  source "$SCRIPT_DIR/lib/build/backends/overlay-chroot.sh"
  source "$SCRIPT_DIR/lib/build/profiles/steamos.sh"

  export _build_framework_ready=0
  if build_profile_from_root "$MERGED"; then
    _build_framework_ready=1
    log "Build framework initialized (profile: ${PROFILE_DIR:-unknown})"
  else
    warn "Failed to derive build profile — recipe builds will be skipped"
  fi

  # Install all hardware packages, drivers, kernel modules, and flatpaks
  step "Installing hardware packages and drivers"

  # Snapshot package state before hardware install (name-only for comm baseline)
  local _hw_before="$WORKDIR/hw-pkgs-before.txt"
  local _hw_before_full="$WORKDIR/hw-pkgs-before-full.txt"
  pacman -Q --dbpath "$MERGED/usr/lib/holo/pacmandb" 2>/dev/null \
    | LC_ALL=C sort >"$_hw_before_full"
  awk '{print $1}' "$_hw_before_full" | LC_ALL=C sort -u >"$_hw_before"

  install_hw_libs

  # Propagate package-owned files from overlay to image
  # (install_hw_libs installs into $MERGED overlay; files must be copied to $MNT)
  local _hw_after="$WORKDIR/hw-pkgs-after.txt"
  local _hw_after_full="$WORKDIR/hw-pkgs-after-full.txt"
  pacman -Q --dbpath "$MERGED/usr/lib/holo/pacmandb" 2>/dev/null \
    | LC_ALL=C sort >"$_hw_after_full"
  awk '{print $1}' "$_hw_after_full" | LC_ALL=C sort -u >"$_hw_after"

  # Detect new packages (names not in before) and removed packages (names not in after)
  local _hw_new_pkgs_file="$WORKDIR/hw-new-pkgs.txt"
  LC_ALL=C comm -13 "$_hw_before" "$_hw_after" >"$_hw_new_pkgs_file"

  local _hw_removed_pkgs_file="$WORKDIR/hw-removed-pkgs.txt"
  LC_ALL=C comm -23 "$_hw_before" "$_hw_after" >"$_hw_removed_pkgs_file"

  # Also detect packages whose version changed
  declare -A _hw_before_ver=()
  declare -A _hw_after_ver=()
  local _pkg _ver
  while read -r _pkg _ver; do
    _hw_before_ver["$_pkg"]="$_ver"
  done <"$_hw_before_full"
  while read -r _pkg _ver; do
    _hw_after_ver["$_pkg"]="$_ver"
  done <"$_hw_after_full"
  for _pkg in "${!_hw_after_ver[@]}"; do
    if [[ "${_hw_before_ver[$_pkg]:-}" != "${_hw_after_ver[$_pkg]}" ]]; then
      if ! grep -qxF "$_pkg" "$_hw_new_pkgs_file"; then
        echo "$_pkg" >>"$_hw_new_pkgs_file"
      fi
    fi
  done

  local _hw_new_count
  _hw_new_count=$(wc -l <"$_hw_new_pkgs_file")

  local _hw_removed_count
  _hw_removed_count=$(wc -l <"$_hw_removed_pkgs_file")

  # Remove replaced packages from image BEFORE copying new ones.
  if ((_hw_removed_count > 0)); then
    log "Removing $_hw_removed_count replaced package(s) from image"

    local -a _hw_removed_pkgs=()
    mapfile -t _hw_removed_pkgs <"$_hw_removed_pkgs_file"

    remove_replaced_packages "$MNT" "${_hw_removed_pkgs[@]}"
  fi

  if ((_hw_new_count > 0)); then
    log "Propagating $_hw_new_count new/changed package(s) from overlay to image"
    local _hw_filelist="$WORKDIR/hw-payload-files.txt"
    : >"$_hw_filelist"
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] || continue
      chroot "$MERGED" pacman -Qlq "$pkg" 2>/dev/null >>"$_hw_filelist" || true
    done <"$_hw_new_pkgs_file"

    # Convert to relative paths and rsync
    sed 's|^/||' "$_hw_filelist" >"$_hw_filelist.rel"
    if [[ -s "$_hw_filelist.rel" ]]; then
      rsync -a --force --files-from="$_hw_filelist.rel" "$MERGED/" "$MNT/"
    fi

    # Register packages in the image's pacman db
    local _hw_upper="${UPPER:?UPPER is not set}"
    if [[ -d "$_hw_upper/usr/lib/holo/pacmandb/local" ]]; then
      local -a _hw_new_pkgs=()
      mapfile -t _hw_new_pkgs <"$_hw_new_pkgs_file"

      register_payload_pkgs "$MNT" "$_hw_upper" "${_hw_new_pkgs[@]}"
    fi

    # Copy pacman keyring (not owned by any package)
    if [[ -d "$MERGED/etc/pacman.d/gnupg" ]]; then
      mkdir -p "$MNT/etc/pacman.d"
      rsync -a "$MERGED/etc/pacman.d/gnupg/" "$MNT/etc/pacman.d/gnupg/"
    fi

    # Verify propagated packages in final image match overlay
    local _hw_total _hw_verified=0 _hw_failed=0
    _hw_total=$(wc -l <"$_hw_new_pkgs_file")
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] || continue
      if verify_propagated_package "$pkg"; then
        ((++_hw_verified))
      else
        ((++_hw_failed))
      fi
    done <"$_hw_new_pkgs_file"

    log "Package propagation:"
    log "  added:   $_hw_new_count"
    log "  verified: ${_hw_verified}/${_hw_total}"
    ((_hw_failed == 0)) || die "Propagation verification failed for $_hw_failed package(s)"
  fi

  # Final package-state integrity check
  # Verify that all requested packages match between overlay and image,
  # and that packages intentionally removed by the overlay are absent.
  step "Verifying package-state integrity"
  local _verify_requested=0 _verify_matching=0 _verify_mismatched=0
  local _verify_removed_total=0 _verify_removed_ok=0

  # Check new/changed packages
  if [[ -s "$_hw_new_pkgs_file" ]]; then
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] || continue
      ((++_verify_requested))
      local overlay_state image_state
      overlay_state="$(chroot "$MERGED" pacman -Q "$pkg" 2>/dev/null || true)"
      image_state="$(chroot "$MNT" pacman -Q "$pkg" 2>/dev/null || true)"
      if [[ "$overlay_state" == "$image_state" && -n "$overlay_state" ]]; then
        ((++_verify_matching))
      else
        ((++_verify_mismatched))
        warn "Package-state mismatch:"
        warn "  package: $pkg"
        warn "  overlay: ${overlay_state:-missing}"
        warn "  image:   ${image_state:-missing}"
      fi
    done <"$_hw_new_pkgs_file"
  fi

  # Verify packages intentionally removed by the overlay are absent from $MNT
  if [[ -s "$_hw_removed_pkgs_file" ]]; then
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] || continue
      ((++_verify_removed_total))
      if ! chroot "$MNT" pacman -Q "$pkg" &>/dev/null; then
        ((++_verify_removed_ok))
      else
        warn "Removed package still present in image: $pkg"
        ((++_verify_mismatched))
      fi
    done <"$_hw_removed_pkgs_file"
  fi

  log "Package-state verification:"
  log "  requested packages: $_verify_requested"
  log "  matching:           $_verify_matching"
  log "  mismatched:         $_verify_mismatched"
  if ((_verify_removed_total > 0)); then
    log "  removed (absent):   $_verify_removed_ok/$_verify_removed_total"
  fi
  ((_verify_mismatched == 0)) || die "Package-state verification failed: $_verify_mismatched mismatched package(s)"

  # Install NVIDIA modprobe config if nvidia is selected
  if nvidia_is_selected; then
    local _nvidia_conf="etc/modprobe.d/99-nvidia-patch.conf"
    if [[ ! -s "$MERGED/$_nvidia_conf" ]]; then
      log "Installing nvidia modprobe config"
      install -Dm644 "$SCRIPT_DIR/lib/configs/99-nvidia-patch.conf" "$MERGED/$_nvidia_conf"
    fi

    # Verify and propagate NVIDIA modprobe config to image
    if [[ -s "$MERGED/$_nvidia_conf" ]]; then
      install -Dm644 "$MERGED/$_nvidia_conf" "$MNT/$_nvidia_conf"
    else
      die "NVIDIA modprobe config was not generated in build overlay"
    fi

    [[ -s "$MNT/$_nvidia_conf" ]] || die "Failed to persist NVIDIA modprobe config to image"

    log "NVIDIA modprobe config persistence:"
    log "  overlay: $([[ -s "$MERGED/$_nvidia_conf" ]] && echo yes || echo no)"
    log "  image:   $([[ -s "$MNT/$_nvidia_conf" ]] && echo yes || echo no)"
  else
    log "NVIDIA not requested — skipping NVIDIA modprobe configuration"
  fi

  progress_emit build_hid

  # Copy built modules from build overlay to $MNT
  step "Copying built modules to image"
  copy_built_modules_to_image
  progress_emit copy_modules

  return 0
}

# Phase: Configure system and GRUB
phase_build_configure() {
  stage_header "configure"
  # Apply all customizations dynamically from config
  step "Applying customizations"
  local all_items
  all_items="$(get_all_customization_items)"
  if [[ -n "$all_items" ]]; then
    apply_customizations "$all_items" "build" "$MNT"
  fi
  _diag_os_release "after apply_customizations"

  # Configure update channel
  configure_update_channel
  _diag_os_release "after configure_update_channel"

  # Reconcile initramfs
  step "Restoring module autoloading in initramfs"
  reconcile_initramfs "$MNT" "$KVER" "${INITRAMFS_MODULES:-}"

  # Configure GRUB
  patch_persistent_defaults
  patch_kernel_cmdline
  finalize_grub
  progress_emit configure_grub

  # Apply update strategy (self-heal machinery)
  apply_update_strategy

  # Persist project files to /home for later re-run.
  # Always persist when selfheal mode is active (runtime needs the files),
  # otherwise respect PERSIST_BUILDER (default: enabled).
  if [[ "${PERSIST_BUILDER:-1}" -eq 1 || "${UPDATE_MODE:-}" == selfheal ]]; then
    ensure_project_persisted "$SCRIPT_DIR" "$HOMEMNT"

    # Persist user's build config to /home for repatch to source
    if [[ -n "${CONFIG_FILE:-}" && -f "$CONFIG_FILE" ]]; then
      cp -f "$CONFIG_FILE" "$HOMEMNT/.steamos-build/build.conf"
      log "Build config persisted to /home/.steamos-build/build.conf"
    fi
  else
    log "Skipping builder persistence (PERSIST_BUILDER=0)"
  fi

  # Install log collector and one-click installer
  inject_log_collector
  install_one_click_installer
  progress_emit patch_installer

  # Configure desktop session
  if [[ -n "$DEFAULT_SESSION" ]]; then
    configure_desktop_session "$MNT" "$DEFAULT_SESSION"
  fi

  # Run custom script in chroot if present
  run_custom_script "$MNT"

  return 0
}

# Phase: Finalize and publish image
phase_build_finalize() {
  stage_header "finalize"
  # Restore empty machine-id before publishing — don't bake build-time ID into image
  if [[ "${_MACHINE_ID_WAS_EMPTY:-0}" -eq 1 ]]; then
    log "Restoring empty machine-id (build-time ID was temporary)"
    : >"$MNT/etc/machine-id"
  fi

  _diag_os_release "before finalize"
  cleanup_disk_space "$MNT" "image-finalize"
  progress_emit finalize
  finalize

  # Write manifest alongside image (copy of user's config for reference)
  local manifest="${OUT}.conf"
  if [[ -n "${CONFIG_FILE:-}" && -f "$CONFIG_FILE" ]]; then
    cp -f "$CONFIG_FILE" "$manifest"
    log "Build manifest written: $manifest"
  fi

  # finalize() already ran cleanup() and set _cleanup_done=1.
  # Emit the progress event so the yad window shows the phase.
  progress_emit cleanup

  # Snapshot system state after cleanup and compare with before-build state
  local _state_before="/tmp/.steamos-build-state-before-$$"
  local _state_after="/tmp/.steamos-build-state-after-$$"
  snapshot_system_state "$_state_after"
  compare_system_state "$_state_before" "$_state_after" "build hygiene" || true
  rm -f "$_state_before" "$_state_after"

  return 0
}
