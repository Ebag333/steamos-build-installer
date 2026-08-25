#!/bin/bash
#
# steamos-nvidia-installer — lib/drivers/aotofu-vaapi.sh
# AoTofu nvidia-vaapi-driver module.
# Builds and installs the AoTofu VA-API driver for NVIDIA.
#
# Sourced by the build backend and repatch — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/drivers/aotofu-vaapi.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Source common driver utilities if not already loaded
if [[ ! -v _BUILD_MODULES ]]; then
  SCRIPT_DIR_DRV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR_DRV/common.sh"
fi

# ---------------------------------------------------------------------------
# Driver Configuration
# ---------------------------------------------------------------------------

AOTOFU_DRIVER_NAME="aotofu-vaapi"
AOTOFU_DRIVER_DESC="AoTofu nvidia-vaapi-driver for VA-API support"

# Repository settings
AOTOFU_REPO_URL="${AOTOFU_REPO_URL:-https://github.com/AoTofu/nvidia-vaapi-driver.git}"
AOTOFU_REF="${AOTOFU_REF:-main}"

# Runtime dependencies — must remain in the finished image.
AOTOFU_RUNTIME_DEPS=(
  gst-plugins-bad-libs
  libglvnd
)

# Build-only dependencies — needed to compile, not to load the driver.
AOTOFU_BUILD_ONLY_DEPS=(
  git
  base-devel
  meson
  ninja
  pkgconf
  ffnvcodec-headers
  libva
  libdrm
)

# Combined list for backward compatibility.
AOTOFU_BUILD_DEPS=("${AOTOFU_RUNTIME_DEPS[@]}" "${AOTOFU_BUILD_ONLY_DEPS[@]}")

# pkg-config dependencies to verify
AOTOFU_PC_DEPS=(
  egl
  ffnvcodec
  libdrm
  libva
  gstreamer-codecparsers-1.0
)

# State directory for tracking builds
AOTOFU_STATE_DIR="/usr/lib/steamos-nvidia/aotofu-vaapi"

# Source bundle directory (inside state dir) for self-heal
AOTOFU_BUNDLE_DIR="$AOTOFU_STATE_DIR/source"

# Register this driver
register_build "$AOTOFU_DRIVER_NAME" "$AOTOFU_DRIVER_DESC"

# ---------------------------------------------------------------------------
# State Management
# ---------------------------------------------------------------------------

# Get the stamp file path.
# Args: $1 = root path (optional, defaults to /)
_get_aotofu_stamp_file() {
  local root="${1:-/}"
  echo "$root$AOTOFU_STATE_DIR/build.stamp"
}

# Read a value from the stamp file.
# Args: $1 = key, $2 = root path (optional, defaults to /)
_aotofu_stamp_value() {
  local key="$1"
  local root="${2:-/}"
  local stamp_file
  stamp_file="$(_get_aotofu_stamp_file "$root")"
  [[ -f "$stamp_file" ]] || return 0
  sed -n "s/^${key}=//p" "$stamp_file" | tail -n1
}

# Write the stamp file with current build info.
# Args: $1 = commit, $2 = fingerprint, $3 = installed SHA, $4 = root path (optional, defaults to /)
_write_aotofu_stamp() {
  local commit="$1"
  local fingerprint="$2"
  local installed_sha="$3"
  local root="${4:-/}"
  local stamp_file
  stamp_file="$(_get_aotofu_stamp_file "$root")"

  mkdir -p "$(dirname "$stamp_file")"
  cat >"$stamp_file" <<STAMP
driver=$AOTOFU_DRIVER_NAME
repo=$AOTOFU_REPO_URL
ref=$AOTOFU_REF
commit=$commit
fingerprint=$fingerprint
installed_sha=$installed_sha
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STAMP
}

# Get package version via pkg-config from the target root.
# Args: $1 = package name, $2 = root path (optional, defaults to /)
_pkg_version() {
  local pc="$1"
  local root="${2:-/}"
  if [[ "$root" == "/" ]]; then
    pkg-config --modversion "$pc" 2>/dev/null || printf 'missing'
  else
    chroot "$root" pkg-config --modversion "$pc" 2>/dev/null || printf 'missing'
  fi
}

# Compute fingerprint for source + environment.
# Args: $1 = source directory, $2 = commit, $3 = root path (optional, defaults to /)
# Output: SHA256 hash
_compute_aotofu_fingerprint() {
  local src_dir="$1"
  local commit="$2"
  local root="${3:-/}"

  # Hash key package versions from target
  local pkg_hash=""
  local pc
  for pc in "${AOTOFU_PC_DEPS[@]}"; do
    pkg_hash+="$(_pkg_version "$pc" "$root")"
  done

  # Hash installed packages from target
  local installed_hash=""
  if [[ "$root" == "/" ]]; then
    installed_hash="$(pacman -Q 2>/dev/null \
      | grep -E '^(libva|libdrm|libglvnd|ffnvcodec-headers|gst-plugins-bad-libs|nvidia|nvidia-open-dkms|nvidia-utils) ' \
      | sort | sha256sum | awk '{print $1}')"
  else
    installed_hash="$(chroot "$root" pacman -Q 2>/dev/null \
      | grep -E '^(libva|libdrm|libglvnd|ffnvcodec-headers|gst-plugins-bad-libs|nvidia|nvidia-open-dkms|nvidia-utils) ' \
      | sort | sha256sum | awk '{print $1}')"
  fi

  # Combine and hash
  printf '%s%s%s%s%s' "$AOTOFU_REPO_URL" "$commit" "$pkg_hash" "$installed_hash" "$AOTOFU_REF" \
    | sha256sum | awk '{print $1}'
}

# Check if rebuild is needed.
# Args: $1 = commit, $2 = installed driver path (optional), $3 = root path (optional, defaults to /)
# Returns 0 if rebuild needed, 1 if current
_aotofu_needs_rebuild() {
  local commit="$1"
  local installed_path="${2:-}"
  local root="${3:-/}"

  local fingerprint
  fingerprint="$(_compute_aotofu_fingerprint "" "$commit" "$root")"

  local old_fingerprint
  old_fingerprint="$(_aotofu_stamp_value fingerprint "$root")"

  local old_installed_sha
  old_installed_sha="$(_aotofu_stamp_value installed_sha "$root")"

  # Check fingerprint
  if [[ "$old_fingerprint" == "$fingerprint" ]]; then
    # Fingerprint matches — check installed driver
    if [[ -n "$installed_path" && -f "$installed_path" ]]; then
      local current_sha
      current_sha="$(sha256sum "$installed_path" | awk '{print $1}')"
      if [[ "$current_sha" == "$old_installed_sha" ]]; then
        return 1 # Current, no rebuild needed
      fi
      # SHA mismatch → rebuild
    elif [[ -n "$installed_path" ]]; then
      # Path provided but file missing → rebuild
      :
    else
      # No path provided, fingerprint matches → current
      return 1
    fi
  fi

  return 0 # Rebuild needed
}

# ---------------------------------------------------------------------------
# Dependency Management
# ---------------------------------------------------------------------------

# Map pkg-config names to the pacman packages that provide them.
# Used to force-reinstall when --needed skips packages whose .pc files are missing.
_aotofu_pc_to_pkg() {
  case "$1" in
    egl) echo libglvnd ;;
    ffnvcodec) echo ffnvcodec-headers ;;
    libdrm) echo libdrm ;;
    libva) echo libva ;;
    gstreamer-codecparsers-1.0) echo gst-plugins-bad-libs ;;
    *) echo "" ;;
  esac
}

# Quote package targets for safe shell expansion inside in_chroot.
_aotofu_quote_targets() {
  local item
  for item in "$@"; do
    printf '%q ' "$item"
  done
}

# Create a pacman config that includes Arch repos as fallback for build tools.
# This allows installing meson, ninja, cmake, etc. from Arch when Valve repos
# don't have them, while keeping libraries (libdrm, libva) in Valve's universe.
# Args: $1 = root path (optional, defaults to MERGED)
# Sets: AOTOFU_PACCONF with the path to the combined config
_setup_aotofu_pacman_conf() {
  local root="${1:-${MERGED:-/}}"
  local conf_path="/tmp/pacman-aotofu.conf"

  # Start with the base PACCONF (Valve repos)
  if [[ -f "${PACCONF:-}" ]]; then
    cp "$PACCONF" "$conf_path"
  else
    # Fallback: create minimal config
    {
      printf '[options]\n'
      printf 'SigLevel = Never\n'
      printf 'Architecture = auto\n'
    } >"$conf_path"
  fi

  # Append Arch repos for build tools
  cat >>"$conf_path" <<'EOF'

[core]
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch

[extra]
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch

[multilib]
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
EOF

  AOTOFU_PACCONF="$conf_path"
  log "  AoTofu pacman config: $conf_path (Valve + Arch repos)"
}

# Install all build dependencies (runtime + build-only).
# Thin wrapper for backward compatibility — prefer the split helpers.
# Args: $1 = root path (optional, defaults to MERGED)
_install_aotofu_deps() {
  local root="${1:-${MERGED:-/}}"
  _install_aotofu_runtime_deps "$root" && _install_aotofu_build_deps "$root"
}

# Validate all build dependencies before invoking Meson.
# Single pass — commands then pkg-config, with version output.
# Args: $1 = root path (optional, defaults to /)
# Returns 0 if all met, 1 if any missing
_aotofu_preflight_check() {
  local root="${1:-${MERGED:-/}}"
  local ok=1

  log "  Preflight: checking commands"
  for cmd in cc meson ninja pkg-config git; do
    if [[ "$root" == "/" ]]; then
      if command -v "$cmd" >/dev/null 2>&1; then
        log "    ✓ $cmd"
      else
        warn "    ✗ $cmd: MISSING"
        ok=0
      fi
    else
      if chroot "$root" /bin/sh -c 'command -v "$1" >/dev/null 2>&1' sh "$cmd"; then
        log "    ✓ $cmd"
      else
        warn "    ✗ $cmd: MISSING"
        ok=0
      fi
    fi
  done

  log "  Preflight: checking pkg-config dependencies"
  for pc in "${AOTOFU_PC_DEPS[@]}"; do
    local ver=""
    if [[ "$root" == "/" ]]; then
      ver="$(pkg-config --modversion "$pc" 2>/dev/null || true)"
    else
      ver="$(chroot "$root" pkg-config --modversion "$pc" 2>/dev/null || true)"
    fi
    if [[ -n "$ver" ]]; then
      log "    ✓ $pc: $ver"
    else
      warn "    ✗ $pc: pkg-config module missing"
      # Identify provider package
      local pkg
      pkg="$(_aotofu_pc_to_pkg "$pc")"
      if [[ -n "$pkg" ]]; then
        warn "      provider: $pkg"
        # Show installed version
        local installed_ver=""
        if [[ "$root" == "/" ]]; then
          installed_ver="$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}')"
        else
          installed_ver="$(chroot "$root" pacman -Q "$pkg" 2>/dev/null | awk '{print $2}')"
        fi
        if [[ -n "$installed_ver" ]]; then
          warn "      installed version: $installed_ver"
        else
          warn "      installed: NO"
        fi
      fi

      # pkg-config environment
      warn "      pkg-config: $(command -v pkg-config 2>/dev/null || echo 'not found')"
      warn "      PKG_CONFIG_PATH: ${PKG_CONFIG_PATH:-<unset>}"
      warn "      PKG_CONFIG_LIBDIR: ${PKG_CONFIG_LIBDIR:-<unset>}"
      local pc_path=""
      if [[ "$root" == "/" ]]; then
        pc_path="$(pkg-config --variable=pc_path pkg-config 2>/dev/null || true)"
      else
        pc_path="$(chroot "$root" pkg-config --variable=pc_path pkg-config 2>/dev/null || true)"
      fi
      warn "      pkg-config pc_path: ${pc_path:-<unknown>}"

      # Filesystem checks
      local pc_file_host="/usr/lib/pkgconfig/${pc}.pc"
      local pc_file_share="/usr/share/pkgconfig/${pc}.pc"
      if [[ "$root" == "/" ]]; then
        if [[ -e "$pc_file_host" ]]; then
          warn "      $pc_file_host: EXISTS ($(stat -c '%s bytes' "$pc_file_host" 2>/dev/null || true))"
        else
          warn "      $pc_file_host: MISSING"
        fi
        if [[ -e "$pc_file_share" ]]; then
          warn "      $pc_file_share: EXISTS"
        else
          warn "      $pc_file_share: MISSING"
        fi
      else
        local target_host="$root$pc_file_host"
        local target_share="$root$pc_file_share"
        if [[ -e "$target_host" ]]; then
          warn "      $pc_file_host (in chroot): EXISTS ($(stat -c '%s bytes' "$target_host" 2>/dev/null || true))"
        else
          warn "      $pc_file_host (in chroot): MISSING"
        fi
        if [[ -e "$target_share" ]]; then
          warn "      $pc_file_share (in chroot): EXISTS"
        else
          warn "      $pc_file_share (in chroot): MISSING"
        fi
      fi

      # pacman package verification
      if [[ -n "$pkg" ]]; then
        if [[ "$root" == "/" ]]; then
          local qkk
          qkk="$(pacman -Qkk "$pkg" 2>&1 | grep -E 'missing|warning' | head -5)"
          if [[ -n "$qkk" ]]; then
            warn "      pacman -Qkk $pkg:"
            while IFS= read -r line; do
              warn "        $line"
            done <<<"$qkk"
          fi
        else
          local qkk
          qkk="$(chroot "$root" pacman -Qkk "$pkg" 2>&1 | grep -E 'missing|warning' | head -5)"
          if [[ -n "$qkk" ]]; then
            warn "      pacman -Qkk $pkg (in chroot):"
            while IFS= read -r line; do
              warn "        $line"
            done <<<"$qkk"
          fi
        fi
      fi

      # Try REINSTALL (without --needed) to restore missing files
      if [[ -n "$pkg" && -n "$installed_ver" ]]; then
        log "      Reinstalling $pkg (without --needed) to restore missing files..."
        if [[ "$root" == "/" ]]; then
          pacman -S --noconfirm "$pkg" 2>&1 | tail -3 || true
        else
          chroot "$root" pacman --config "$PACCONF" -S --noconfirm "$pkg" 2>&1 | tail -3 || true
        fi
        # Re-check after reinstall
        if [[ "$root" == "/" ]]; then
          ver="$(pkg-config --modversion "$pc" 2>/dev/null || true)"
        else
          ver="$(chroot "$root" pkg-config --modversion "$pc" 2>/dev/null || true)"
        fi
        if [[ -n "$ver" ]]; then
          log "    ✓ $pc: $ver (after reinstall)"
          continue
        fi
        # Post-reinstall filesystem check
        if [[ "$root" == "/" ]]; then
          if [[ -e "$pc_file_host" ]]; then
            warn "      post-reinstall $pc_file_host: EXISTS"
          else
            warn "      post-reinstall $pc_file_host: STILL MISSING"
          fi
        else
          if [[ -e "$target_host" ]]; then
            warn "      post-reinstall $pc_file_host (in chroot): EXISTS"
          else
            warn "      post-reinstall $pc_file_host (in chroot): STILL MISSING"
          fi
        fi
      fi

      ok=0
    fi
  done

  return $((1 - ok))
}

# ---------------------------------------------------------------------------
# Three-Phase Package Snapshot
# ---------------------------------------------------------------------------
# Captures BASE → RUNTIME → BUILD package states so that transitive
# build-only dependencies (e.g. python-tqdm) are excluded from the payload
# without relying on an ever-growing BUILD_ONLY_RE regex.

# Snapshot installed package names (for delta computation).
# Uses pacman -Qq (names only) so version upgrades aren't misclassified as new packages.
# Args: $1 = root path, $2 = output file
_aotofu_snapshot_packages() {
  local root="${1:?}"
  local output="${2:?}"
  if [[ "$root" == "/" ]]; then
    pacman -Qq | LC_ALL=C sort >"$output"
  else
    chroot "$root" pacman -Qq | LC_ALL=C sort >"$output"
  fi
}

# Install only runtime deps (version-matched gst-plugins-bad-libs + libglvnd).
# Args: $1 = root path
_install_aotofu_runtime_deps() {
  local root="${1:-${MERGED:-/}}"

  local image_gst_version=""
  if [[ "$root" == "/" ]]; then
    image_gst_version="$(pacman -Q gstreamer 2>/dev/null | awk '{print $2}')"
  else
    image_gst_version="$(chroot "$root" pacman -Q gstreamer 2>/dev/null | awk '{print $2}')"
  fi

  if [[ -z "$image_gst_version" ]]; then
    warn "Unable to determine target GStreamer version"
    return 1
  fi

  # Install non-versioned runtime deps first (libglvnd, egl-wayland etc.)
  # Use AOTOFU_PACCONF which includes Arch repos for packages Valve doesn't ship
  local other_runtime=("${AOTOFU_RUNTIME_DEPS[@]:1}")
  if ((${#other_runtime[@]})); then
    local quoted_other
    quoted_other="$(_aotofu_quote_targets "${other_runtime[@]}")"
    log "  Installing runtime dependencies"
    # Refresh database to ensure packages are found
    if [[ "$root" == "/" ]]; then
      pacman --config "${AOTOFU_PACCONF:-$PACCONF}" -Sy 2>/dev/null || true
      if ! pacman --config "${AOTOFU_PACCONF:-$PACCONF}" -S --noconfirm --needed ${quoted_other}; then
        warn "Failed to install runtime dependencies: ${other_runtime[*]}"
        return 1
      fi
    else
      chroot "$root" pacman --config "${AOTOFU_PACCONF:-$PACCONF}" -Sy 2>/dev/null || true
      if ! chroot "$root" pacman --config "${AOTOFU_PACCONF:-$PACCONF}" -S $PACOPTS ${quoted_other}; then
        warn "Failed to install runtime dependencies: ${other_runtime[*]}"
        return 1
      fi
    fi
  fi

  # Install version-pinned gst-plugins-bad-libs
  local gst_target="gst-plugins-bad-libs=${image_gst_version}"
  log "  Installing $gst_target"

  # Try configured repos first
  local installed=0
  if [[ "$root" == "/" ]]; then
    pacman -S --noconfirm --needed "$gst_target" && installed=1
  else
    chroot "$root" pacman --config "$PACCONF" -S $PACOPTS "$gst_target" && installed=1
  fi

  # Fallback: retrieve from Arch archive
  if ((!installed)); then
    log "  Configured repos do not have $gst_target — attempting archived package"
    local first_letter="${gst_target:0:1}"
    local archive_url="https://archive.archlinux.org/packages/${first_letter}/gst-plugins-bad-libs/gst-plugins-bad-libs-${image_gst_version}-x86_64.pkg.tar.zst"
    local cached_pkg="/tmp/gst-plugins-bad-libs-${image_gst_version}.pkg.tar.zst"

    if curl -sfL "$archive_url" -o "$cached_pkg"; then
      log "  Retrieved from archive — installing with pacman -U"
      if [[ "$root" == "/" ]]; then
        pacman -U --noconfirm "$cached_pkg" && installed=1
      else
        cp "$cached_pkg" "$root/tmp/"
        chroot "$root" pacman --config "$PACCONF" -U --noconfirm "/tmp/$(basename "$cached_pkg")" && installed=1
        rm -f "$root/tmp/$(basename "$cached_pkg")"
      fi
      rm -f "$cached_pkg"
    fi
  fi

  if ((!installed)); then
    log "  Exact version gst-plugins-bad-libs=${image_gst_version} unavailable — trying unpinned"
    # No cross-distro guard here — we're installing from Valve's repos,
    # not Arch. Accept whatever version Valve currently ships.
    if [[ "$root" == "/" ]]; then
      pacman -S --noconfirm --needed "gst-plugins-bad-libs" && installed=1
    else
      chroot "$root" pacman --config "$PACCONF" -S $PACOPTS "gst-plugins-bad-libs" && installed=1
    fi
  fi

  if ((!installed)); then
    warn "AoTofu requires gst-plugins-bad-libs matching GStreamer ${image_gst_version}."
    warn "Configured repositories do not contain that version."
    warn "Archived package retrieval also failed."
    return 1
  fi
}

# Install only build-only deps.
# libdrm and libva are version-pinned to the image's installed versions to
# avoid pulling newer Arch versions that would cause build/runtime mismatch.
# Args: $1 = root path
_install_aotofu_build_deps() {
  local root="${1:-${MERGED:-/}}"

  # Read the image's installed versions of libdrm and libva so we can pin
  # the build deps to match.  This prevents Arch's latest from upgrading
  # libraries that SteamOS ships at older versions.
  local image_libdrm="" image_libva=""
  if [[ "$root" == "/" ]]; then
    image_libdrm="$(pacman -Q libdrm 2>/dev/null | awk '{print $2}')"
    image_libva="$(pacman -Q libva 2>/dev/null | awk '{print $2}')"
  else
    image_libdrm="$(chroot "$root" pacman -Q libdrm 2>/dev/null | awk '{print $2}')"
    image_libva="$(chroot "$root" pacman -Q libva 2>/dev/null | awk '{print $2}')"
  fi

  # Separate pinned deps from the rest
  local unpinned=()
  local pinned=()
  local item
  for item in "${AOTOFU_BUILD_ONLY_DEPS[@]}"; do
    case "$item" in
      libdrm)
        if [[ -n "$image_libdrm" ]]; then
          pinned+=("libdrm=${image_libdrm}")
        else
          warn "  libdrm not installed in image — installing latest"
          unpinned+=("libdrm")
        fi
        ;;
      libva)
        if [[ -n "$image_libva" ]]; then
          pinned+=("libva=${image_libva}")
        else
          warn "  libva not installed in image — installing latest"
          unpinned+=("libva")
        fi
        ;;
      *)
        unpinned+=("$item")
        ;;
    esac
  done

  # Install unpinned deps (toolchain, headers)
  # Use AOTOFU_PACCONF which includes Arch repos for build tools
  if ((${#unpinned[@]})); then
    local quoted
    quoted="$(_aotofu_quote_targets "${unpinned[@]}")"
    log "  Installing unpinned build dependencies"
    # Refresh database to ensure packages are found
    if [[ "$root" == "/" ]]; then
      pacman --config "${AOTOFU_PACCONF:-$PACCONF}" -Sy 2>/dev/null || true
      if ! pacman --config "${AOTOFU_PACCONF:-$PACCONF}" -S --noconfirm --needed \
        --overwrite 'usr/lib/libgcc_s.so.1' \
        --overwrite 'usr/lib/libstdc++.so*' \
        --overwrite 'usr/share/locale/*/LC_MESSAGES/libstdc++.mo' \
        ${quoted}; then
        warn "Failed to install unpinned build dependencies: ${unpinned[*]}"
        return 1
      fi
    else
      chroot "$root" pacman --config "${AOTOFU_PACCONF:-$PACCONF}" -Sy 2>/dev/null || true
      if ! chroot "$root" pacman --config "${AOTOFU_PACCONF:-$PACCONF}" -S $PACOPTS \
        --overwrite 'usr/lib/libgcc_s.so.1' \
        --overwrite 'usr/lib/libstdc++.so*' \
        --overwrite 'usr/share/locale/*/LC_MESSAGES/libstdc++.mo' \
        ${quoted}; then
        warn "Failed to install unpinned build dependencies: ${unpinned[*]}"
        return 1
      fi
    fi
  fi

  # Install version-pinned deps with archive fallback
  local target
  for target in "${pinned[@]}"; do
    local pkg_name="${target%%=*}"
    local pkg_ver="${target#*=}"
    log "  Installing $target"

    local installed=0
    if [[ "$root" == "/" ]]; then
      pacman -S --noconfirm --needed "$target" && installed=1
    else
      chroot "$root" pacman --config "$PACCONF" -S $PACOPTS "$target" && installed=1
    fi

    if ((!installed)); then
      log "  Configured repos do not have $target — attempting archived package"
      local first_letter="${pkg_name:0:1}"
      local archive_url="https://archive.archlinux.org/packages/${first_letter}/${pkg_name}/${pkg_name}-${pkg_ver}-x86_64.pkg.tar.zst"
      local cached_pkg="/tmp/${pkg_name}-${pkg_ver}.pkg.tar.zst"

      if curl -sfL "$archive_url" -o "$cached_pkg"; then
        log "  Retrieved from archive — installing with pacman -U"
        if [[ "$root" == "/" ]]; then
          pacman -U --noconfirm "$cached_pkg" && installed=1
        else
          cp "$cached_pkg" "$root/tmp/"
          chroot "$root" pacman --config "$PACCONF" -U --noconfirm "/tmp/$(basename "$cached_pkg")" && installed=1
          rm -f "$root/tmp/$(basename "$cached_pkg")"
        fi
        rm -f "$cached_pkg"
      fi
    fi

    if ((!installed)); then
      log "  Exact version ${target} unavailable — trying unpinned ${pkg_name}"
      # No cross-distro guard here — we're installing from Valve's repos,
      # not Arch. Accept whatever version Valve currently ships.
      if [[ "$root" == "/" ]]; then
        pacman -S --noconfirm --needed "$pkg_name" && installed=1
      else
        chroot "$root" pacman --config "$PACCONF" -S $PACOPTS "$pkg_name" && installed=1
      fi
    fi

    if ((!installed)); then
      warn "AoTofu build requires ${pkg_name}=${pkg_ver} (matching image)."
      warn "Configured repositories do not contain that version."
      warn "Archived package retrieval also failed."
      return 1
    fi
  done
}

# Compute RUNTIME→BUILD delta and append to global exclusions file.
# Args: $1 = work directory (AoTofu-local, for snapshots), $2 = root path
_aotofu_record_build_only_delta() {
  local workdir="${1:?}"
  local root="${2:-${MERGED:-/}}"

  local runtime="$workdir/aotofu-runtime.txt"
  local build="$workdir/aotofu-build.txt"
  local exclusions="${WORKDIR:?}/build-only-exclusions.txt"

  _aotofu_snapshot_packages "$root" "$build"

  if [[ -f "$runtime" && -f "$build" ]]; then
    local count
    count="$(LC_ALL=C comm -13 "$runtime" "$build" | wc -l)"
    if ((count > 0)); then
      LC_ALL=C comm -13 "$runtime" "$build" >>"$exclusions"
      LC_ALL=C sort -u -o "$exclusions" "$exclusions"
      log "  Build-only delta: $count packages recorded for exclusion"
    else
      log "  Build-only delta: 0 packages"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Source Management
# ---------------------------------------------------------------------------

# Prepare the build environment: install dependencies and capture package
# snapshots for build-only delta tracking.
# Args: $1 = work directory, $2 = root path
# Returns 0 on success, 1 on failure
_aotofu_prepare_build_environment() {
  local workdir="${1:?}"
  local root="${2:?}"

  # Clear stale snapshots from any prior attempt
  mkdir -p "$workdir"
  rm -f \
    "$workdir/aotofu-base.txt" \
    "$workdir/aotofu-runtime.txt" \
    "$workdir/aotofu-build.txt"

  # ── Phase 1: BASE snapshot ──
  _aotofu_snapshot_packages "$root" "$workdir/aotofu-base.txt"

  # ── Phase 2: Setup pacman config with Arch repos for build tools ──
  _setup_aotofu_pacman_conf "$root"

  # ── Phase 3: Install runtime dependencies ──
  _install_aotofu_runtime_deps "$root" || return 1

  # ── Phase 4: RUNTIME snapshot ──
  _aotofu_snapshot_packages "$root" "$workdir/aotofu-runtime.txt"

  # ── Phase 5: Install build-only dependencies ──
  _install_aotofu_build_deps "$root" || return 1

  # ── Preflight validation (single pass, no retries) ──
  if ! _aotofu_preflight_check "$root"; then
    local -a missing=()
    for pc in "${AOTOFU_PC_DEPS[@]}"; do
      local ver=""
      if [[ "$root" == "/" ]]; then
        ver="$(pkg-config --modversion "$pc" 2>/dev/null || true)"
      else
        ver="$(chroot "$root" pkg-config --modversion "$pc" 2>/dev/null || true)"
      fi
      [[ -z "$ver" ]] && missing+=("$pc")
    done
    for cmd in cc meson ninja pkg-config git; do
      if [[ "$root" == "/" ]]; then
        command -v "$cmd" >/dev/null 2>&1 || missing+=("cmd:$cmd")
      else
        chroot "$root" /bin/sh -c 'command -v "$1" >/dev/null 2>&1' sh "$cmd" || missing+=("cmd:$cmd")
      fi
    done
    warn "Dependencies still missing after installation: ${missing[*]}"
    return 1
  fi
}

# Fetch/update AoTofu source.
# Args: $1 = source directory
# Sets: AOTOFU_FETCHED_COMMIT on success
_fetch_aotofu_source() {
  local src_dir="${1:?_fetch_aotofu_source: missing source dir}"

  if [[ ! -d "$src_dir/.git" ]]; then
    rm -rf "$src_dir"
    log "  Cloning $AOTOFU_REPO_URL"
    git clone --no-tags --filter=blob:none "$AOTOFU_REPO_URL" "$src_dir" >&2
  fi

  git -C "$src_dir" remote set-url origin "$AOTOFU_REPO_URL"

  log "  Fetching source"
  git -C "$src_dir" fetch --prune --tags origin >&2

  local commit=""
  if git -C "$src_dir" rev-parse --verify --quiet "refs/remotes/origin/$AOTOFU_REF^{commit}" >/dev/null; then
    commit="$(git -C "$src_dir" rev-parse "refs/remotes/origin/$AOTOFU_REF^{commit}")"
  elif git -C "$src_dir" rev-parse --verify --quiet "$AOTOFU_REF^{commit}" >/dev/null; then
    commit="$(git -C "$src_dir" rev-parse "$AOTOFU_REF^{commit}")"
  else
    git -C "$src_dir" fetch origin "$AOTOFU_REF" || {
      warn "Unable to fetch ref: $AOTOFU_REF"
      return 1
    }
    commit="$(git -C "$src_dir" rev-parse 'FETCH_HEAD^{commit}')"
  fi

  git -C "$src_dir" checkout --detach -f "$commit"
  git -C "$src_dir" reset --hard "$commit" >/dev/null
  git -C "$src_dir" clean -fdx >/dev/null

  AOTOFU_FETCHED_COMMIT="$commit"
}

# ---------------------------------------------------------------------------
# Build Logic
# ---------------------------------------------------------------------------

# Build AoTofu VA-API driver.
# Runs meson inside the target root (chroot for build/repatch, direct for live).
# Args: $1 = root path, $2 = source directory (host path), $3 = work directory (host path)
# Sets: AOTOFU_BUILT_DRIVER on success
_build_aotofu_driver() {
  local root="${1:?_build_aotofu_driver: missing root}"
  local src_dir="${2:?_build_aotofu_driver: missing source dir}"
  local workdir="${3:?_build_aotofu_driver: missing work dir}"

  # For chroot builds: copy source into chroot, use chroot-relative paths
  # For live builds: use paths directly
  local src_in_root build_in_root search_dir
  if [[ "$root" == "/" ]]; then
    src_in_root="$src_dir"
    build_in_root="$workdir/aotofu-build"
    search_dir="$build_in_root"
  else
    src_in_root="/tmp/aotofu-src"
    build_in_root="/tmp/aotofu-build"
    search_dir="$root$build_in_root"
    # Copy source into chroot
    rm -rf "$root$src_in_root"
    mkdir -p "$root$src_in_root"
    cp -a "$src_dir/." "$root$src_in_root/"
  fi

  log "  Configuring release build"
  rm -rf "$search_dir"
  if [[ "$root" == "/" ]]; then
    meson setup "$build_in_root" "$src_in_root" \
      --buildtype=release --prefix=/usr >&2 \
      || {
        warn "meson setup failed"
        return 1
      }
  else
    chroot "$root" meson setup "$build_in_root" "$src_in_root" \
      --buildtype=release --prefix=/usr >&2 \
      || {
        warn "meson setup failed"
        return 1
      }
  fi

  log "  Building"
  if [[ "$root" == "/" ]]; then
    meson compile -C "$build_in_root" >&2 || {
      warn "Build failed"
      return 1
    }
  else
    chroot "$root" meson compile -C "$build_in_root" >&2 || {
      warn "Build failed"
      return 1
    }
  fi

  log "  Running unit tests"
  if [[ "$root" == "/" ]]; then
    meson test -C "$build_in_root" --print-errorlogs >&2 || {
      warn "Tests failed"
      return 1
    }
  else
    chroot "$root" meson test -C "$build_in_root" --print-errorlogs >&2 || {
      warn "Tests failed"
      return 1
    }
  fi

  # Find built driver (host path for file operations)
  local built_driver
  built_driver="$(find "$search_dir" -maxdepth 2 -type f -name 'nvidia_drv_video.so' -print -quit)"
  [[ -n "$built_driver" && -f "$built_driver" ]] || {
    warn "nvidia_drv_video.so not found after build"
    return 1
  }

  AOTOFU_BUILT_DRIVER="$built_driver"
}

# Install AoTofu driver.
# Args: $1 = built driver path, $2 = target path
# Returns 0 on success, 1 on failure
_install_aotofu_driver() {
  local built_driver="${1:?_install_aotofu_driver: missing built driver}"
  local target_driver="${2:?_install_aotofu_driver: missing target path}"

  mkdir -p "$(dirname "$target_driver")"
  install -m0755 "$built_driver" "$target_driver" || {
    warn "Failed to install driver"
    return 1
  }

  # Verify installation
  local built_sha installed_sha
  built_sha="$(sha256sum "$built_driver" | awk '{print $1}')"
  installed_sha="$(sha256sum "$target_driver" | awk '{print $1}')"
  [[ "$built_sha" == "$installed_sha" ]] || {
    warn "Installed driver checksum mismatch"
    return 1
  }

  printf '%s' "$installed_sha"
}

# Find NVIDIA render node for testing.
_find_nvidia_render_node() {
  local sys vendor node
  for sys in /sys/class/drm/renderD*/device; do
    [[ -r "$sys/vendor" ]] || continue
    vendor="$(cat "$sys/vendor" 2>/dev/null || true)"
    [[ "$vendor" == "0x10de" ]] || continue
    node="/dev/dri/$(basename "$(dirname "$sys")")"
    [[ -e "$node" ]] && {
      printf '%s\n' "$node"
      return 0
    }
  done
  return 1
}

# Run hardware smoke test.
_run_aotofu_hw_test() {
  local driver_dir="$1"

  command -v vainfo >/dev/null 2>&1 || {
    warn "vainfo not available; skipping test"
    return 0
  }

  local node
  node="$(_find_nvidia_render_node || true)"
  [[ -n "$node" ]] || {
    warn "No NVIDIA render node found; skipping test"
    return 0
  }

  if [[ -r /sys/module/nvidia_drm/parameters/modeset ]]; then
    case "$(cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null || true)" in
      Y | 1) ;;
      *) warn "nvidia_drm modeset not enabled; AoTofu requires nvidia-drm.modeset=1" ;;
    esac
  fi

  log "  Running vainfo smoke test on $node"
  if LIBVA_DRIVER_NAME=nvidia \
    LIBVA_DRIVERS_PATH="$driver_dir" \
    NVD_BACKEND=direct \
    NVD_EXPORT_LAYOUT=auto \
    vainfo --display drm --device "$node" >/tmp/aotofu-vainfo.log 2>&1; then
    log "  vainfo smoke test passed"
  else
    warn "vainfo smoke test failed; install is retained"
    sed 's/^/[vainfo] /' /tmp/aotofu-vainfo.log >&2 || true
  fi
}

# ---------------------------------------------------------------------------
# High-Level Interface
# ---------------------------------------------------------------------------

# Verify host has git for source fetching.
# Args: none
# Returns 0 if available, 1 if missing
_require_host_git() {
  if ! command -v git >/dev/null 2>&1; then
    warn "git is required on the host for AoTofu source management"
    return 1
  fi
}

# Apply AoTofu driver (build-time).
# Args: $1 = work directory, $2 = root path (optional, defaults to MERGED)
# Returns 0 on success, 1 on failure
apply_aotofu_vaapi_build() {
  local workdir="${1:?apply_aotofu_vaapi_build: missing work directory}"
  local root="${2:-${MERGED:-/}}"

  log "Building AoTofu VA-API driver"

  _require_host_git || return 1

  local src_dir="$workdir/aotofu-src"

  # Install dependencies with snapshot tracking
  _aotofu_prepare_build_environment "$workdir" "$root" || {
    _aotofu_record_build_only_delta "$workdir" "$root"
    return 1
  }

  # Fetch source
  _fetch_aotofu_source "$src_dir" || {
    _aotofu_record_build_only_delta "$workdir" "$root"
    return 1
  }
  local commit="$AOTOFU_FETCHED_COMMIT"
  log "  Source commit: $commit"

  # Check if rebuild is needed — use chroot's pkg-config for driver path
  local driver_dir
  if [[ "$root" == "/" ]]; then
    driver_dir="$(pkg-config --variable=driverdir libva 2>/dev/null || true)"
  else
    driver_dir="$(chroot "$root" pkg-config --variable=driverdir libva 2>/dev/null || true)"
  fi
  if [[ -z "$driver_dir" || "$driver_dir" != /* ]]; then
    warn "Invalid libva driverdir: '${driver_dir:-<empty>}'"
    _aotofu_record_build_only_delta "$workdir" "$root"
    return 1
  fi
  local target_driver_chroot="$driver_dir/nvidia_drv_video.so"
  local target_driver_host="$root$target_driver_chroot"

  if ! _aotofu_needs_rebuild "$commit" "$target_driver_host" "$root"; then
    log "  AoTofu driver is current — skipping rebuild"
    _aotofu_record_build_only_delta "$workdir" "$root"
    return 0
  fi

  # Build inside the target root
  _build_aotofu_driver "$root" "$src_dir" "$workdir" || {
    _aotofu_record_build_only_delta "$workdir" "$root"
    return 1
  }
  local built_driver="$AOTOFU_BUILT_DRIVER"

  # ── Verify VP9 codecparser support is linked ──
  local needed
  needed="$(readelf -d "$built_driver" 2>/dev/null | grep NEEDED || true)"
  log "  Driver NEEDED: $(echo "$needed" | awk '{print $NF}' | tr '\n' ' ')"

  if ! grep -q 'libgstcodecparsers' <<<"$needed"; then
    warn "AoTofu built without VP9 codecparser support — gst-plugins-bad-libs not linked"
    _aotofu_record_build_only_delta "$workdir" "$root"
    return 1
  fi
  log "  VP9 codec support: enabled"

  # Backup existing driver (host path)
  if [[ -f "$target_driver_host" ]]; then
    local current_sha
    current_sha="$(sha256sum "$target_driver_host" | awk '{print $1}')"
    local backup_dir="$root$AOTOFU_STATE_DIR/backups"
    local backup_path="$backup_dir/nvidia_drv_video.so.$current_sha"
    if [[ ! -e "$backup_path" ]]; then
      mkdir -p "$backup_dir"
      cp -a "$target_driver_host" "$backup_path"
      log "  Backed up existing driver to $backup_path"
    fi
  fi

  # Install (host path for file operations)
  local installed_sha
  installed_sha="$(_install_aotofu_driver "$built_driver" "$target_driver_host")" || {
    _aotofu_record_build_only_delta "$workdir" "$root"
    return 1
  }

  # ── Verify runtime dependencies resolve in target root ──
  if [[ "$root" != "/" ]]; then
    if chroot "$root" ldd "$target_driver_chroot" 2>&1 | grep -q 'not found'; then
      warn "AoTofu driver has unresolved runtime dependencies:"
      chroot "$root" ldd "$target_driver_chroot" 2>&1 | grep 'not found' >&2
      _aotofu_record_build_only_delta "$workdir" "$root"
      return 1
    fi
    log "  Runtime dependency check: all resolved"
  fi

  # Copy to state directory (root-aware)
  mkdir -p "$root$AOTOFU_STATE_DIR/driver"
  install -m0755 "$built_driver" "$root$AOTOFU_STATE_DIR/driver/nvidia_drv_video.so"

  # Write stamp (root-aware)
  local fingerprint
  fingerprint="$(_compute_aotofu_fingerprint "$src_dir" "$commit" "$root")"
  _write_aotofu_stamp "$commit" "$fingerprint" "$installed_sha" "$root"

  # Register custom payload files (not owned by any pacman package)
  register_custom_payload_file "$target_driver_chroot"
  register_custom_payload_file "$AOTOFU_STATE_DIR/build.stamp"
  register_custom_payload_file "$AOTOFU_STATE_DIR/driver/nvidia_drv_video.so"

  # Create bundle for self-heal
  local bundle_dir="$MNT$AOTOFU_BUNDLE_DIR"
  if ! create_driver_bundle "$src_dir" "$bundle_dir"; then
    warn "Failed to create AoTofu source bundle for self-heal"
  fi

  # ── Record build-only delta for compute_payload ──
  _aotofu_record_build_only_delta "$workdir" "$root"

  log "AoTofu VA-API driver built and installed"
  return 0
}

# Apply AoTofu driver (rebuild/self-heal).
# Args: none (uses AOTOFU_BUNDLE_DIR relative to MERGED)
# Returns 0 on success, 1 on failure
apply_aotofu_vaapi_rebuild() {
  local root="${MERGED:-/}"
  local workdir="$MERGED/tmp/aotofu-rebuild"
  local bundle_dir="$root$AOTOFU_BUNDLE_DIR"

  log "Rebuilding AoTofu VA-API driver from bundle"

  _require_host_git || return 1

  # Load sources from bundle
  local src_dir="$workdir/src"
  if ! load_driver_bundle "$bundle_dir" "$src_dir"; then
    return 1
  fi

  # Install dependencies with snapshot tracking
  _aotofu_prepare_build_environment "$workdir" "$root" || {
    _aotofu_record_build_only_delta "$workdir" "$root"
    return 1
  }

  # Get commit from source
  local commit
  commit="$(git -C "$src_dir" rev-parse HEAD 2>/dev/null || true)"
  [[ -n "$commit" ]] || {
    warn "Cannot determine commit from source"
    _aotofu_record_build_only_delta "$workdir" "$root"
    return 1
  }

  # Check if rebuild is needed — use chroot's pkg-config for driver path
  local driver_dir
  driver_dir="$(chroot "$root" pkg-config --variable=driverdir libva 2>/dev/null || true)"
  if [[ -z "$driver_dir" || "$driver_dir" != /* ]]; then
    warn "Invalid libva driverdir: '${driver_dir:-<empty>}'"
    _aotofu_record_build_only_delta "$workdir" "$root"
    return 1
  fi
  local target_driver_chroot="$driver_dir/nvidia_drv_video.so"
  local target_driver_host="$root$target_driver_chroot"

  if ! _aotofu_needs_rebuild "$commit" "$target_driver_host" "$root"; then
    log "  AoTofu driver is current — skipping rebuild"
    _aotofu_record_build_only_delta "$workdir" "$root"
    rm -rf "$src_dir"
    return 0
  fi

  # Build inside the target root
  _build_aotofu_driver "$root" "$src_dir" "$workdir" || {
    _aotofu_record_build_only_delta "$workdir" "$root"
    return 1
  }
  local built_driver="$AOTOFU_BUILT_DRIVER"

  # ── Verify VP9 codecparser support is linked ──
  local needed
  needed="$(readelf -d "$built_driver" 2>/dev/null | grep NEEDED || true)"
  if ! grep -q 'libgstcodecparsers' <<<"$needed"; then
    warn "AoTofu built without VP9 codecparser support — gst-plugins-bad-libs not linked"
    _aotofu_record_build_only_delta "$workdir" "$root"
    return 1
  fi
  log "  VP9 codec support: enabled"

  # Backup existing driver (host path)
  if [[ -f "$target_driver_host" ]]; then
    local current_sha
    current_sha="$(sha256sum "$target_driver_host" | awk '{print $1}')"
    local backup_dir="$root$AOTOFU_STATE_DIR/backups"
    local backup_path="$backup_dir/nvidia_drv_video.so.$current_sha"
    if [[ ! -e "$backup_path" ]]; then
      mkdir -p "$backup_dir"
      cp -a "$target_driver_host" "$backup_path"
    fi
  fi

  # Install (host path for file operations)
  local installed_sha
  installed_sha="$(_install_aotofu_driver "$built_driver" "$target_driver_host")" || {
    _aotofu_record_build_only_delta "$workdir" "$root"
    return 1
  }

  # ── Verify runtime dependencies resolve in target root ──
  if chroot "$root" ldd "$target_driver_chroot" 2>&1 | grep -q 'not found'; then
    warn "AoTofu driver has unresolved runtime dependencies:"
    chroot "$root" ldd "$target_driver_chroot" 2>&1 | grep 'not found' >&2
    _aotofu_record_build_only_delta "$workdir" "$root"
    return 1
  fi
  log "  Runtime dependency check: all resolved"

  # Copy to state directory (root-aware)
  mkdir -p "$root$AOTOFU_STATE_DIR/driver"
  install -m0755 "$built_driver" "$root$AOTOFU_STATE_DIR/driver/nvidia_drv_video.so"

  # Write stamp (root-aware)
  local fingerprint
  fingerprint="$(_compute_aotofu_fingerprint "$src_dir" "$commit" "$root")"
  _write_aotofu_stamp "$commit" "$fingerprint" "$installed_sha" "$root"

  # Register custom payload files (not owned by any pacman package)
  register_custom_payload_file "$target_driver_chroot"
  register_custom_payload_file "$AOTOFU_STATE_DIR/build.stamp"
  register_custom_payload_file "$AOTOFU_STATE_DIR/driver/nvidia_drv_video.so"

  # ── Record build-only delta for compute_payload ──
  _aotofu_record_build_only_delta "$workdir" "$root"

  # Clean up source
  rm -rf "$src_dir"

  log "AoTofu VA-API driver rebuilt and installed"
  return 0
}

# Apply AoTofu driver (live system).
# Args: $1 = work directory (optional, defaults to /tmp)
# Returns 0 on success, 1 on failure
apply_aotofu_vaapi_live() (
  local workdir="${1:-/tmp/aotofu-vaapi-build}"
  local root="/"

  log "Installing AoTofu VA-API driver on live system"

  # Check if running as root
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    warn "Live installation requires root privileges"
    return 1
  fi

  # Prepare work directory for snapshots
  mkdir -p "$workdir"

  # Handle read-only filesystem (SteamOS) BEFORE dependency installation
  local reenable_readonly=0
  if command -v steamos-readonly >/dev/null 2>&1; then
    if ! touch /usr/.write-test 2>/dev/null; then
      log "  /usr is read-only; temporarily disabling SteamOS read-only mode"
      steamos-readonly disable
      reenable_readonly=1
    fi
    rm -f /usr/.write-test 2>/dev/null
  fi

  # Cleanup function — runs on all exit paths (success and failure).
  # Order matters: package removal before readonly restore.
  _cleanup_aotofu_live() {
    # Remove build-only packages actually introduced by this transaction
    if [[ -f "$workdir/live-runtime.txt" && -f "$workdir/live-build.txt" ]]; then
      mapfile -t _added_build_pkgs < <(
        LC_ALL=C comm -13 "$workdir/live-runtime.txt" "$workdir/live-build.txt"
      )
      if ((${#_added_build_pkgs[@]})); then
        log "  Removing build-only dependencies"
        pacman -Rns --noconfirm "${_added_build_pkgs[@]}" 2>/dev/null || true
      fi
    fi
    rm -rf "$workdir"
    if ((reenable_readonly)); then
      log "  Restoring SteamOS read-only mode"
      steamos-readonly enable || warn "failed to re-enable read-only mode"
    fi
  }
  trap _cleanup_aotofu_live EXIT

  # Install dependencies and validate
  _install_aotofu_runtime_deps "/"
  _aotofu_snapshot_packages "/" "$workdir/live-runtime.txt"
  _install_aotofu_build_deps "/"
  _aotofu_snapshot_packages "/" "$workdir/live-build.txt"
  if ! _aotofu_preflight_check "/"; then
    warn "Dependencies still missing after installation"
    return 1
  fi

  # Fetch source
  local src_dir="$workdir/src"
  _fetch_aotofu_source "$src_dir" || return 1
  local commit="$AOTOFU_FETCHED_COMMIT"
  log "  Source commit: $commit"

  # Check if rebuild is needed
  local driver_dir
  driver_dir="$(pkg-config --variable=driverdir libva 2>/dev/null || true)"
  if [[ -z "$driver_dir" || "$driver_dir" != /* ]]; then
    warn "Invalid libva driverdir: '${driver_dir:-<empty>}'"
    return 1
  fi
  local target_driver="$driver_dir/nvidia_drv_video.so"

  if ! _aotofu_needs_rebuild "$commit" "$target_driver" "/"; then
    log "  AoTofu driver is current — skipping rebuild"
    return 0
  fi

  # Build (live: root is /, so build runs directly on host)
  _build_aotofu_driver "/" "$src_dir" "$workdir" || return 1
  local built_driver="$AOTOFU_BUILT_DRIVER"

  # ── Verify VP9 codecparser support is linked ──
  local needed
  needed="$(readelf -d "$built_driver" 2>/dev/null | grep NEEDED || true)"
  if ! grep -q 'libgstcodecparsers' <<<"$needed"; then
    warn "AoTofu built without VP9 codecparser support — gst-plugins-bad-libs not linked"
    return 1
  fi
  log "  VP9 codec support: enabled"

  # Backup existing driver
  if [[ -f "$target_driver" ]]; then
    local current_sha
    current_sha="$(sha256sum "$target_driver" | awk '{print $1}')"
    local backup_dir="$AOTOFU_STATE_DIR/backups"
    local backup_path="$backup_dir/nvidia_drv_video.so.$current_sha"
    if [[ ! -e "$backup_path" ]]; then
      mkdir -p "$backup_dir"
      cp -a "$target_driver" "$backup_path"
    fi
  fi

  # Install
  local installed_sha
  installed_sha="$(_install_aotofu_driver "$built_driver" "$target_driver")" || return 1

  # Verify runtime dependencies resolve
  if ldd "$target_driver" 2>&1 | grep -q 'not found'; then
    warn "AoTofu driver has unresolved runtime dependencies:"
    ldd "$target_driver" 2>&1 | grep 'not found' >&2
    return 1
  fi
  log "  Runtime dependency check: all resolved"

  # Write stamp
  local fingerprint
  fingerprint="$(_compute_aotofu_fingerprint "$src_dir" "$commit" "/")"
  _write_aotofu_stamp "$commit" "$fingerprint" "$installed_sha" "/"

  # Run hardware test
  _run_aotofu_hw_test "$driver_dir"

  log "AoTofu VA-API driver installed on live system"
  return 0
)
