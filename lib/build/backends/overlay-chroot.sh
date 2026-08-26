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
# Uses a loopback image (ext4) for the overlay workspace to avoid
# casefold issues on SteamOS's /home partition.
# Args: $1 = name, $2 = profile dir
# Prints: path to build root directory (to stdout)
_build_overlay_create_root() {
  local name="${1:?}"
  local profile="${2:?}"

  local build_dir="${WORKDIR:-/tmp}/build-roots/$name-$$"
  mkdir -p "$build_dir"

  local profile_root="${PROFILE_ROOT:?profile must set PROFILE_ROOT}"

  log "  Creating overlay build root: $build_dir" >&2
  log "    lower: $profile_root" >&2

  # Create a loopback image for the overlay workspace (avoids casefold issues)
  local ovl_img="$build_dir/overlay-work.img"
  local ovl_mnt="$build_dir/overlay-mnt"
  local merged="$build_dir/merged"

  mkdir -p "$ovl_mnt" "$merged"

  log "    Creating overlay workspace image (2G)" >&2
  truncate -s 2G "$ovl_img"
  mkfs.ext4 -q -F "$ovl_img"

  local ovl_loop
  ovl_loop="$(losetup --find --show --nooverlap "$ovl_img")" || {
    warn "Failed to attach loop device for overlay workspace" >&2
    return 1
  }

  mount -t ext4 "$ovl_loop" "$ovl_mnt" || {
    warn "Failed to mount overlay workspace" >&2
    losetup -d "$ovl_loop" 2>/dev/null
    return 1
  }

  mkdir -p "$ovl_mnt/upper" "$ovl_mnt/ovlwork"

  # Mount overlay
  mount -t overlay overlay \
    -o "lowerdir=$profile_root,upperdir=$ovl_mnt/upper,workdir=$ovl_mnt/ovlwork" \
    "$merged" || {
    warn "Failed to mount overlay" >&2
    umount "$ovl_mnt" 2>/dev/null
    losetup -d "$ovl_loop" 2>/dev/null
    return 1
  }

  # Mount essential filesystems
  mount --bind /dev "$merged/dev" || true
  mount --bind /dev/pts "$merged/dev/pts" || true
  mount --bind /dev/shm "$merged/dev/shm" || true
  mount --bind /proc "$merged/proc" || true
  mount --bind /sys "$merged/sys" || true

  log "  Overlay build root created" >&2
  echo "$build_dir"
}

# Destroy a build root.
# Uses strict cleanup: refuses to proceed if unmount fails, waits for
# ext4 superblock release, and verifies loop detachment.
# Args: $1 = build root directory
_build_overlay_destroy_root() {
  local build_dir="${1:?}"

  [[ -d "$build_dir" ]] || return 0

  log "  Destroying build root: $build_dir" >&2

  local rc=0
  local merged="$build_dir/merged"
  local ovl_mnt="$build_dir/overlay-mnt"
  local ovl_img="$build_dir/overlay-work.img"

  # ------------------------------------------------------------
  # 1. Kill known chroot daemons before touching mount topology.
  # ------------------------------------------------------------
  if [[ -d "$merged/etc/pacman.d/gnupg" ]]; then
    gpgconf --homedir "$merged/etc/pacman.d/gnupg" --kill gpg-agent >/dev/null 2>&1 || true
  fi

  # ------------------------------------------------------------
  # 2. Unmount child mounts inside the overlay (deepest first).
  # ------------------------------------------------------------
  if mountpoint -q "$merged" 2>/dev/null; then
    local m
    for m in \
      "$merged/dev/pts" \
      "$merged/dev/shm" \
      "$merged/dev" \
      "$merged/sys" \
      "$merged/proc" \
      "$merged/tmp"; do
      [[ -e "$m" ]] || continue
      if mountpoint -q "$m" 2>/dev/null; then
        if ! strict_unmount "$m" "build root child"; then
          rc=1
        fi
      fi
    done
  fi

  if ((rc != 0)); then
    warn "_build_overlay_destroy_root: child mounts remain; refusing to tear down overlay"
    return 1
  fi

  # ------------------------------------------------------------
  # 3. Unmount the overlay (MERGED).
  # ------------------------------------------------------------
  if mountpoint -q "$merged" 2>/dev/null; then
    if ! strict_unmount "$merged" "build root overlay"; then
      rc=1
    fi
  fi

  if ((rc != 0)); then
    warn "_build_overlay_destroy_root: overlay still mounted"
    return 1
  fi

  # ------------------------------------------------------------
  # 4. Unmount the ext4 overlay workspace.
  # ------------------------------------------------------------
  if mountpoint -q "$ovl_mnt" 2>/dev/null; then
    if ! strict_unmount "$ovl_mnt" "build root workspace"; then
      rc=1
    fi
  fi

  # ------------------------------------------------------------
  # 5. Find loop devices by backing file and wait for ext4 release.
  # ------------------------------------------------------------
  local loops=""
  # Always search by path — loops_for_file handles the (deleted) suffix
  loops="$(loops_for_file "$ovl_img")"

  # Also check by the (deleted) path the kernel may still hold
  if [[ -z "$loops" ]]; then
    loops="$(losetup -j "$ovl_img" 2>/dev/null | cut -d: -f1)"
  fi

  while IFS= read -r loop; do
    [[ -n "$loop" ]] || continue

    if ! wait_ext4_gone "$loop"; then
      warn "_build_overlay_destroy_root: $loop still owns a live ext4 superblock"
      warn "_build_overlay_destroy_root: refusing losetup -d; reboot may be required"
      rc=1
    fi
  done <<<"$loops"

  if ((rc != 0)); then
    return 1
  fi

  # ------------------------------------------------------------
  # 6. Detach loop devices.
  # ------------------------------------------------------------
  while IFS= read -r loop; do
    [[ -n "$loop" ]] || continue

    if ! strict_detach_loop "$loop"; then
      rc=1
    fi
  done <<<"$loops"

  # ------------------------------------------------------------
  # 7. Remove build directory only if cleanup succeeded.
  # ------------------------------------------------------------
  if ((rc == 0)); then
    rm -rf "$build_dir"
  else
    warn "_build_overlay_destroy_root: preserving $build_dir due to cleanup errors"
  fi

  return "$rc"
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
  chmod 777 "$root/tmp/build"

  # Copy patches if they exist
  if [[ -d "$recipe_dir/patches" ]]; then
    cp -r "$recipe_dir/patches" "$root/tmp/build/"
  fi

  # Copy any additional source files
  if [[ -d "$recipe_dir/sources" ]]; then
    cp -r "$recipe_dir/sources" "$root/tmp/build/"
  fi

  # Fetch source from recipe.conf SOURCE_URL if specified
  local recipe_conf="$recipe_dir/recipe.conf"
  if [[ -f "$recipe_conf" ]]; then
    local source_url="" source_ref="main" source_type="git" source_dir=""
    local install_cmd=""
    source_url="$(sed -n 's/^SOURCE_URL=//p' "$recipe_conf" 2>/dev/null | tr -d '"' | head -1)"
    source_ref="$(sed -n 's/^SOURCE_REF=//p' "$recipe_conf" 2>/dev/null | tr -d '"' | head -1)"
    source_type="$(sed -n 's/^SOURCE_TYPE=//p' "$recipe_conf" 2>/dev/null | tr -d '"' | head -1)"
    source_dir="$(sed -n 's/^SOURCE_DIR=//p' "$recipe_conf" 2>/dev/null | tr -d '"' | head -1)"
    install_cmd="$(sed -n 's/^INSTALL_CMD=//p' "$recipe_conf" 2>/dev/null | tr -d '"' | head -1)"
    source_ref="${source_ref:-main}"
    source_type="${source_type:-git}"

    # Determine extraction target based on build mode:
    # - Direct install mode (INSTALL_CMD): extract to /tmp/build/ so INSTALL_CMD can find sources
    # - Package build mode (PKGBUILD): extract to /tmp/build/src/ for makepkg
    local extract_dir="$root/tmp/build/src"
    if [[ -n "$install_cmd" ]]; then
      extract_dir="$root/tmp/build"
    fi

    if [[ -n "$source_url" ]]; then
      log "  Fetching source: $source_url ($source_type)"

      if [[ -d "$recipe_dir/sources/$source_dir" ]]; then
        # Source already bundled in recipe
        mkdir -p "$extract_dir"
        cp -a "$recipe_dir/sources/$source_dir" "$extract_dir/"
      elif [[ "$source_type" == "tarball" ]]; then
        # Download and extract tarball
        local tarball="/tmp/source-$$-$(basename "$source_url")"
        if curl -sL "$source_url" -o "$tarball" 2>&1; then
          mkdir -p "$extract_dir"
          chmod 777 "$extract_dir"
          tar -xzf "$tarball" -C "$extract_dir/" || {
            warn "Failed to extract tarball"
            rm -f "$tarball"
            return 1
          }
          rm -f "$tarball"
          # Make source writable by nobody (makepkg runs as nobody)
          chown -R nobody:nobody "$extract_dir" 2>/dev/null || true
        else
          warn "Failed to download $source_url"
          return 1
        fi
      elif command -v git &>/dev/null; then
        # Git clone
        local src_name
        src_name="$(basename "$source_url" .git)"
        mkdir -p "$extract_dir"
        chmod 777 "$extract_dir"
        git clone --branch "$source_ref" "$source_url" "$extract_dir/$src_name" 2>&1 | tail -3 || {
          warn "Failed to clone $source_url"
          return 1
        }
        # Make source writable by nobody (makepkg runs as nobody)
        chown -R nobody:nobody "$extract_dir" 2>/dev/null || true
      else
        warn "git not available and source not bundled"
        return 1
      fi
    fi
  fi

  # Copy PKGBUILD if it exists (needed for package build mode)
  if [[ -f "$recipe_dir/PKGBUILD" ]]; then
    cp "$recipe_dir/PKGBUILD" "$root/tmp/build/"
    chmod 666 "$root/tmp/build/PKGBUILD"
  fi

  return 0
}

# Run build environment diagnostics inside the chroot.
# Catches missing headers, broken toolchains, and package integrity issues
# before makepkg runs, making failures much easier to diagnose.
#
# Generic by default. Recipes can define DIAG_PKGS and DIAG_PC_FILES
# in recipe.conf for recipe-specific checks.
#
# Args: $1 = root path, $2 = output directory (for logging), $3 = recipe dir (optional)
# Returns 0 if diagnostics pass, 1 if critical issues found.
_build_overlay_diagnostics() {
  local root="${1:?}"
  local output_dir="${2:-/tmp}"
  local recipe_dir="${3:-}"
  local diag_log="$output_dir/build-diagnostics.log"
  local failed=0

  # Load recipe-specific diagnostic lists if available
  local -a diag_pc_files=()
  local -a diag_pkgs=()
  if [[ -n "$recipe_dir" && -f "$recipe_dir/recipe.conf" ]]; then
    # Source recipe.conf to get DIAG_PC_FILES and DIAG_PKGS
    # Use a subshell to avoid polluting current scope
    local recipe_conf="$recipe_dir/recipe.conf"
    local diag_pc_str diag_pkgs_str
    diag_pc_str="$(sed -n 's/^DIAG_PC_FILES=(//;s/)//p' "$recipe_conf" 2>/dev/null)"
    diag_pkgs_str="$(sed -n 's/^DIAG_PKGS=(//;s/)//p' "$recipe_conf" 2>/dev/null)"

    # Parse arrays from strings
    if [[ -n "$diag_pc_str" ]]; then
      eval "diag_pc_files=($diag_pc_str)"
    fi
    if [[ -n "$diag_pkgs_str" ]]; then
      eval "diag_pkgs=($diag_pkgs_str)"
    fi
  fi

  # Generic toolchain files to always check
  local -a generic_toolchain_files=(
    /usr/include/stdlib.h
    /usr/include/stdint.h
    /usr/include/pthread.h
    /usr/include/sys/ioctl.h
  )

  # Generic build tools to always check
  local -a generic_build_tools=(glibc gcc pkgconf)

  {
    echo "===== BUILD ENVIRONMENT ====="
    chroot "$root" cat /etc/os-release 2>/dev/null | head -5
    echo ""

    echo "===== BUILD TOOLS ====="
    local tool
    for tool in gcc meson ninja pkgconf; do
      local version=""
      case "$tool" in
        gcc)    version="$(chroot "$root" gcc --version 2>/dev/null | head -1)" ;;
        meson)  version="$(chroot "$root" meson --version 2>/dev/null)" ;;
        ninja)  version="$(chroot "$root" ninja --version 2>/dev/null)" ;;
        pkgconf) version="$(chroot "$root" pkg-config --version 2>/dev/null)" ;;
      esac
      if [[ -n "$version" ]]; then
        printf '[OK]      %-12s %s\n' "$tool" "$version"
      else
        printf '[MISSING] %s\n' "$tool"
      fi
    done
    echo ""

    echo "===== TOOLCHAIN FILES ====="
    local file
    for file in "${generic_toolchain_files[@]}"; do
      if [[ -e "$root$file" ]]; then
        printf '[OK]      %s\n' "$file"
      else
        printf '[MISSING] %s\n' "$file"
      fi
    done
    echo ""

    # Recipe-specific pkg-config files
    if [[ ${#diag_pc_files[@]} -gt 0 ]]; then
      echo "===== RECIPE PKG-CONFIG FILES ====="
      for file in "${diag_pc_files[@]}"; do
        local pc_path="/usr/lib/pkgconfig/$file"
        if [[ -e "$root$pc_path" ]]; then
          printf '[OK]      %s\n' "$file"
        else
          printf '[MISSING] %s\n' "$file"
        fi
      done
      echo ""
    fi

    echo "===== COMPILER SANITY ====="
    if printf '#include <stdlib.h>\nint main(void){return 0;}\n' \
      | chroot "$root" cc -x c - -o /tmp/.build-sanity 2>/dev/null; then
      echo "[OK] C toolchain can compile and link"
      chroot "$root" rm -f /tmp/.build-sanity
    else
      echo "[FAILED] C toolchain sanity check"
      printf '#include <stdlib.h>\nint main(void){return 0;}\n' \
        | chroot "$root" cc -v -x c - -o /tmp/.build-sanity 2>&1 || true
      failed=1
    fi
    echo ""

    # Recipe-specific pkg-config checks
    if [[ ${#diag_pc_files[@]} -gt 0 ]]; then
      echo "===== RECIPE PKG-CONFIG ====="
      local dep
      for dep in "${diag_pc_files[@]}"; do
        # Strip .pc suffix for pkg-config query
        local dep_name="${dep%.pc}"
        local version
        if version="$(chroot "$root" pkg-config --modversion "$dep_name" 2>/dev/null)"; then
          printf '[OK]      %-32s %s\n' "$dep_name" "$version"
        else
          printf '[FAILED]  %s\n' "$dep_name"
          chroot "$root" pkg-config --print-errors --exists "$dep_name" 2>&1 | sed 's/^/          /' || true
        fi
      done
      echo ""
    fi

    # Recipe-specific package integrity checks
    if [[ ${#diag_pkgs[@]} -gt 0 ]]; then
      echo "===== RECIPE PACKAGE INTEGRITY ====="
      local pkg
      for pkg in "${diag_pkgs[@]}"; do
        if chroot "$root" pacman -Q "$pkg" >/dev/null 2>&1; then
          local qkk_output altered_count
          qkk_output="$(chroot "$root" pacman -Qkk "$pkg" 2>&1)"
          altered_count="$(echo "$qkk_output" | grep -oE '[1-9][0-9]* altered files' || true)"
          if [[ -n "$altered_count" ]]; then
            echo "[INCOMPLETE] $pkg ($altered_count)"
            echo "$qkk_output" | grep -E 'warning:.*No such file|warning:.*altered' | head -10 | sed 's/^/  /'
          else
            echo "[OK] $pkg"
          fi
        else
          echo "[NOT INSTALLED] $pkg"
        fi
      done
      echo ""
    fi

    echo "===== PACMAN CONFIG ====="
    chroot "$root" grep -Ev '^\s*(#|$)' /etc/pacman.conf 2>/dev/null | head -20 || true
    echo ""

    echo "===== BUILD ENVIRONMENT ====="
    chroot "$root" env | grep -E '^(PKG_CONFIG|CPATH|C_INCLUDE_PATH|CPLUS_INCLUDE_PATH|LIBRARY_PATH|LD_LIBRARY_PATH)=' 2>/dev/null || echo "  (no build env vars set)"
    echo ""
  } >"$diag_log" 2>&1

  # Log diagnostics
  while IFS= read -r line; do
    log "  $line"
  done <"$diag_log"

  return "$failed"
}

# Run the build using makepkg or direct install command.
# Args: $1 = build root directory, $2 = recipe directory, $3 = output directory
_build_overlay_run() {
  local build_dir="${1:?}"
  local recipe_dir="${2:?}"
  local output_dir="${3:?}"
  local root="$build_dir/merged"

  log "  Running build"

  # Ensure output directory exists
  mkdir -p "$output_dir"

  # Load recipe config to determine build mode
  local recipe_conf="$recipe_dir/recipe.conf"
  local install_cmd="" install_args=""
  if [[ -f "$recipe_conf" ]]; then
    install_cmd="$(sed -n 's/^INSTALL_CMD=//p' "$recipe_conf" 2>/dev/null | tr -d '"' | head -1)"
    install_args="$(sed -n 's/^INSTALL_ARGS=//p' "$recipe_conf" 2>/dev/null | tr -d '"' | head -1)"
  fi

  # Install build dependencies (common to both modes).
  # Don't use --needed: SteamOS images may have packages registered as installed
  # but with development files stripped (e.g. glibc headers, egl.pc).
  # Reinstalling without --needed restores the missing files.
  log "  Installing build dependencies"
  chroot "$root" pacman -S --noconfirm base-devel 2>&1 | tail -5 || {
    warn "Failed to install build dependencies"
    return 1
  }

  # Install recipe-specific dependencies based on build mode
  _build_overlay_install_deps "$root" "$recipe_conf" "$install_cmd"

  # Run build environment diagnostics before compiling.
  # Catches missing headers, broken toolchains, and package integrity issues
  # before makepkg runs, making failures much easier to diagnose.
  _build_overlay_diagnostics "$root" "$output_dir" "$recipe_dir" || {
    warn "Build environment diagnostics failed"
    return 1
  }

  local build_log="$output_dir/build.log"

  if [[ -n "$install_cmd" ]]; then
    # Get source directory for direct install mode
    local source_dir=""
    if [[ -f "$recipe_conf" ]]; then
      source_dir="$(sed -n 's/^SOURCE_DIR=//p' "$recipe_conf" 2>/dev/null | tr -d '"' | head -1)"
    fi
    _build_overlay_run_direct "$root" "$install_cmd" "$install_args" "$source_dir" "$build_log" "$output_dir"
  else
    _build_overlay_run_makepkg "$root" "$output_dir" "$build_log"
  fi
}

# Install recipe-specific dependencies.
# Args: $1 = root path, $2 = recipe.conf path, $3 = install_cmd (empty for makepkg mode)
_build_overlay_install_deps() {
  local root="${1:?}"
  local recipe_conf="${2:?}"
  local install_cmd="${3:-}"

  # Extract and install recipe-specific dependencies as root
  # (makepkg -s uses sudo which doesn't work for the nobody user)
  # Don't use --needed: ABI-locked deps from the image may be registered
  # as installed but have development files missing (e.g. egl.pc from libglvnd).
  local deps=""
  if [[ -n "$install_cmd" ]]; then
    # Direct install mode: read deps from recipe.conf
    if [[ -f "$recipe_conf" ]]; then
      deps="$(sed -n 's/^BUILD_DEPS=(//;s/)//p' "$recipe_conf" 2>/dev/null | tr -d '()"')"
      deps+=" $(sed -n 's/^RUNTIME_DEPS=(//;s/)//p' "$recipe_conf" 2>/dev/null | tr -d '()"')"
    fi
  else
    # Package build mode: extract deps from PKGBUILD
    if [[ -f "$root/tmp/build/PKGBUILD" ]]; then
      deps="$(chroot "$root" /bin/bash -c 'cd /tmp/build && source PKGBUILD 2>/dev/null && echo "${makedepends[@]} ${depends[@]}"' 2>/dev/null || true)"
    fi
  fi

  if [[ -n "$deps" ]]; then
    log "  Installing recipe dependencies: $deps"
    chroot "$root" pacman -S --noconfirm $deps 2>&1 | tail -5 || true
  fi
}

# Run direct install mode (INSTALL_CMD from recipe.conf).
# Args: $1 = root path, $2 = install command, $3 = install args, $4 = source dir, $5 = build log path, $6 = output directory
_build_overlay_run_direct() {
  local root="${1:?}"
  local install_cmd="${2:?}"
  local install_args="${3:-}"
  local source_dir="${4:-}"
  local build_log="${5:?}"
  local output_dir="${6:?}"

  # Determine working directory for INSTALL_CMD
  # If SOURCE_DIR is specified, run from that subdirectory; otherwise run from /tmp/build
  local work_dir="/tmp/build"
  if [[ -n "$source_dir" ]]; then
    work_dir="/tmp/build/$source_dir"
  fi

  log "  Using direct install: $install_cmd $install_args (from $work_dir)"
  (
    cd "$root$work_dir" || exit 1
    chroot "$root" /bin/bash -c "
      cd $work_dir
      $install_cmd $install_args 2>&1
    "
  ) | tee "$build_log" || {
    _build_capture_diagnostics "$root" "$output_dir" "$build_log"
    return 1
  }
}

# Run package build mode (makepkg).
# Args: $1 = root path, $2 = output directory, $3 = build log path
_build_overlay_run_makepkg() {
  local root="${1:?}"
  local output_dir="${2:?}"
  local build_log="${3:?}"

  log "  Building package with makepkg"
  (
    cd "$root/tmp/build" || exit 1
    chroot "$root" /bin/bash -c '
      cd /tmp/build
      # Run makepkg as nobody (use runuser to avoid account-expiry checks)
      # -s is omitted because dependencies are pre-installed
      runuser -u nobody -- makepkg --noconfirm --noprogressbar 2>&1
    '
  ) | tee "$build_log" || {
    _build_capture_diagnostics "$root" "$output_dir" "$build_log"
    return 1
  }

  # Move any .pkg.tar.* from build dir to output_dir
  find "$root/tmp/build" -maxdepth 1 -name '*.pkg.tar.*' -type f -exec cp {} "$output_dir/" \; 2>/dev/null || true
}

# Capture build diagnostics on failure to a persistent location.
# Args: $1 = root path, $2 = output directory, $3 = build log path
_build_capture_diagnostics() {
  local root="${1:?}"
  local output_dir="${2:?}"
  local build_log="${3:?}"
  local persist_dir="/home/.steamos-nvidia/build-logs"
  mkdir -p "$persist_dir"
  local timestamp
  timestamp="$(date +%Y%m%d-%H%M%S)"

  # Find and copy any meson logs from the build tree
  local meson_log
  meson_log="$(find "$root/tmp/build" -name 'meson-log.txt' -type f 2>/dev/null | head -1)"
  if [[ -n "$meson_log" ]]; then
    cp "$meson_log" "$persist_dir/meson-log-${timestamp}.txt" 2>/dev/null || true
    log "  Meson log preserved: $persist_dir/meson-log-${timestamp}.txt"
  fi

  # Copy the build log itself
  cp "$build_log" "$persist_dir/build-${timestamp}.log" 2>/dev/null || true
  log "  Build log preserved: $persist_dir/build-${timestamp}.log"

  warn "Build failed — see log: $build_log"
}
