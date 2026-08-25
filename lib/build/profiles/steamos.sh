#!/bin/bash
#
# steamos-nvidia-installer — lib/build/profiles/steamos.sh
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

# Detect if a root is SteamOS.
# Args: $1 = root path
# Returns 0 if SteamOS, 1 if not.
steamos_is_steamos() {
  local root="${1:?}"

  [[ -f "$root/etc/os-release" ]] || return 1

  local id
  id="$(sed -n 's/^ID=//p' "$root/etc/os-release" | tr -d '"')"
  [[ "$id" == "steamos" || "$id" == "holo" ]]
}

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
  if [[ -d "$root/usr/lib/holo/pacmandb" ]]; then
    kernel_pkg="$(pacman -Q --dbpath "$root/usr/lib/holo/pacmandb" 2>/dev/null | grep '^linux-neptune' | head -1 | awk '{print $2}' || true)"
  fi

  if [[ -n "$kernel_pkg" ]]; then
    echo "$kernel_pkg"
  else
    # Fallback: look for installed kernel
    find "$root/usr/lib/modules" -maxdepth 1 -type d -name '6.*' 2>/dev/null | head -1 | xargs basename 2>/dev/null || echo "unknown"
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
  build_profile_from_root "$root" "$output_dir"

  # Add SteamOS-specific metadata
  local version build_id kernel
  version="$(steamos_get_version "$root")"
  build_id="$(steamos_get_build_id "$root")"
  kernel="$(steamos_get_kernel_version "$root")"

  cat >>"$output_dir/profile.conf" <<EOF
STEAMOS_VERSION=$version
STEAMOS_BUILD_ID=$build_id
STEAMOS_KERNEL=$kernel
EOF

  log "  SteamOS version: $version"
  log "  Build ID: $build_id"
  log "  Kernel: $kernel"
}
