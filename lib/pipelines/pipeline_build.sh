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
  # Log the build configuration
  if [[ -n "${CONFIG_FILE:-}" && -f "$CONFIG_FILE" ]]; then
    log "Build config: $CONFIG_FILE"
    log "────────────────────────────────────────────"
    while IFS="" read -r line; do
      [[ -n "$line" ]] && log "  $line"
    done <"$CONFIG_FILE"
    log "────────────────────────────────────────────"
  else
    log "No config file — using defaults"
  fi

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

  # Persistent mount tracking — survives killed processes.
  MOUNTS_FILE="$WORKDIR/mounts"

  # Clear stale state and create directories
  setup_clear_stale_state
  setup_dirs

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
  install_hw_libs
  progress_emit install_hw

  # Build framework setup
  source "$SCRIPT_DIR/lib/build/engine.sh"
  source "$SCRIPT_DIR/lib/build/repository.sh"
  source "$SCRIPT_DIR/lib/build/verify.sh"
  source "$SCRIPT_DIR/lib/build/backends/arch-devtools.sh"
  source "$SCRIPT_DIR/lib/build/backends/overlay-chroot.sh"
  source "$SCRIPT_DIR/lib/build/profiles/steamos.sh"

  local _build_framework_ready=0
  if build_profile_from_root "$MERGED"; then
    _build_framework_ready=1
    log "Build framework initialized (profile: ${PROFILE_DIR:-unknown})"
  else
    warn "Failed to derive build profile — recipe builds will be skipped"
  fi

  # Build and install custom drivers from hw-packages-build.conf
  step "Building custom drivers"
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

      # Use new framework if available and recipe exists
      if ((_build_framework_ready)) && [[ -d "$recipe_dir" ]]; then
        # Check for INSTALL_CMD — run directly in $MERGED to avoid the
        # build-root overlay swallowing the installed modules.
        local _install_cmd=""
        _install_cmd="$(sed -n 's/^INSTALL_CMD=//p' "$recipe_dir/recipe.conf" 2>/dev/null | tr -d '"' | head -1)"

        if [[ -n "$_install_cmd" ]]; then
          log "Building $module via direct install in main overlay"
          local _install_args=""
          _install_args="$(sed -n 's/^INSTALL_ARGS=//p' "$recipe_dir/recipe.conf" 2>/dev/null | tr -d '"' | head -1)"

          # Copy recipe sources into $MERGED so the script can find them
          mkdir -p "$MERGED/tmp/build/sources"
          if [[ -d "$recipe_dir/sources" ]]; then
            cp -a "$recipe_dir/sources/." "$MERGED/tmp/build/sources/"
          fi

          # Run the install script directly in the main overlay chroot
          local _script_name
          _script_name="$(basename "$_install_cmd")"
          if [[ -f "$MERGED/tmp/build/sources/$_script_name" ]]; then
            chmod +x "$MERGED/tmp/build/sources/$_script_name"
            if chroot "$MERGED" /bin/bash -c "cd /tmp/build/sources && ./${_script_name} ${_install_args}" 2>&1; then
              log "$module built and installed via direct install"
              # Copy built kernel modules from overlay to raw rootfs.
              # install_payload only rsyncs pacman-owned files, so modules
              # installed by direct-install scripts need explicit copying.
              log "  DIAG: KVER=$KVER"
              log "  DIAG: MERGED updates dir exists: $(test -d "$MERGED/usr/lib/modules/$KVER/updates" && echo yes || echo no)"
              log "  DIAG: MERGED logitech dir: $(ls -d "$MERGED"/usr/lib/modules/*/updates/logitech 2>/dev/null || echo 'not found')"
              if [[ -d "$MERGED/usr/lib/modules/$KVER/updates" ]]; then
                mkdir -p "$MNT/usr/lib/modules/$KVER/updates"
                rsync -a "$MERGED/usr/lib/modules/$KVER/updates/" "$MNT/usr/lib/modules/$KVER/updates/"
                log "  Kernel modules copied to image"
              fi
              # Copy self-heal bundles from overlay to raw rootfs for finalize checks.
              # The build script bundles to /home/.steamos-build/bundles/<name>/.
              local _bundle_src="$MERGED/home/.steamos-build/bundles"
              if [[ -d "$_bundle_src" ]]; then
                log "  Self-heal bundles already persisted to /home/.steamos-build/bundles/"
              fi
            else
              warn "FAILED: $module direct install failed"
            fi
          else
            warn "Install script not found: $_script_name in $recipe_dir/sources/"
          fi
        else
          log "Building $module via build framework"
          if build_recipe --recipe "$recipe_dir" --profile "$PROFILE_DIR" --output "$WORKDIR/packages"; then
            # INSTALL_CMD mode produces no artifact — the script installs directly
            if [[ -n "${BUILD_ARTIFACT:-}" && -f "$BUILD_ARTIFACT" ]]; then
              install_build_artifact "$MERGED" "$BUILD_ARTIFACT"
              log "$module built and installed via framework"
              # Validate the installed artifact
              local _artifact=""
              _artifact="$(sed -n 's/^ARTIFACT=//p' "$recipe_dir/recipe.conf" 2>/dev/null | tr -d '"' | head -1)"
              if [[ -n "$_artifact" ]]; then
                validate_build_artifact "$MERGED" "$BUILD_ARTIFACT" "$_artifact" \
                  || warn "Post-install validation failed for $module"
              fi
              # Persist built package for repatch self-heal
              local _bundle_dir="/home/.steamos-build/bundles/$module"
              mkdir -p "$_bundle_dir"
              cp -f "$BUILD_ARTIFACT" "$_bundle_dir/"
              log "Persisted $module package for self-heal: $_bundle_dir/$(basename "$BUILD_ARTIFACT")"
            else
              log "$module built and installed via direct install (no artifact)"
            fi
          else
            warn "FAILED: $module build via framework failed"
          fi
        fi
        continue
      fi
    done
  fi
  progress_emit build_hid

  # Install flatpak packages from hw-packages-build.conf
  step "Installing flatpak packages"
  install_flatpak_packages "$MNT"

  # Compute and install payload
  compute_payload
  install_payload
  _diag_os_release "after install_payload"
  progress_emit copy_payload

  # Apply all customizations dynamically from config
  step "Applying customizations"
  local all_items
  all_items="$(get_all_customization_items)"
  if [[ -n "$all_items" ]]; then
    apply_customizations "$all_items" "build" "$MNT"
  fi
  _diag_os_release "after apply_customizations"

  # Configure update channel — MUST run after install_payload and
  # apply_customizations.  install_payload rsyncs from the overlay ($MERGED)
  # to the raw rootfs ($MNT); if the overlay upper contains a stale copy of
  # /etc/os-release (from a package that owns it), the rsync overwrites our
  # variant/branch stamps.  Running configure_update_channel last ensures our
  # writes are the final word on os-release, manifest.json, and OOBE state.
  configure_update_channel
  _diag_os_release "after configure_update_channel"

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
    cp -f "$CONFIG_FILE" "$HOMEMNT/.steamos-build/build.conf"
    log "Build config persisted to /home/.steamos-build/build.conf"
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
  _diag_os_release "before finalize"
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
