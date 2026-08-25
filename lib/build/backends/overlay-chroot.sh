#!/bin/bash
#
# steamos-nvidia-installer — lib/build/backends/overlay-chroot.sh
# Build backend using overlay mounts and chroot (no devtools required).
#
# This backend uses the same approach as the existing installer:
# overlay mount + chroot, which works on SteamOS without arch-install-scripts.
#
# Sourced by engine.sh — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/build/backends/overlay-chroot.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Guard against double-sourcing
[[ -v _BUILD_OVERLAY_LOADED ]] && return 0
_BUILD_OVERLAY_LOADED=1

# ---------------------------------------------------------------------------
# Backend interface
# ---------------------------------------------------------------------------

# Create a clean build root using overlay mount.
# Args: $1 = name, $2 = profile dir
# Prints: path to build root directory (to stdout)
_build_overlay_create_root() {
  local name="${1:?}"
  local profile="${2:?}"

  local build_dir="${WORKDIR:-/tmp}/build-roots/$name-$$"
  mkdir -p "$build_dir"/{upper,ovlwork,merged}

  local profile_root="${PROFILE_ROOT:?profile must set PROFILE_ROOT}"

  log "  Creating overlay build root: $build_dir" >&2
  log "    lower: $profile_root" >&2
  log "    upper: $build_dir/upper" >&2

  # Mount overlay
  mount -t overlay overlay \
    -o "lowerdir=$profile_root,upperdir=$build_dir/upper,workdir=$build_dir/ovlwork" \
    "$build_dir/merged" || {
    warn "Failed to mount overlay" >&2
    return 1
  }

  # Mount essential filesystems
  mount --bind /dev "$build_dir/merged/dev" || true
  mount --bind /dev/pts "$build_dir/merged/dev/pts" || true
  mount --bind /dev/shm "$build_dir/merged/dev/shm" || true
  mount --bind /proc "$build_dir/merged/proc" || true
  mount --bind /sys "$build_dir/merged/sys" || true

  log "  Overlay build root created" >&2
  echo "$build_dir"
}

# Destroy a build root.
# Args: $1 = build root directory
_build_overlay_destroy_root() {
  local build_dir="${1:?}"

  if [[ -d "$build_dir" ]]; then
    log "  Destroying build root: $build_dir" >&2

    # Unmount in reverse order, handling nested mounts
    local merged="$build_dir/merged"

    # Unmount all children of merged first (deepest first)
    if mountpoint -q "$merged" 2>/dev/null; then
      # Unmount nested filesystems
      umount -R "$merged/dev" 2>/dev/null || true
      umount -R "$merged/proc" 2>/dev/null || true
      umount -R "$merged/sys" 2>/dev/null || true
      umount -R "$merged/tmp" 2>/dev/null || true

      # Unmount the overlay itself
      umount -R "$merged" 2>/dev/null || true
    fi

    # Remove directory
    rm -rf "$build_dir"
  fi
}

# Sync build root with profile (update repos, install build deps).
# Args: $1 = build root directory
_build_overlay_sync_root() {
  local build_dir="${1:?}"
  local root="$build_dir/merged"
  local pacman_conf="${PROFILE_PACMAN:?}"

  log "  Syncing build root"

  # Copy pacman.conf into the root
  cp "$pacman_conf" "$root/etc/pacman.conf"

  # Refresh package database (Valve repos are required, Arch repos are optional)
  local sync_output
  sync_output="$(chroot "$root" pacman -Sy 2>&1)" || true

  # Check if at least the Valve repos synced
  if echo "$sync_output" | grep -q "core-3.8\|holo-3.8\|jupiter-3.8"; then
    log "  Valve repos synced successfully"
  else
    # Try with just the Valve repos by temporarily removing Arch repos
    local conf_backup="$root/etc/pacman.conf.bak"
    cp "$root/etc/pacman.conf" "$conf_backup"

    # Remove Arch repo sections
    sed -i '/^\[core\]/,/^\[/ { /^\[core\]/d; /^Server.*geo.mirror.pkgbuild.com/d; }' "$root/etc/pacman.conf"
    sed -i '/^\[extra\]/,/^\[/ { /^\[extra\]/d; /^Server.*geo.mirror.pkgbuild.com/d; }' "$root/etc/pacman.conf"
    sed -i '/^\[multilib\]/,/^\[/ { /^\[multilib\]/d; /^Server.*geo.mirror.pkgbuild.com/d; }' "$root/etc/pacman.conf"

    sync_output="$(chroot "$root" pacman -Sy 2>&1)" || true
    mv "$conf_backup" "$root/etc/pacman.conf"

    if echo "$sync_output" | grep -q "core-3.8\|holo-3.8\|jupiter-3.8"; then
      log "  Valve repos synced (Arch repos unavailable)"
    else
      warn "Failed to sync any repos"
      echo "$sync_output" | tail -5 | while IFS= read -r line; do
        warn "  $line"
      done
      return 1
    fi
  fi

  return 0
}

# Inject recipe sources into build root.
# Args: $1 = build root directory, $2 = recipe directory
_build_overlay_inject_sources() {
  local build_dir="${1:?}"
  local recipe_dir="${2:?}"
  local root="$build_dir/merged"

  log "  Injecting recipe sources"

  # Create build directory in the root
  mkdir -p "$root/tmp/build"
  cp "$recipe_dir/PKGBUILD" "$root/tmp/build/"

  # Copy patches if they exist
  if [[ -d "$recipe_dir/patches" ]]; then
    cp -r "$recipe_dir/patches" "$root/tmp/build/"
  fi

  # Copy any additional source files
  if [[ -d "$recipe_dir/sources" ]]; then
    cp -r "$recipe_dir/sources" "$root/tmp/build/"
  fi

  return 0
}

# Run the build using makepkg.
# Args: $1 = build root directory, $2 = recipe directory, $3 = output directory
_build_overlay_run() {
  local build_dir="${1:?}"
  local recipe_dir="${2:?}"
  local output_dir="${3:?}"
  local root="$build_dir/merged"

  log "  Running build"

  # Ensure output directory exists
  mkdir -p "$output_dir"

  # Install build dependencies
  log "  Installing build dependencies"
  chroot "$root" pacman -S --noconfirm --needed base-devel 2>&1 | tail -5 || {
    warn "Failed to install build dependencies"
    return 1
  }

  # Build with makepkg (as nobody user for safety)
  local build_log="$output_dir/build.log"

  (
    cd "$root/tmp/build" || exit 1
    chroot "$root" /bin/bash -c '
      cd /tmp/build
      # Run makepkg as nobody
      su nobody -s /bin/bash -c "makepkg -s --noconfirm --noprogressbar" 2>&1
    '
  ) | tee "$build_log" || {
    warn "Build failed — see log: $build_log"
    return 1
  }

  # Move any .pkg.tar.* from build dir to output_dir
  find "$root/tmp/build" -maxdepth 1 -name '*.pkg.tar.*' -type f -exec cp {} "$output_dir/" \; 2>/dev/null || true

  return 0
}
