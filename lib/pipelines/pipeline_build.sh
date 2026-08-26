#!/bin/bash
#
# steamos-nvidia-installer — lib/pipelines/pipeline_build.sh
# Build workflow pipeline definition.
# Defines the phases for creating a patched NVIDIA SteamOS image.
#
# Sourced by backend.sh — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/pipelines/pipeline_build.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Pipeline Definition
# ---------------------------------------------------------------------------

register_build_pipeline() {
  define_pipeline \
    "validate" \
    "setup" \
    "prepare" \
    "overlay" \
    "install" \
    "configure" \
    "finalize"

  register_phase "validate" "phase_build_validate" "Validate build inputs"
  register_phase "setup" "phase_build_setup" "Set up build environment"
  register_phase "prepare" "phase_build_prepare" "Prepare rootfs and partitions"
  register_phase "overlay" "phase_build_overlay" "Create overlay chroot"
  register_phase "install" "phase_build_install" "Install drivers and packages"
  register_phase "configure" "phase_build_configure" "Configure system and GRUB"
  register_phase "finalize" "phase_build_finalize" "Finalize and publish image"
}

# ---------------------------------------------------------------------------
# Phase Implementations
# ---------------------------------------------------------------------------

# Phase: Validate build inputs
phase_build_validate() {
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

  return 0
}

# Phase: Set up build environment
phase_build_setup() {
  # Resolve workdir
  setup_resolve_workdir

  # Set up directory structure
  MNT="$WORKDIR/mnt"
  EFIMNT="$WORKDIR/efi"
  HOMEMNT="$WORKDIR/home"
  UPPER="$WORKDIR/upper"
  OVLWORK="$WORKDIR/ovlwork"
  MERGED="$WORKDIR/merged"
  OVL_IMG="$WORKDIR/overlay-work.img"
  OVL_MNT="$WORKDIR/overlay-mnt"
  OVL_LOOPDEV=""

  # Clear stale state and create directories
  setup_clear_stale_state
  setup_dirs

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

# Phase: Create overlay chroot
phase_build_overlay() {
  # Derive build-flag items from GAMING_ITEMS before overlay setup so that
  # FIX_KEYRING and SKIP_SIG are available to setup_overlay_chroot().
  # These items only set flags — the real customisation pass runs later in
  # Phase 5 (install), but the flags must be visible during Phase 4.
  if [[ -n "${GAMING_ITEMS:-}" ]]; then
    [[ " $GAMING_ITEMS " == *" fix-keyring "* ]] && export FIX_KEYRING=1
    [[ " $GAMING_ITEMS " == *" skip-sigcheck "* ]] && export SKIP_SIG=1
  fi

  # Create overlay filesystem for chroot
  setup_overlay_chroot
  progress_emit setup_chroot

  # Install kernel headers
  install_kernel_headers

  return 0
}

# Phase: Install drivers and packages
phase_build_install() {
  # Clear transaction scratch files from any previous run
  : >"$WORKDIR/build-only-exclusions.txt"
  : >"$WORKDIR/custom-payload-files.txt"

  # Install hardware packages (NVIDIA + optional)
  mkdir -p "$MNT/usr/lib/steamos-nvidia"
  ln -sfn "$SCRIPT_DIR/lib/configs" "$MNT/usr/lib/steamos-nvidia/configs"
  install_hw_libs
  progress_emit install_hw

  # Build framework setup (used when USE_BUILD_FRAMEWORK=1)
  local _build_framework_ready=0
  if [[ "${USE_BUILD_FRAMEWORK:-0}" -eq 1 ]]; then
    # Source the build framework
    source "$SCRIPT_DIR/lib/build/engine.sh"
    source "$SCRIPT_DIR/lib/build/repository.sh"
    source "$SCRIPT_DIR/lib/build/verify.sh"
    source "$SCRIPT_DIR/lib/build/backends/arch-devtools.sh"
    source "$SCRIPT_DIR/lib/build/backends/overlay-chroot.sh"
    source "$SCRIPT_DIR/lib/build/profiles/steamos.sh"

    # Derive profile from target rootfs
    if build_profile_from_root "$MERGED"; then
      _build_framework_ready=1
      log "Build framework initialized (profile: ${PROFILE_DIR:-unknown})"
    else
      warn "Failed to derive build profile — falling back to legacy build"
    fi
  fi

  # Build and install custom drivers from hw-packages-build.conf
  step "Building custom drivers"
  local kernel_modules
  kernel_modules="$(get_build_items "kernel-module")"
  if [[ -n "$kernel_modules" ]]; then
    for module in $kernel_modules; do
      local recipe_dir="$SCRIPT_DIR/recipes/$module"

      # Use new framework if available and recipe exists
      if ((_build_framework_ready)) && [[ -d "$recipe_dir" ]]; then
        log "Building $module via build framework"
        if build_recipe --recipe "$recipe_dir" --profile "$PROFILE_DIR" --output "$WORKDIR/packages"; then
          install_build_artifact "$MERGED" "$BUILD_ARTIFACT"
          log "$module built and installed via framework"
        else
          warn "FAILED: $module build via framework failed"
        fi
        continue
      fi

      # Legacy build path
      case "$module" in
        logitech-hid)
          fetch_hid_sources
          build_hid
          # Bundle HID sources for self-heal
          if [[ -n "${DRIVER_SRC_DIR:-}" && -d "$DRIVER_SRC_DIR" ]]; then
            local hid_bundle="$MNT/usr/lib/steamos-nvidia/hid"
            mkdir -p "$hid_bundle"
            cp -a "$DRIVER_SRC_DIR/." "$hid_bundle/"
            # Also persist to /home for rebuild to use
            local hid_home="/home/.steamos-nvidia/bundles/hid"
            mkdir -p "$hid_home"
            cp -a "$DRIVER_SRC_DIR/." "$hid_home/"
            log "HID source bundle created for self-heal"
          fi
          ;;
        aotofu-vaapi)
          if apply_aotofu_vaapi_build "$WORKDIR" "$MERGED"; then
            # Bundle source for self-heal (separate from state directory)
            local aotofu_bundle="$MNT/usr/lib/steamos-nvidia/aotofu-vaapi/source"
            if [[ -d "$WORKDIR/aotofu-src" ]]; then
              mkdir -p "$aotofu_bundle"
              cp -a "$WORKDIR/aotofu-src/." "$aotofu_bundle/"
              # Also persist to /home for rebuild to use
              local aotofu_home="/home/.steamos-nvidia/bundles/aotofu-vaapi/source"
              mkdir -p "$aotofu_home"
              cp -a "$WORKDIR/aotofu-src/." "$aotofu_home/"
              log "AoTofu source bundle created for self-heal"
            fi
          else
            warn "FAILED: aotofu-vaapi build failed"
          fi
          ;;
      esac
    done
  fi
  progress_emit build_hid

  # Install flatpak packages from hw-packages-build.conf
  step "Installing flatpak packages"
  local flatpaks
  flatpaks="$(get_build_items "flatpak")"
  if [[ -n "$flatpaks" ]]; then
    for pkg in $flatpaks; do
      case "$pkg" in
        dlss-updater)
          if apply_dlss_updater_build "$MNT"; then
            log "DLSS Updater: installed or staged for first-boot"
          else
            warn "FAILED: dlss-updater build failed"
          fi
          ;;
      esac
    done
  fi

  # Configure update channel
  configure_update_channel

  # Compute and install payload
  compute_payload
  rm -f "$MNT/usr/lib/steamos-nvidia/configs"
  install_payload
  progress_emit copy_payload

  # Apply all customizations dynamically from config
  step "Applying customizations"
  local all_items
  all_items="$(get_all_customization_items)"
  if [[ -n "$all_items" ]]; then
    apply_customizations "$all_items" "build" "$MNT"
  fi

  return 0
}

# Phase: Configure system and GRUB
phase_build_configure() {
  # Configure GRUB
  patch_persistent_defaults
  patch_kernel_cmdline
  finalize_grub
  progress_emit configure_grub

  # Apply update strategy (self-heal machinery)
  apply_update_strategy

  # Persist project files to /home for later re-run
  ensure_project_persisted "$SCRIPT_DIR" "$HOMEMNT"

  # Persist user's build config to /home for repatch to source
  if [[ -n "${CONFIG_FILE:-}" && -f "$CONFIG_FILE" ]]; then
    cp -f "$CONFIG_FILE" "$HOMEMNT/.steamos-nvidia/build.conf"
    log "Build config persisted to /home/.steamos-nvidia/build.conf"
  fi

  # Install log collector and one-click installer
  inject_log_collector
  install_one_click_installer
  progress_emit patch_installer

  # Configure desktop session
  if [[ -n "$DEFAULT_SESSION" ]]; then
    configure_desktop_session "$MNT" "$DEFAULT_SESSION"
  fi

  return 0
}

# Phase: Finalize and publish image
phase_build_finalize() {
  progress_emit finalize
  finalize

  # Write manifest alongside image (copy of user's config for reference)
  local manifest="${OUT}.conf"
  if [[ -n "${CONFIG_FILE:-}" && -f "$CONFIG_FILE" ]]; then
    cp -f "$CONFIG_FILE" "$manifest"
    log "Build manifest written: $manifest"
  fi

  return 0
}
