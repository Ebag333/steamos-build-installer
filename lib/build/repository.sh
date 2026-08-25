#!/bin/bash
#
# steamos-nvidia-installer — lib/build/repository.sh
# Repository policy enforcement.
#
# Sourced by engine.sh — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/build/repository.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Guard against double-sourcing
[[ -v _BUILD_REPO_LOADED ]] && return 0
_BUILD_REPO_LOADED=1

# ---------------------------------------------------------------------------
# Repository policy
# ---------------------------------------------------------------------------

# Packages that are allowed to come from Arch repos (build tools).
# These are safe because they don't affect runtime ABI.
ARCH_FALLBACK_ALLOWED=(
  cmake
  meson
  ninja
  git
  patch
  pkgconf
  python
  python-build
  python-installer
  python-setuptools
  python-wheel
  autoconf
  automake
  bison
  flex
  m4
  make
  gcc
  binutils
  debugedit
  fakeroot
)

# Packages that must NEVER come from Arch repos (ABI-critical).
# These must match the target image exactly.
ARCH_FALLBACK_DENIED=(
  glibc
  gcc-libs
  libgcc
  libstdc++
  libdrm
  libva
  libglvnd
  mesa
  llvm
  llvm-libs
  systemd
  linux
  linux-api-headers
  vulkan-icd-loader
  vulkan-tools
  gst-plugins-bad-libs
  gstreamer
)

# Check if a package is allowed to come from Arch repos.
# Args: $1 = package name
# Returns 0 if allowed, 1 if denied.
repo_is_arch_allowed() {
  local pkg="${1:?}"

  # Check denied list first
  local denied
  for denied in "${ARCH_FALLBACK_DENIED[@]}"; do
    [[ "$pkg" == "$denied" ]] && return 1
  done

  # Check allowed list
  local allowed
  for allowed in "${ARCH_FALLBACK_ALLOWED[@]}"; do
    [[ "$pkg" == "$allowed" ]] && return 0
  done

  # Unknown packages are denied by default
  return 1
}

# Check if a package is in the target image.
# Args: $1 = root path, $2 = package name
# Returns 0 if installed, 1 if not.
repo_is_in_target() {
  local root="${1:?}"
  local pkg="${2:?}"

  local dbpath=""
  if [[ -d "$root/usr/lib/holo/pacmandb" ]]; then
    dbpath="$root/usr/lib/holo/pacmandb"
  elif [[ -d "$root/var/lib/pacman" ]]; then
    dbpath="$root/var/lib/pacman"
  else
    return 1
  fi

  pacman -Q --dbpath "$dbpath" "$pkg" >/dev/null 2>&1
}

# Validate that a package transaction doesn't cross distro boundaries.
# Args: $1 = root path, $@ = package names
# Returns 0 if safe, 1 if any package would cross distro boundaries.
repo_validate_transaction() {
  local root="${1:?}"
  shift

  local pkg
  for pkg in "$@"; do
    # Strip version pin
    pkg="${pkg%%=*}"

    # Skip empty
    [[ -z "$pkg" ]] && continue

    # If the package is in the target image and not in the allowed list, reject
    if repo_is_in_target "$root" "$pkg"; then
      if ! repo_is_arch_allowed "$pkg"; then
        warn "Cross-distro upgrade blocked: $pkg is already installed from target"
        return 1
      fi
    fi
  done

  return 0
}

# Generate a pacman config with proper repository priority.
# Args: $1 = target root, $2 = output path, $3 = include arch repos (0/1)
repo_generate_config() {
  local root="${1:?}"
  local output="${2:?}"
  local include_arch="${3:-1}"

  # Read DBPath from the target's config
  local dbpath
  dbpath="$(sed -n 's/^[[:space:]]*DBPath[[:space:]]*=//p' "$root/etc/pacman.conf" 2>/dev/null | head -1 | tr -d ' ')"
  [[ -n "$dbpath" ]] || dbpath="/var/lib/pacman"

  # Start with options
  {
    printf '[options]\n'
    printf 'SigLevel = Never\n'
    printf 'Architecture = %s\n' "${PROFILE_ARCH:-x86_64}"
    printf 'DBPath = %s\n' "$dbpath"
    printf '\n'
  } >"$output"

  # Append repo sections from the target's config (skip [options])
  sed -n '/^\[/,$p' "$root/etc/pacman.conf" 2>/dev/null | sed '/^\[options\]/,/^$/d' >>"$output"

  # Optionally append Arch repos
  if ((include_arch)); then
    cat >>"$output" <<'EOF'

[core]
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch

[extra]
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch

[multilib]
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
EOF
  fi
}
