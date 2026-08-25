#!/bin/bash
#
# steamos-nvidia-installer — lib/builds/common.sh
# Shared utilities for custom build modules.
# Provides common functions for fetching, building, and installing packages.
#
# Sourced by build modules — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/builds/common.sh is a library — source it from build modules, not run directly." >&2
  exit 1
fi

BUILDS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Build Registry
# ---------------------------------------------------------------------------
# Track which builds are registered for build/rebuild

# Use -gA (global associative) to ensure arrays persist when sourced from functions
declare -gA _BUILD_MODULES=()
declare -gA _BUILD_DESC=()

# Register a build module.
# Args: $1 = build name, $2 = description
register_build() {
  local name="${1:?register_build: missing name}"
  local desc="${2:-}"

  _BUILD_MODULES["$name"]=1
  _BUILD_DESC["$name"]="$desc"
}

# Check if a build is registered.
# Args: $1 = build name
# Returns 0 if registered, 1 if not
is_build_registered() {
  local name="${1:?is_build_registered: missing name}"
  [[ "${_BUILD_MODULES[$name]:-}" == "1" ]]
}

# List all registered builds.
# Output: one build name per line
list_builds() {
  local name
  for name in "${!_BUILD_MODULES[@]}"; do
    echo "$name"
  done
}

# ---------------------------------------------------------------------------
# Source Management
# ---------------------------------------------------------------------------

# Download a file with retry logic.
# Args: $1 = URL, $2 = output file
# Returns 0 on success, 1 on failure
download_with_retry() {
  local url="${1:?download_with_retry: missing URL}"
  local output="${2:?download_with_retry: missing output}"
  local retries="${3:-3}"

  local i
  for ((i = 1; i <= retries; i++)); do
    if curl -sfL "$url" -o "$output" 2>/dev/null; then
      return 0
    fi
    log "  Download attempt $i failed, retrying..."
    sleep 1
  done

  warn "Failed to download after $retries attempts: $url"
  return 1
}

# ---------------------------------------------------------------------------
# Build Helpers
# ---------------------------------------------------------------------------

# Check if kernel headers are available for building.
# Args: $1 = root path, $2 = kernel version
# Returns 0 if available, 1 if not
check_kernel_headers() {
  local root="${1:?check_kernel_headers: missing root}"
  local kver="${2:?check_kernel_headers: missing kernel version}"

  if [[ -d "$root/usr/lib/modules/$kver/build" ]]; then
    return 0
  else
    warn "Kernel headers not found for $kver"
    return 1
  fi
}

# Check if a kernel config option is set to a specific value.
# Args: $1 = root path, $2 = kernel version, $3 = config option, $4 = expected value
# Returns 0 if matches, 1 if not
check_kernel_config() {
  local root="${1:?check_kernel_config: missing root}"
  local kver="${2:?check_kernel_config: missing kernel version}"
  local option="${3:?check_kernel_config: missing option}"
  local expected="${4:-m}"

  local kconfig="$root/usr/lib/modules/$kver/build/.config"
  if [[ ! -f "$kconfig" ]]; then
    warn "Kernel config not found at $kconfig"
    return 1
  fi

  local val
  val="$(grep "^CONFIG_${option}=" "$kconfig" 2>/dev/null | cut -d= -f2)"

  case "$val" in
    "$expected") return 0 ;;
    y) [[ "$expected" == "y" ]] && return 0 ;;
    *) return 1 ;;
  esac
}

# Build kernel modules in a chroot.
# Args: $1 = root path, $2 = kernel version, $3 = source directory, $4 = build directory
# Returns 0 on success, 1 on failure
build_kernel_modules() {
  local root="${1:?build_kernel_modules: missing root}"
  local kver="${2:?build_kernel_modules: missing kernel version}"
  local src_dir="${3:?build_kernel_modules: missing source dir}"
  local build_dir="${4:?build_kernel_modules: missing build dir}"

  # Clean and build
  if ! chroot "$root" make -C "/usr/lib/modules/$kver/build" M="$build_dir" clean 2>&1; then
    warn "Failed to clean build directory"
    return 1
  fi

  if ! chroot "$root" make -C "/usr/lib/modules/$kver/build" M="$build_dir" modules 2>&1; then
    warn "Failed to build modules"
    return 1
  fi

  return 0
}

# Install kernel modules to /updates directory.
# Args: $1 = root path, $2 = kernel version, $3 = build directory, $4 = module names (space-separated), $5 = subdirectory
# Returns 0 on success, 1 on failure
install_kernel_modules() {
  local root="${1:?install_kernel_modules: missing root}"
  local kver="${2:?install_kernel_modules: missing kernel version}"
  local build_dir="${3:?install_kernel_modules: missing build dir}"
  local modules="${4:?install_kernel_modules: missing modules}"
  local subdir="${5:-}"

  local install_base="/usr/lib/modules/$kver/updates"
  [[ -n "$subdir" ]] && install_base="$install_base/$subdir"

  local mod
  for mod in $modules; do
    local ko="$build_dir/$mod.ko"
    local install_path="$install_base/$mod.ko"

    if ! chroot "$root" install -Dm644 "$ko" "$install_path"; then
      warn "Failed to install $mod.ko"
      return 1
    fi
  done

  # Run depmod to update module database
  chroot "$root" depmod "$kver"

  return 0
}

# Verify installed modules are in /updates directory.
# Args: $1 = root path, $2 = kernel version, $3 = module names (space-separated), $4 = subdirectory
# Returns 0 if all verified, 1 if any fail
verify_installed_modules() {
  local root="${1:?verify_installed_modules: missing root}"
  local kver="${2:?verify_installed_modules: missing kernel version}"
  local modules="${3:?verify_installed_modules: missing modules}"
  local subdir="${4:-}"

  local mod
  for mod in $modules; do
    local installed_path
    installed_path="$(chroot "$root" modinfo -k "$kver" -n "$mod" 2>/dev/null)"

    if [[ -n "$subdir" ]]; then
      [[ "$installed_path" == */updates/$subdir/* ]] || {
        warn "$mod resolves to $installed_path — not in /updates/$subdir/"
        return 1
      }
    else
      [[ "$installed_path" == */updates/* ]] || {
        warn "$mod resolves to $installed_path — not in /updates/"
        return 1
      }
    fi
  done

  return 0
}

# ---------------------------------------------------------------------------
# Bundle Management
# ---------------------------------------------------------------------------

# Create a driver source bundle for self-heal.
# Args: $1 = source directory, $2 = bundle directory
# Returns 0 on success, 1 on failure
create_driver_bundle() {
  local src_dir="${1:?create_driver_bundle: missing source dir}"
  local bundle_dir="${2:?create_driver_bundle: missing bundle dir}"

  rm -rf "$bundle_dir"
  mkdir -p "$bundle_dir"
  cp -a "$src_dir/." "$bundle_dir/"

  return 0
}

# Load driver sources from a bundle.
# Args: $1 = bundle directory, $2 = destination directory
# Returns 0 on success, 1 on failure
load_driver_bundle() {
  local bundle_dir="${1:?load_driver_bundle: missing bundle dir}"
  local dest_dir="${2:?load_driver_bundle: missing destination dir}"

  if [[ ! -d "$bundle_dir" ]]; then
    warn "Driver bundle not found: $bundle_dir"
    return 1
  fi

  rm -rf "$dest_dir"
  mkdir -p "$dest_dir"
  cp -a "$bundle_dir/." "$dest_dir/"

  return 0
}

# ---------------------------------------------------------------------------
# Flatpak Support
# ---------------------------------------------------------------------------

# Install a flatpak package from GitHub releases.
# Args: $1 = GitHub repo (e.g., "Recol/DLSS-Updater"), $2 = install type (user|system), $3 = root path (optional)
# Returns 0 on success, 1 on failure
install_flatpak_from_github() {
  local repo="${1:?install_flatpak_from_github: missing repo}"
  local install_type="${2:-user}"
  local root="${3:-/}"

  log "  Installing flatpak from GitHub: $repo"

  # Get latest release URL
  local url
  url="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
    | grep -oE '"browser_download_url": *"[^"]+\.flatpak"' \
    | head -1 | cut -d'"' -f4)"

  if [[ -z "$url" ]]; then
    warn "  No flatpak found for $repo"
    return 1
  fi

  local file="${url##*/}"
  local tmp="/tmp/$file"

  # Download
  log "  Downloading: $url"
  if ! download_with_retry "$url" "$tmp"; then
    return 1
  fi

  # Live system: install directly
  if [[ "$root" == "/" ]]; then
    log "  Installing: $file"
    local install_output
    install_output="$(flatpak install --"$install_type" -y "$tmp" 2>&1)"
    if [[ $? -ne 0 ]]; then
      warn "  Failed to install flatpak: $file"
      warn "  flatpak output: $install_output"
      rm -f "$tmp"
      return 1
    fi
    rm -f "$tmp"
    log "  Flatpak installed: $repo"
    return 0
  fi

  # Build/rebuild: stage for first-boot installation
  log "  Build environment detected — staging Flatpak for first boot"
  local stage_dir="$root/usr/share/steamos-nvidia/flatpaks"
  mkdir -p "$stage_dir"

  # Use stable filename based on repo name
  local stable_name
  stable_name="$(echo "$repo" | tr '/' '-' | tr '[:upper:]' '[:lower:]').flatpak"
  cp "$tmp" "$stage_dir/$stable_name"

  # Install systemd user service for first-boot installation
  local service_dir="$root/etc/systemd/user"
  local wants_dir="$root/etc/systemd/user/default.target.wants"
  mkdir -p "$wants_dir"

  # Install service file
  if [[ -f "$BUILDS_DIR/../configs/steamos-nvidia-flatpak-install.service" ]]; then
    cp "$BUILDS_DIR/../configs/steamos-nvidia-flatpak-install.service" "$service_dir/"
  fi

  # Install installer script
  if [[ -f "$BUILDS_DIR/../configs/install-staged-flatpaks.sh" ]]; then
    install -m 755 "$BUILDS_DIR/../configs/install-staged-flatpaks.sh" "$root/usr/lib/steamos-nvidia/install-staged-flatpaks"
  fi

  # Enable service
  ln -sf /etc/systemd/user/steamos-nvidia-flatpak-install.service \
    "$wants_dir/steamos-nvidia-flatpak-install.service"

  rm -f "$tmp"
  log "  Flatpak staged: $repo"
  return 0
}

# Install flatpak packages from configuration.
# Args: $1 = root path (optional, defaults to /)
# Returns 0 on success, 1 on failure
install_flatpak_packages() {
  local root="${1:-/}"
  local conf="$BUILDS_DIR/../configs/hw-packages-build.conf"

  if [[ ! -r "$conf" ]]; then
    warn "Build config not found: $conf"
    return 1
  fi

  local type name default desc
  while IFS='|' read -r type name default desc; do
    # Skip comments and empty lines
    [[ "$type" =~ ^#.*$ || -z "$type" ]] && continue

    # Only process flatpak entries
    [[ "$type" == "flatpak" ]] || continue

    # Skip if not enabled
    [[ "$default" == "TRUE" ]] || continue

    # Install flatpak
    install_flatpak_from_github "$name" "user" "$root"
  done <"$conf"

  return 0
}
