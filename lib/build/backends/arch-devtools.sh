#!/bin/bash
#
# steamos-build-installer — lib/build/backends/arch-devtools.sh
# Build backend using Arch devtools (mkarchroot/makechrootpkg).
#
# Sourced by engine.sh — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/build/backends/arch-devtools.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Guard against double-sourcing
[[ -v _BUILD_DEVTOOLS_LOADED ]] && return 0
_BUILD_DEVTOOLS_LOADED=1

# ---------------------------------------------------------------------------
# Backend interface
# ---------------------------------------------------------------------------

# Create a clean build root using mkarchroot.
# Args: $1 = name, $2 = profile dir
# Prints: path to build root directory
_build_devtools_create_root() {
  local name="${1:?}"
  # shellcheck disable=SC2034 # part of backend interface; profile data accessed via PROFILE_* env vars
  local profile="${2:?}"

  local build_dir="${WORKDIR:-/tmp}/build-roots/$name-$$"
  mkdir -p "$build_dir"

  local pacman_conf="${PROFILE_PACMAN:?profile must set PROFILE_PACMAN}"
  local arch="${PROFILE_ARCH:-x86_64}"

  log "  Creating build root: $build_dir"
  log "    pacman.conf: $pacman_conf"
  log "    arch: $arch"

  # Verify mkarchroot is available
  if ! command -v mkarchroot >/dev/null 2>&1; then
    warn "mkarchroot not found — install arch-install-scripts"
    return 1
  fi

  # Verify pacman.conf exists
  if [[ ! -f "$pacman_conf" ]]; then
    warn "pacman.conf not found: $pacman_conf"
    return 1
  fi

  # Create the root with base packages
  local mkarchroot_output=""
  mkarchroot_output="$(mkarchroot \
    -C "$pacman_conf" \
    ${PROFILE_MAKEPKG:+-M "$PROFILE_MAKEPKG"} \
    "$build_dir/root" \
    base base-devel 2>&1)" || {
    warn "mkarchroot failed:"
    echo "$mkarchroot_output" | while IFS="" read -r line; do
      warn "  $line"
    done
    return 1
  }

  log "  Build root created successfully"
  echo "$build_dir"
}

# Destroy a build root.
# Args: $1 = build root directory
_build_devtools_destroy_root() {
  local build_dir="${1:?}"

  if [[ -d "$build_dir" ]]; then
    log "  Destroying build root: $build_dir"
    rm -rf "$build_dir"
  fi
}

# Sync build root with profile (update repos, install build deps).
# Args: $1 = build root directory
_build_devtools_sync_root() {
  local build_dir="${1:?}"
  local root="$build_dir/root"
  local pacman_conf="${PROFILE_PACMAN:?}"

  log "  Syncing build root"

  # Update the root — Phase 4 already performed pacman -Syu; only refresh databases here.
  arch-nspawn -C "$pacman_conf" "$root" pacman -Sy --noconfirm --ask=4 \
    > >(tail -5 | _pacman_filter_stdout) \
    2> >(tee -a "${PACMAN_RAW_LOG:-/dev/null}" | _pacman_filter_stderr >&2)
  if [[ "${PIPESTATUS[0]}" -ne 0 ]]; then
    warn "Failed to sync build root"
    return 1
  fi

  return 0
}

# Inject recipe sources into build root.
# Args: $1 = build root directory, $2 = recipe directory
_build_devtools_inject_sources() {
  local build_dir="${1:?}"
  local recipe_dir="${2:?}"
  local root="$build_dir/root"

  log "  Injecting recipe sources"

  # Copy PKGBUILD and patches into the build directory
  local build_src="$build_dir/build"
  mkdir -p "$build_src"
  cp "$recipe_dir/PKGBUILD" "$build_src/"

  # Copy patches if they exist
  if [[ -d "$recipe_dir/patches" ]]; then
    cp -r "$recipe_dir/patches" "$build_src/"
  fi

  # Copy any additional source files
  if [[ -d "$recipe_dir/sources" ]]; then
    cp -r "$recipe_dir/sources" "$build_src/"
  fi

  return 0
}

# Run the build using makechrootpkg.
# Args: $1 = build root directory, $2 = recipe directory, $3 = output directory
_build_devtools_run() {
  local build_dir="${1:?}"
  local recipe_dir="${2:?}"
  local output_dir="${3:?}"
  local root="$build_dir/root"
  local build_src="$build_dir/build"
  local pacman_conf="${PROFILE_PACMAN:?}"

  log "  Running build"

  # Ensure output directory exists
  mkdir -p "$output_dir"

  # Build with makechrootpkg
  # -r: chroot directory
  # -C: pacman.conf
  # -M: makepkg.conf
  # -l: copy directory (for build artifacts)
  # -o: install built packages into the chroot before building
  local build_log="$output_dir/build.log"

  (
    cd "$build_src" || exit 1
    makechrootpkg \
      -r "$root" \
      -C "$pacman_conf" \
      ${PROFILE_MAKEPKG:+-M "$PROFILE_MAKEPKG"} \
      -l "$output_dir" \
      2>&1
  ) | tee "$build_log" || {
    warn "Build failed — see log: $build_log"
    return 1
  }

  # Move any .pkg.tar.* from build_src to output_dir
  find "$build_src" -maxdepth 1 -name '*.pkg.tar.*' -type f -exec mv {} "$output_dir/" \; 2>/dev/null || true

  return 0
}
