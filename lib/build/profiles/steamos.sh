#!/bin/bash
#
# steamos-build-installer — lib/build/profiles/steamos.sh
# SteamOS-specific profile handling.
#
# Sourced by engine.sh — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/build/profiles/steamos.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Guard against double-sourcing
[[ -v _BUILD_STEAMOS_PROFILE_LOADED ]] && return 0
_BUILD_STEAMOS_PROFILE_LOADED=1

# ---------------------------------------------------------------------------
# SteamOS profile
# ---------------------------------------------------------------------------

# Get SteamOS version from a root.
# Args: $1 = root path
# Prints: version string
steamos_get_version() {
  local root="${1:?}"

  if [[ -f "$root/etc/os-release" ]]; then
    sed -n 's/^VERSION_ID=//p' "$root/etc/os-release" | tr -d '"'
  fi
}

# Get SteamOS build ID from a root.
# Args: $1 = root path
# Prints: build ID
steamos_get_build_id() {
  local root="${1:?}"

  if [[ -f "$root/etc/os-release" ]]; then
    sed -n 's/^BUILD_ID=//p' "$root/etc/os-release" | tr -d '"'
  fi
}

# Get the kernel version from a root.
# Args: $1 = root path
# Prints: kernel version
steamos_get_kernel_version() {
  local root="${1:?}"

  # Try from the installed kernel package
  local kernel_pkg=""
  local _kernel_dbpath
  _kernel_dbpath="$(resolve_pacman_dbpath "$root")" || _kernel_dbpath=""
  if [[ -n "$_kernel_dbpath" ]]; then
    kernel_pkg="$(pacman -Q --dbpath "$_kernel_dbpath" 2>/dev/null | grep '^linux-neptune' | sort -V | tail -1 | awk '{print $2}' || true)"
  fi

  if [[ -n "$kernel_pkg" ]]; then
    echo "$kernel_pkg"
  else
    # Fallback: look for installed kernel
    local moddir
    moddir="$(find "$root/usr/lib/modules" -maxdepth 1 -type d -name '6.*' 2>/dev/null | sort -V | tail -1)"
    if [[ -n "$moddir" ]]; then
      basename "$moddir"
    else
      echo "unknown"
    fi
  fi
}

# Derive a complete SteamOS build profile.
# Args: $1 = root path, $2 = output directory
# Sets: PROFILE_DIR
steamos_derive_profile() {
  local root="${1:?}"
  local output_dir="${2:-${WORKDIR:-/tmp}/steamos-profile-$$}"

  mkdir -p "$output_dir"

  log "Deriving SteamOS build profile"

  # Call the generic profile derivation
  if ! build_profile_from_root "$root" "$output_dir"; then
    log "ERROR: build_profile_from_root failed"
    return 1
  fi

  # Add SteamOS-specific metadata
  local version build_id kernel
  version="$(steamos_get_version "$root")"
  build_id="$(steamos_get_build_id "$root")"
  kernel="$(steamos_get_kernel_version "$root")"

  # Write with shell-safe quoting so that values containing spaces,
  # quotes, #, backslashes, or newlines don't corrupt the file.
  {
    printf 'STEAMOS_VERSION=%s\n' "$(printf '%q' "$version")"
    printf 'STEAMOS_BUILD_ID=%s\n' "$(printf '%q' "$build_id")"
    printf 'STEAMOS_KERNEL=%s\n' "$(printf '%q' "$kernel")"
  } >>"$output_dir/profile.conf"

  log "  SteamOS version: $version"
  log "  Build ID: $build_id"
  log "  Kernel: $kernel"
}
