#!/bin/bash
#
# steamos-build-installer — lib/build/engine.sh
# Clean-room build engine.  Nothing compiles in the target OS.
# Every build happens in a disposable root and produces a pacman package.
#
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/build/engine.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Guard against double-sourcing
[[ -v _BUILD_ENGINE_LOADED ]] && return 0
_BUILD_ENGINE_LOADED=1

# ---------------------------------------------------------------------------
# Dependency provenance tracking
# ---------------------------------------------------------------------------

# Track dependency resolution for logging.
declare -a _BUILD_DEP_LOG=()

# Log a dependency with its provenance.
# Args: $1 = name, $2 = version, $3 = source (valve/arch/local), $4 = class (abi-locked/fallback/build-only)
_build_log_dep() {
  local name="${1:?}" version="${2:?}" source="${3:?}" class="${4:?}"
  _BUILD_DEP_LOG+=("$(printf '%-20s %-16s %-24s %s' "$name" "$version" "$source" "$class")")
}

# Print the dependency provenance table.
_build_print_deps() {
  log "Dependency resolution"
  printf '  %-20s %-16s %-24s %s\n' "PACKAGE" "VERSION" "SOURCE" "CLASS" | while IFS="" read -r line; do log "$line"; done
  printf '  %-20s %-16s %-24s %s\n' "-------" "-------" "------" "-----" | while IFS="" read -r line; do log "$line"; done
  local entry
  for entry in "${_BUILD_DEP_LOG[@]}"; do
    log "  $entry"
  done
}

# Resolve a package's provenance against a profile.
# Args: $1 = root, $2 = package name
# Sets: _DEP_VERSION, _DEP_SOURCE, _DEP_CLASS
_build_resolve_dep() {
  local root="${1:?}" pkg="${2:?}"

  _DEP_VERSION="" _DEP_SOURCE="" _DEP_CLASS=""

  # Check if it's in the target image (Valve repos)
  local dbpath=""
  if [[ -d "$root/usr/lib/holo/pacmandb" ]]; then
    dbpath="$root/usr/lib/holo/pacmandb"
  elif [[ -d "$root/var/lib/pacman" ]]; then
    dbpath="$root/var/lib/pacman"
  fi

  if [[ -n "$dbpath" ]]; then
    local ver
    ver="$(pacman -Q --dbpath "$dbpath" "$pkg" 2>/dev/null | awk '{print $2}' || true)"
    if [[ -n "$ver" ]]; then
      _DEP_VERSION="$ver"
      _DEP_SOURCE="valve/image"
      if repo_is_arch_allowed "$pkg"; then
        _DEP_CLASS="build-only"
      else
        _DEP_CLASS="abi-locked"
      fi
      return 0
    fi
  fi

  # Check configured repos (Valve sync)
  local sync_ver
  sync_ver="$(pacman -Si "$pkg" 2>/dev/null | sed -n 's/^Version[[:space:]]*: //p' | head -1)"
  if [[ -n "$sync_ver" ]]; then
    _DEP_VERSION="$sync_ver"
    _DEP_SOURCE="valve/repos"
    if repo_is_arch_allowed "$pkg"; then
      _DEP_CLASS="build-only"
    else
      _DEP_CLASS="abi-locked"
    fi
    return 0
  fi

  # Check Arch repos
  if [[ -n "${AOTOFU_PACCONF:-}" ]]; then
    local arch_ver
    arch_ver="$(pacman --config "$AOTOFU_PACCONF" -Si "$pkg" 2>/dev/null | sed -n 's/^Version[[:space:]]*: //p' | head -1)"
    if [[ -n "$arch_ver" ]]; then
      _DEP_VERSION="$arch_ver"
      _DEP_SOURCE="arch/extra"
      if repo_is_arch_allowed "$pkg"; then
        _DEP_CLASS="fallback"
      else
        _DEP_CLASS="BLOCKED"
      fi
      return 0
    fi
  fi

  return 1
}

# Cleanup function for build_recipe trap
_build_cleanup_build_root=""
_build_cleanup_keep_failed=0
_build_parent_exit_trap=""
_build_parent_exit_code=""
_build_exit_cleanup() {
  if ((_build_cleanup_keep_failed)) && [[ -n "$_build_cleanup_build_root" && -d "$_build_cleanup_build_root" ]]; then
    warn "Build failed — preserving build root: $_build_cleanup_build_root"
    warn "Enter with: arch-nspawn $_build_cleanup_build_root/root"
  else
    if [[ -n "$_build_cleanup_build_root" && -d "$_build_cleanup_build_root" ]]; then
      _build_destroy_root "$_build_cleanup_build_root" || {
        warn "Build root cleanup failed, attempting force cleanup"
        _build_force_destroy_root "$_build_cleanup_build_root"
      }
    fi
  fi
  # Execute parent exit code directly (we're inside the EXIT handler,
  # so re-registering the trap via eval would not execute it)
  if [[ -n "$_build_parent_exit_code" ]]; then
    eval "$_build_parent_exit_code"
  fi
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# Robustly extract the first pkgname from a PKGBUILD directory.
#
# Handles arrays, split packages, comments, whitespace, and multi-line
# assignments by preferring .SRCINFO, then makepkg --printsrcinfo, then
# controlled sourcing of PKGBUILD.
#
# Args: $1 = directory containing PKGBUILD
# Prints: first package name (stdout)
# Returns: 0 on success, 1 on failure
_build_extract_pkgname() {
  local dir="${1:?}"

  # 1) Prefer .SRCINFO if present (no shell execution needed)
  if [[ -f "$dir/.SRCINFO" ]]; then
    local name
    name="$(sed -n 's/^[[:space:]]*pkgname[[:space:]]*=[[:space:]]*//p' "$dir/.SRCINFO" | head -1)"
    if [[ -n "$name" ]]; then
      echo "$name"
      return 0
    fi
  fi

  # 2) Use makepkg --printsrcinfo if available
  if command -v makepkg >/dev/null 2>&1 && [[ -f "$dir/PKGBUILD" ]]; then
    local srcinfo
    srcinfo="$(makepkg --printsrcinfo -p "$dir/PKGBUILD" 2>/dev/null)" || srcinfo=""
    if [[ -n "$srcinfo" ]]; then
      local name
      name="$(echo "$srcinfo" | sed -n 's/^[[:space:]]*pkgname[[:space:]]*=[[:space:]]*//p' | head -1)"
      if [[ -n "$name" ]]; then
        echo "$name"
        return 0
      fi
    fi
  fi

  # 3) Source PKGBUILD in a subshell to safely read pkgname array
  if [[ -f "$dir/PKGBUILD" ]]; then
    local name
    name="$(
      set +euo pipefail
      # Source only pkgname; define safe stubs for functions we don't need
      pkgname=()
      # shellcheck disable=SC1091
      source "$dir/PKGBUILD" 2>/dev/null || true
      if [[ ${#pkgname[@]} -gt 0 ]]; then
        echo "${pkgname[0]}"
      fi
    )"
    if [[ -n "$name" ]]; then
      echo "$name"
      return 0
    fi
  fi

  return 1
}

# Build a recipe against a profile, producing an artifact.
#
# Usage:
#   build_recipe --recipe DIR --profile PROFILE [--output DIR] [--keep-failed]
#
# Returns 0 on success, 1 on failure.  Sets BUILD_ARTIFACT to the .pkg.tar.zst path.
# IMPORTANT: This function NEVER installs anything into the target.
build_recipe() {
  local recipe_dir="" profile="" output_dir="" keep_failed=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --recipe)
        recipe_dir="$2"
        shift 2
        ;;
      --profile)
        profile="$2"
        shift 2
        ;;
      --output)
        output_dir="$2"
        shift 2
        ;;
      --keep-failed)
        keep_failed=1
        shift
        ;;
      *) die "build_recipe: unknown option: $1" ;;
    esac
  done

  [[ -n "$recipe_dir" ]] || die "build_recipe: --recipe is required"
  [[ -d "$recipe_dir" ]] || die "build_recipe: recipe directory not found: $recipe_dir"
  [[ -n "$profile" ]] || die "build_recipe: --profile is required"

  # Load recipe
  local recipe_conf="$recipe_dir/recipe.conf"
  [[ -f "$recipe_conf" ]] || die "build_recipe: recipe.conf not found in $recipe_dir"
  # shellcheck disable=SC1090
  source "$recipe_conf"

  local name="${NAME:?recipe.conf must set NAME}"
  local pkgbuild="$recipe_dir/PKGBUILD"

  # Extract pkgname from PKGBUILD (may differ from NAME in recipe.conf)
  local pkgname_str=""
  if [[ -f "$pkgbuild" ]]; then
    pkgname_str="$(_build_extract_pkgname "$recipe_dir")" || true
  fi
  PKGNAME="${pkgname_str:-$name}"

  # Check for direct install mode (INSTALL_CMD in recipe.conf)
  local install_cmd=""
  install_cmd="$(sed -n 's/^INSTALL_CMD=//p' "$recipe_conf" 2>/dev/null | tr -d '"' | head -1)"

  # PKGBUILD is required for package build mode, but not for direct install mode
  if [[ -z "$install_cmd" ]]; then
    [[ -f "$pkgbuild" ]] || die "build_recipe: PKGBUILD not found in $recipe_dir (required for package build mode)"
  fi

  # Default output directory
  output_dir="${output_dir:-${WORKDIR:-/tmp}/build-output/$name}"
  mkdir -p "$output_dir"

  log "Building recipe: $name"
  log "  recipe:  $recipe_dir"
  log "  profile: $profile"
  log "  output:  $output_dir"

  # Load profile
  _build_load_profile "$profile"

  # Source repository policy and initialize from recipe
  # shellcheck source=lib/build/repository.sh
  source "${BASH_SOURCE[0]%/*}/repository.sh"
  repo_init "$recipe_conf"

  # Resolve and log dependency provenance
  _BUILD_DEP_LOG=()
  local -a all_deps=("${RUNTIME_DEPS[@]}" "${BUILD_DEPS[@]}")
  local dep
  for dep in "${all_deps[@]}"; do
    if _build_resolve_dep "${PROFILE_ROOT:-/}" "$dep"; then
      _build_log_dep "$dep" "$_DEP_VERSION" "$_DEP_SOURCE" "$_DEP_CLASS"
    else
      _build_log_dep "$dep" "NOT FOUND" "none" "MISSING"
    fi
  done
  _build_print_deps

  # Create build root
  local build_root=""
  build_root="$(_build_create_root "$name" "$profile")" || die "Failed to create build root"

  # Ensure cleanup on exit — save and restore any parent EXIT trap
  _build_cleanup_build_root=""
  _build_cleanup_keep_failed=0
  _build_cleanup_build_root="$build_root"
  _build_cleanup_keep_failed="$keep_failed"
  _build_parent_exit_trap="$(trap -p EXIT)" || true
  _build_parent_exit_code=""
  if [[ -n "$_build_parent_exit_trap" ]]; then
    _build_parent_exit_code="$_build_parent_exit_trap"
    _build_parent_exit_code="${_build_parent_exit_code#trap -- \'}"
    _build_parent_exit_code="${_build_parent_exit_code#trap \'}"
    _build_parent_exit_code="${_build_parent_exit_code%\' EXIT}"
  fi
  trap _build_exit_cleanup EXIT

  # Sync build root with profile
  _build_sync_root "$build_root" || die "Failed to sync build root"

  # Inject recipe sources
  _build_inject_sources "$build_root" "$recipe_dir" || die "Failed to inject sources"

  # Build
  _build_run "$build_root" "$recipe_dir" "$output_dir" || {
    warn "Build failed for $name"
    return 1
  }

  # For direct install mode, the driver installs directly into the overlay
  # so there's no artifact to collect or verify
  if [[ -n "$install_cmd" ]]; then
    BUILD_ARTIFACT=""
    log "Build complete: direct install mode (no artifact)"
    log ""
    log "IMPORTANT: Direct install mode installs into the build root overlay."
    log "The driver is now available in the build root."
  else
    # Collect artifact (package build mode only)
    local artifact=""
    artifact="$(_build_collect_artifact "$output_dir" "$name")" || {
      warn "Failed to collect artifact for $name"
      return 1
    }

    # Verify artifact
    _build_verify_artifact "$artifact" "$profile" || {
      warn "Artifact verification failed for $name"
      return 1
    }

    # shellcheck disable=SC2034 # global set for callers (pipeline_build.sh, validate.sh, etc.)
    BUILD_ARTIFACT="$artifact"
    log "Build complete: $artifact"
    log ""
    log "IMPORTANT: build_recipe does NOT install into the target."
    log "Use install_build_artifact separately to install the package."
  fi

  # Disable cleanup trap on success, restore parent trap
  trap - EXIT
  if [[ -n "$_build_parent_exit_trap" ]]; then
    eval "$_build_parent_exit_trap"
    _build_parent_exit_trap=""
  fi
  _build_destroy_root "$build_root"

  return 0
}

# Install a build artifact into a target root.
#
# This function knows NOTHING about recipes.  Its contract is:
#   install_build_artifact ROOT PACKAGE
#
# It takes a root path and a .pkg.tar.zst, and installs it via pacman.
# Nothing else.
install_build_artifact() {
  local root="${1:?install_build_artifact: missing root}"
  local pkg="${2:?install_build_artifact: missing package}"

  [[ -f "$pkg" ]] || die "install_build_artifact: package not found: $pkg"

  log "Installing $(basename "$pkg") into $root"

  if [[ "$root" == "/" ]]; then
    pacman_install_local --needed -- "$pkg" || die "Failed to install $pkg"
  else
    cp "$pkg" "$root/tmp/"
    _pacman_retry chroot "$root" pacman --config "${PACCONF:-/etc/pacman.conf}" -U --noconfirm "/tmp/$(basename "$pkg")" || {
      rm -f "$root/tmp/$(basename "$pkg")"
      die "Failed to install $pkg into chroot"
    }
    rm -f "$root/tmp/$(basename "$pkg")"
  fi

  log "Installed $(basename "$pkg") successfully"
}

# Validate a build artifact after installation.
#
# Three-stage validation:
#   1. Package contents — verify expected files exist in the archive
#   2. Target installation — verify files landed and pass integrity check
#   3. Runtime linkage — verify all shared libraries resolve in the target
#
# Args: $1 = root path, $2 = package file, $3 = expected artifact path (chroot-relative, e.g. /usr/lib/dri/nvidia_drv_video.so)
# Returns 0 on success, 1 on failure
validate_build_artifact() {
  local root="${1:?validate_build_artifact: missing root}"
  local pkg="${2:?validate_build_artifact: missing package}"
  local artifact="${3:?validate_build_artifact: missing artifact path}"
  local rc=0

  local pkg_basename
  pkg_basename="$(basename "$pkg")"

  # Extract package metadata once
  local pkg_name="" pkg_ver=""
  if command -v bsdtar >/dev/null 2>&1; then
    local pkginfo
    pkginfo="$(bsdtar -xOf "$pkg" .PKGINFO 2>/dev/null)" || pkginfo=""
    if [[ -n "$pkginfo" ]]; then
      pkg_name="$(echo "$pkginfo" | sed -n 's/^pkgname = //p' | head -1)"
      pkg_ver="$(echo "$pkginfo" | sed -n 's/^pkgver = //p' | head -1)"
    fi
  fi

  log ""
  log "===== ARTIFACT VALIDATION ====="
  log "Package: $pkg_basename"
  [[ -n "$pkg_name" ]] && log "  pkgname: $pkg_name"
  [[ -n "$pkg_ver" ]] && log "  pkgver:  $pkg_ver"

  # ── Stage 1: Package contents ──────────────────────────────────────────
  if ! command -v bsdtar >/dev/null 2>&1; then
    warn "  bsdtar not available — skipping package content validation"
  else
    local artifact_no_slash="${artifact#/}"
    if bsdtar -tf "$pkg" 2>/dev/null | grep -qxF "$artifact_no_slash"; then
      log "  [OK] $artifact"
    else
      warn "  [FAILED] $artifact not found in package"
      rc=1
    fi

    # Identify the binary type if it's an ELF
    if [[ -f "$root$artifact" ]]; then
      local file_type
      file_type="$(file "$root$artifact" 2>/dev/null | sed 's/.*: //')"
      log "  [OK] $file_type"
    fi

    # Verify .PKGINFO has required fields
    if [[ -n "$pkginfo" ]]; then
      local _field
      for _field in pkgname pkgver arch; do
        if echo "$pkginfo" | grep -q "^${_field} = "; then
          :
        else
          warn "  [FAILED] .PKGINFO missing $_field"
          rc=1
        fi
      done
    else
      warn "  [FAILED] could not read .PKGINFO from package"
      rc=1
    fi
  fi

  # ── Stage 2: Target installation ───────────────────────────────────────
  local target_file="$root$artifact"
  if [[ -s "$target_file" ]]; then
    log "  [OK] installed ($(stat -c '%s' "$target_file") bytes)"
  else
    warn "  [FAILED] $artifact missing or empty in target"
    rc=1
  fi

  # Package integrity check
  if [[ -n "$pkg_name" ]]; then
    local qkk_output
    qkk_output="$(chroot "$root" pacman -Qkk "$pkg_name" 2>&1)" || qkk_output=""
    if echo "$qkk_output" | grep -q '0 altered files'; then
      log "  [OK] pacman integrity: 0 altered files"
    else
      local altered
      altered="$(echo "$qkk_output" | grep -oE '[0-9]+ altered files' | head -1)"
      warn "  [WARN] pacman integrity: ${altered:-unknown} (may be normal for first install)"
    fi
  fi

  # ── Stage 3: ELF dependency resolution ─────────────────────────────────
  if [[ "$artifact" == *.so || "$artifact" == *.so.* ]]; then
    log ""
    log "===== ELF DEPENDENCIES ====="
    log "Artifact: $artifact"

    local ldd_output
    ldd_output="$(chroot "$root" ldd "$artifact" 2>&1)" || ldd_output=""

    if [[ -z "$ldd_output" ]]; then
      warn "  ldd produced no output"
    else
      local dep_failed=0
      local line
      while IFS="" read -r line; do
        if [[ "$line" == *"not found"* ]]; then
          local lib_name
          lib_name="$(echo "$line" | awk '{print $1}')"
          warn "  [FAILED] $lib_name"
          dep_failed=1
          rc=1
        elif [[ "$line" =~ ^[[:space:]]([^[:space:]]+\.so[^[:space:]]*) ]]; then
          local lib_name="${BASH_REMATCH[1]}"
        fi
      done <<<"$ldd_output"

      # List resolved NEEDED libraries from readelf for clarity
      local needed_libs
      needed_libs="$(readelf -d "$root$artifact" 2>/dev/null | grep NEEDED | awk '{print $5}' | tr -d '[]')" || needed_libs=""
      if [[ -n "$needed_libs" ]]; then
        while IFS="" read -r lib; do
          [[ -n "$lib" ]] || continue
          if echo "$ldd_output" | grep -q "$lib.*not found"; then
            warn "  [FAILED] $lib"
          else
            log "  [OK] $lib"
          fi
        done <<<"$needed_libs"
      fi

      if ((dep_failed == 0)); then
        log "  [OK] All NEEDED libraries resolvable in target"
      else
        warn "  [FAILED] Unresolved dependencies detected"
      fi
    fi
  fi

  log ""
  if ((rc == 0)); then
    log "Artifact validation passed: $pkg_basename"
  else
    warn "Artifact validation FAILED: $pkg_basename"
  fi
  return "$rc"
}

# Derive a build profile from an existing root filesystem.
#
# Usage:
#   build_profile_from_root ROOT [OUTPUT_DIR]
#
# Sets PROFILE_DIR to the generated profile directory.
build_profile_from_root() {
  local root="${1:?build_profile_from_root: missing root}"
  local output_dir="${2:-${WORKDIR:-/tmp}/build-profile-$$}"

  mkdir -p "$output_dir"

  log "Deriving build profile from $root"

  # Detect OS
  local os_id="" os_version=""
  if [[ -f "$root/etc/os-release" ]]; then
    os_id="$(sed -n 's/^ID=//p' "$root/etc/os-release" | tr -d '"')"
    os_version="$(sed -n 's/^VERSION_ID=//p' "$root/etc/os-release" | tr -d '"')"
  fi

  # Detect architecture
  local arch="x86_64"
  if [[ -f "$root/etc/pacman.conf" ]]; then
    arch="$(sed -n 's/^[[:space:]]*Architecture[[:space:]]*=//p' "$root/etc/pacman.conf" | head -1 | tr -d ' ')"
    [[ "$arch" == "auto" ]] && arch="$(uname -m)"
  fi

  # Detect glibc version
  local glibc_ver=""
  if [[ -d "$root/usr/lib/holo/pacmandb" ]]; then
    glibc_ver="$(pacman -Q --dbpath "$root/usr/lib/holo/pacmandb" glibc 2>/dev/null | awk '{print $2}' || true)"
  fi

  # Generate pacman.conf for the profile
  local profile_pacman="$output_dir/pacman.conf"
  _build_generate_pacman_conf "$root" "$profile_pacman"

  # Generate makepkg.conf
  local profile_makepkg="$output_dir/makepkg.conf"
  _build_generate_makepkg_conf "$arch" "$profile_makepkg"

  # Record package versions for ABI-critical packages
  local packages_lock="$output_dir/packages.lock"
  _build_record_package_versions "$root" "$packages_lock"

  # Write profile metadata
  cat >"$output_dir/profile.conf" <<EOF
PROFILE_NAME=${os_id:-unknown}
PROFILE_VERSION=${os_version:-unknown}
PROFILE_ARCH=$arch
PROFILE_GLIBC=$glibc_ver
PROFILE_PACMAN=$profile_pacman
PROFILE_MAKEPKG=$profile_makepkg
PROFILE_PACKAGES_LOCK=$packages_lock
PROFILE_ROOT=$root
PROFILE_GENERATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

  # shellcheck disable=SC2034 # global set for callers (pipeline_build.sh, validate.sh, etc.)
  PROFILE_DIR="$output_dir"
  log "Profile generated: $output_dir"
  log "  OS: ${os_id:-unknown} ${os_version:-unknown}"
  log "  Arch: $arch"
  log "  glibc: ${glibc_ver:-unknown}"
}

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

# Load a profile into the current shell.
_build_load_profile() {
  local profile_dir="${1:?}"

  if [[ -f "$profile_dir/profile.conf" ]]; then
    # shellcheck disable=SC1091
    source "$profile_dir/profile.conf"
  elif [[ -f "$profile_dir" ]]; then
    # shellcheck disable=SC1090
    source "$profile_dir"
  else
    die "Profile not found: $profile_dir"
  fi

  PROFILE_PACMAN="${PROFILE_PACMAN:?profile must set PROFILE_PACMAN}"
  PROFILE_MAKEPKG="${PROFILE_MAKEPKG:-}"
  PROFILE_ARCH="${PROFILE_ARCH:-x86_64}"
}

# Create a clean build root using the configured backend.
_build_create_root() {
  local name="${1:?}" profile="${2:?}"
  local backend="${BUILD_BACKEND:-overlay-chroot}"

  case "$backend" in
    arch-devtools)
      _build_devtools_create_root "$name" "$profile"
      ;;
    overlay-chroot)
      _build_overlay_create_root "$name" "$profile"
      ;;
    *)
      die "Unknown build backend: $backend"
      ;;
  esac
}

# Destroy a build root.
_build_destroy_root() {
  local build_root="${1:?}"
  local backend="${BUILD_BACKEND:-overlay-chroot}"

  case "$backend" in
    arch-devtools)
      _build_devtools_destroy_root "$build_root"
      ;;
    overlay-chroot)
      _build_overlay_destroy_root "$build_root"
      ;;
  esac
}

# Force destroy a build root (aggressive cleanup for failed builds).
_build_force_destroy_root() {
  local build_root="${1:?}"
  local backend="${BUILD_BACKEND:-overlay-chroot}"

  case "$backend" in
    arch-devtools)
      _build_devtools_destroy_root "$build_root"
      ;;
    overlay-chroot)
      _build_overlay_force_destroy_root "$build_root"
      ;;
  esac
}

# Sync build root with profile (repos, packages).
_build_sync_root() {
  local build_root="${1:?}"
  local backend="${BUILD_BACKEND:-overlay-chroot}"

  case "$backend" in
    arch-devtools)
      _build_devtools_sync_root "$build_root"
      ;;
    overlay-chroot)
      _build_overlay_sync_root "$build_root"
      ;;
  esac
}

# Inject recipe sources into build root.
_build_inject_sources() {
  local build_root="${1:?}"
  local recipe_dir="${2:?}"
  local backend="${BUILD_BACKEND:-overlay-chroot}"

  case "$backend" in
    arch-devtools)
      _build_devtools_inject_sources "$build_root" "$recipe_dir"
      ;;
    overlay-chroot)
      _build_overlay_inject_sources "$build_root" "$recipe_dir"
      ;;
  esac
}

# Run the build.
_build_run() {
  local build_root="${1:?}"
  local recipe_dir="${2:?}"
  local output_dir="${3:?}"
  local backend="${BUILD_BACKEND:-overlay-chroot}"

  case "$backend" in
    arch-devtools)
      _build_devtools_run "$build_root" "$recipe_dir" "$output_dir"
      ;;
    overlay-chroot)
      _build_overlay_run "$build_root" "$recipe_dir" "$output_dir"
      ;;
  esac
}

# Collect the built artifact.
_build_collect_artifact() {
  local output_dir="${1:?}"
  local name="${2:?}"

  # Find all built packages
  local -a pkgs=()
  mapfile -t pkgs < <(find "$output_dir" -maxdepth 1 -name '*.pkg.tar.*' -type f 2>/dev/null)
  ((${#pkgs[@]})) || return 1

  # If only one package, use it
  if ((${#pkgs[@]} == 1)); then
    echo "${pkgs[0]}"
    return 0
  fi

  # Multiple packages — select the one whose .PKGINFO pkgname matches the
  # recipe's expected pkgname.  This avoids picking a -debug package over
  # the actual artifact.
  local expected_pkgname=""
  if [[ -n "${PKGNAME:-}" ]]; then
    expected_pkgname="$PKGNAME"
  elif [[ -n "${name:-}" ]]; then
    # Fall back: try to read pkgname from the PKGBUILD in the output dir
    expected_pkgname="$name"
  fi

  local pkg
  for pkg in "${pkgs[@]}"; do
    local pkginfo_name
    pkginfo_name="$(bsdtar -xOf "$pkg" .PKGINFO 2>/dev/null | sed -n 's/^pkgname = //p' | head -1)" || pkginfo_name=""
    if [[ -n "$expected_pkgname" && "$pkginfo_name" == "$expected_pkgname" ]]; then
      echo "$pkg"
      return 0
    fi
  done

  # Fallback: exclude -debug packages, then pick newest
  local -a non_debug=()
  for pkg in "${pkgs[@]}"; do
    local pkginfo_name
    pkginfo_name="$(bsdtar -xOf "$pkg" .PKGINFO 2>/dev/null | sed -n 's/^pkgname = //p' | head -1)" || pkginfo_name=""
    if [[ "$pkginfo_name" != *-debug ]]; then
      non_debug+=("$pkg")
    fi
  done

  if ((${#non_debug[@]} > 0)); then
    printf '%s\n' "${non_debug[@]}" | sort -V | tail -1
    return 0
  fi

  # Last resort: newest package
  printf '%s\n' "${pkgs[@]}" | sort -V | tail -1
}

# Verify a built artifact against a profile.
_build_verify_artifact() {
  local pkg="${1:?}"
  local profile="${2:?}"

  # Source verification module
  # shellcheck source=lib/build/verify.sh
  source "${BASH_SOURCE[0]%/*}/verify.sh"

  verify_package_metadata "$pkg" || return 1
  verify_package_abi_compat "$pkg" "$profile" || return 1

  return 0
}

# Generate a pacman.conf for a build profile.
_build_generate_pacman_conf() {
  # shellcheck source=lib/build/repository.sh
  source "${BASH_SOURCE[0]%/*}/repository.sh"
  repo_generate_config "$1" "$2" 1
}

# Generate a makepkg.conf for a build profile.
_build_generate_makepkg_conf() {
  local arch="${1:-x86_64}"
  local output="${2:?}"

  cat >"$output" <<EOF
DLAGENTS=('ftp::/usr/bin/curl -gqfC - --ftp-pasv --retry 3 --retry-delay 3 -o %o %u'
          'http::/usr/bin/curl -gqfcL -o %o %u'
          'https::/usr/bin/curl -gqfcL -o %o %u'
          'rsync::/usr/bin/rsync -z %u %o'
          'scp::/usr/bin/scp -C %u %o')

CARCH="${arch}"
CHOST="${arch}-pc-linux-gnu"

CFLAGS="-march=x86-64 -mtune=generic -O2 -pipe -fno-plt -fexceptions \
        -Wp,-D_FORTIFY_SOURCE=3 -Wformat -Werror=format-security \
        -fstack-clash-protection -fcf-protection"
CXXFLAGS="\$CFLAGS"
LDFLAGS="-Wl,-O1 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now \
         -Wl,-z,pack-relative-relocs"
RUSTFLAGS="-Cforce-frame-pointers=yes"
MAKEFLAGS="-j\$(nproc)"
DEBUG_CFLAGS="-g"
DEBUG_CXXFLAGS="\$DEBUG_CFLAGS"
BUILDENV=(!distcc !ccache check !sign)
OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug !lto)
INTEGRITY_CHECK=(sha256)
STRIP_BINARIES="--strip-all"
STRIP_SHARED="--strip-unneeded"
STRIP_STATIC="--strip-debug"
MAN_DIRS=({usr{,/local}{,/share},opt/*}/{man,info})
DOC_DIRS=(usr/{,local/}{,share/}{doc,gtk-doc} opt/*/{doc,gtk-doc})
PKGDEST=/tmp/build-output
SRCDEST=/tmp/build-src
SRCPKGDEST=/tmp/build-srcpkg
LOGDEST=/tmp/build-logs
PACKAGER="steamos-build-installer <noreply@steamos-build>"
EOF
}

# Record ABI-critical package versions from a root.
# Args: $1 = root path, $2 = output file, $3 = recipe.conf path (optional)
_build_record_package_versions() {
  local root="${1:?}"
  local output="${2:?}"
  local recipe_conf="${3:-}"

  local dbpath=""
  if [[ -d "$root/usr/lib/holo/pacmandb" ]]; then
    dbpath="$root/usr/lib/holo/pacmandb"
  elif [[ -d "$root/var/lib/pacman" ]]; then
    dbpath="$root/var/lib/pacman"
  else
    warn "No pacman database found in $root"
    touch "$output"
    return 0
  fi

  # Base ABI-critical packages (generic system packages)
  local -a critical=(
    glibc gcc-libs
    systemd linux linux-api-headers
  )

  # Add recipe-specific ABI-critical packages if provided
  if [[ -n "$recipe_conf" && -f "$recipe_conf" ]]; then
    local extra_str
    extra_str="$(sed -n '/^ABI_CRITICAL_PKGS=(/,/)/{s/^ABI_CRITICAL_PKGS=(//;s/)[[:space:]]*$//;/^[[:space:]]*$/d;p}' "$recipe_conf" 2>/dev/null)"
    if [[ -n "$extra_str" ]]; then
      local -a extra_pkgs
      eval "extra_pkgs=($extra_str)"
      critical+=("${extra_pkgs[@]}")
    fi
  fi

  : >"$output"
  local pkg
  for pkg in "${critical[@]}"; do
    local ver=""
    ver="$(pacman -Q --dbpath "$dbpath" "$pkg" 2>/dev/null | awk '{print $2}' || true)"
    [[ -n "$ver" ]] && printf '%s=%s\n' "$pkg" "$ver" >>"$output"
  done
}
