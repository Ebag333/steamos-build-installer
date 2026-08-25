#!/bin/bash
#
# steamos-nvidia-installer — lib/build/verify.sh
# Package verification utilities.
#
# Sourced by engine.sh — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/build/verify.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Guard against double-sourcing
[[ -v _BUILD_VERIFY_LOADED ]] && return 0
_BUILD_VERIFY_LOADED=1

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# Verify package metadata is valid.
# Args: $1 = package path
# Returns 0 if valid, 1 if invalid.
verify_package_metadata() {
  local pkg="${1:?}"

  [[ -f "$pkg" ]] || {
    warn "Package not found: $pkg"
    return 1
  }

  # Check it's a valid pacman package
  local pkg_name
  pkg_name="$(pacman -Qip "$pkg" 2>/dev/null | sed -n 's/^Name[[:space:]]*: //p')"
  if [[ -z "$pkg_name" ]]; then
    warn "Invalid package: $pkg"
    return 1
  fi

  log "  Package metadata: $pkg_name"
  return 0
}

# Verify package ABI compatibility with a profile.
# Args: $1 = package path, $2 = profile dir
# Returns 0 if compatible, 1 if incompatible.
verify_package_abi_compat() {
  local pkg="${1:?}"
  local profile_dir="${2:?}"

  # Load profile
  local packages_lock="$profile_dir/packages.lock"
  if [[ ! -f "$packages_lock" ]]; then
    log "  No packages.lock — skipping ABI check"
    return 0
  fi

  # Get package dependencies
  local pkg_deps
  pkg_deps="$(pacman -Qip "$pkg" 2>/dev/null | sed -n 's/^Depends On[[:space:]]*: //p')"
  if [[ -z "$pkg_deps" ]]; then
    log "  No dependencies — skipping ABI check"
    return 0
  fi

  # Check each dependency against the lock file
  local dep
  for dep in $pkg_deps; do
    # Strip version constraints
    local dep_name="${dep%%[><=]*}"
    local dep_ver="${dep#*[><=]}"

    # Check if this is an ABI-critical package
    local locked_ver=""
    locked_ver="$(grep "^${dep_name}=" "$packages_lock" 2>/dev/null | cut -d= -f2-)"

    if [[ -n "$locked_ver" && -n "$dep_ver" ]]; then
      # Compare versions
      if [[ "$dep_ver" != "$locked_ver" ]]; then
        warn "ABI mismatch: $dep_name requires $dep_ver but profile has $locked_ver"
        return 1
      fi
    fi
  done

  log "  ABI compatibility: OK"
  return 0
}

# Generate SHA256 checksum for a package.
# Args: $1 = package path
# Prints: checksum
verify_package_checksum() {
  local pkg="${1:?}"

  sha256sum "$pkg" | awk '{print $1}'
}

# Inspect package contents.
# Args: $1 = package path
# Prints: package info and file list
verify_package_inspect() {
  local pkg="${1:?}"

  echo "=== Package Info ==="
  pacman -Qip "$pkg" 2>/dev/null

  echo ""
  echo "=== Package Contents ==="
  pacman -Qlp "$pkg" 2>/dev/null | head -20

  local total
  total="$(pacman -Qlp "$pkg" 2>/dev/null | wc -l)"
  if ((total > 20)); then
    echo "  ... and $((total - 20)) more files"
  fi
}
