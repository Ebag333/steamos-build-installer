#!/bin/bash
#
# steamos-nvidia-installer — lib/builds/dlss_updater.sh
# DLSS Updater flatpak module.
# Downloads and installs the DLSS Updater flatpak from GitHub.
#
# Sourced by the build backend — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/builds/dlss_updater.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Source common build utilities if not already loaded
if [[ ! -v _BUILD_MODULES ]]; then
  SCRIPT_DIR_BUILDS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR_BUILDS/common.sh"
fi

# ---------------------------------------------------------------------------
# Build Configuration
# ---------------------------------------------------------------------------

DLSS_UPDATER_NAME="dlss-updater"
DLSS_UPDATER_DESC="DLSS Updater for NVIDIA GPUs"
DLSS_UPDATER_REPO="Recol/DLSS-Updater"
DLSS_UPDATER_APP_ID="io.github.recol.dlss-updater"

# Register this build
register_build "$DLSS_UPDATER_NAME" "$DLSS_UPDATER_DESC"

# ---------------------------------------------------------------------------
# State Management
# ---------------------------------------------------------------------------

# Get the stamp file path.
_get_dlss_stamp_file() {
  echo "/var/lib/steamos-nvidia/builds/dlss-updater/build.stamp"
}

# Read a value from the stamp file.
# Args: $1 = key
_dlss_stamp_value() {
  local key="$1"
  local stamp_file
  stamp_file="$(_get_dlss_stamp_file)"
  [[ -f "$stamp_file" ]] || return 0
  sed -n "s/^${key}=//p" "$stamp_file" | tail -n1
}

# Write the stamp file with current build info.
# Args: $1 = version, $2 = installed SHA
_write_dlss_stamp() {
  local version="$1"
  local installed_sha="$2"
  local stamp_file
  stamp_file="$(_get_dlss_stamp_file)"

  mkdir -p "$(dirname "$stamp_file")"
  cat >"$stamp_file" <<STAMP
driver=$DLSS_UPDATER_NAME
version=$version
installed_sha=$installed_sha
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STAMP
}

# Check if rebuild is needed.
# Args: $1 = version (optional)
# Returns 0 if rebuild needed, 1 if current
_dlss_needs_rebuild() {
  local version="${1:-}"

  # Check if flatpak is installed
  if flatpak info "$DLSS_UPDATER_APP_ID" >/dev/null 2>&1; then
    local installed_version
    installed_version="$(flatpak info --show-metadata "$DLSS_UPDATER_APP_ID" 2>/dev/null | grep -oP 'version=\K.*' || echo "")"

    if [[ -n "$version" && "$installed_version" == "$version" ]]; then
      return 1 # Current, no rebuild needed
    fi
  fi

  return 0 # Rebuild needed
}

# ---------------------------------------------------------------------------
# Flatpak Installation
# ---------------------------------------------------------------------------

# Get the latest release URL from GitHub.
# Output: URL on stdout
_get_dlss_release_url() {
  local url
  url="$(curl -fsSL "https://api.github.com/repos/$DLSS_UPDATER_REPO/releases/latest" 2>/dev/null \
    | grep -oE '"browser_download_url": *"[^"]+\.flatpak"' \
    | head -1 | cut -d'"' -f4)"

  if [[ -z "$url" ]]; then
    warn "  No flatpak release found for $DLSS_UPDATER_REPO"
    return 1
  fi

  echo "$url"
}

# Get the version from the release URL.
# Args: $1 = URL
# Output: version on stdout
_get_dlss_version_from_url() {
  local url="$1"
  # Extract version from filename (e.g., "DLSS.Updater-1.0.0.flatpak" -> "1.0.0")
  local filename="${url##*/}"
  echo "$filename" | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# Install DLSS Updater flatpak.
# Args: $1 = root path (optional, defaults to /)
# Returns 0 on success, 1 on failure
install_dlss_updater() {
  local root="${1:-/}"

  # Get latest release URL
  local url
  url="$(_get_dlss_release_url)" || return 1

  local file="${url##*/}"
  local tmp="/tmp/$file"

  # Get version
  local version
  version="$(_get_dlss_version_from_url "$url")"

  # Check if rebuild is needed
  if ! _dlss_needs_rebuild "$version"; then
    log "  DLSS Updater is current — skipping"
    return 0
  fi

  # Download
  log "  Downloading: $url"
  if ! download_with_retry "$url" "$tmp"; then
    return 1
  fi

  # Compute SHA
  local installed_sha
  installed_sha="$(sha256sum "$tmp" | awk '{print $1}')"

  # Live system: install directly
  if [[ "$root" == "/" ]]; then
    log "  Installing DLSS Updater flatpak"
    local install_output
    install_output="$(flatpak install --user -y "$tmp" 2>&1)"
    if [[ $? -ne 0 ]]; then
      warn "  Failed to install flatpak: $file"
      warn "  flatpak output: $install_output"
      rm -f "$tmp"
      return 1
    fi
    _write_dlss_stamp "$version" "$installed_sha"
    rm -f "$tmp"
    log "  DLSS Updater installed: $version"
    return 0
  fi

  # Build/rebuild: stage for first-boot installation
  log "  Build environment detected — staging Flatpak for first boot"
  local stage_dir="$root/usr/share/steamos-nvidia/flatpaks"
  mkdir -p "$stage_dir"
  cp "$tmp" "$stage_dir/dlss-updater.flatpak"

  # Install systemd user service for first-boot installation
  local service_dir="$root/etc/systemd/user"
  local wants_dir="$root/etc/systemd/user/default.target.wants"
  mkdir -p "$wants_dir"

  # Install service file
  if [[ -f "$SCRIPT_DIR/lib/configs/steamos-nvidia-flatpak-install.service" ]]; then
    cp "$SCRIPT_DIR/lib/configs/steamos-nvidia-flatpak-install.service" "$service_dir/"
  fi

  # Install installer script
  if [[ -f "$SCRIPT_DIR/lib/configs/install-staged-flatpaks.sh" ]]; then
    install -m 755 "$SCRIPT_DIR/lib/configs/install-staged-flatpaks.sh" "$root/usr/lib/steamos-nvidia/install-staged-flatpaks"
  fi

  # Enable service
  ln -sf /etc/systemd/user/steamos-nvidia-flatpak-install.service \
    "$wants_dir/steamos-nvidia-flatpak-install.service"

  _write_dlss_stamp "$version" "$installed_sha"
  rm -f "$tmp"
  log "  DLSS Updater $version staged successfully"
  return 0
}

# ---------------------------------------------------------------------------
# High-Level Interface
# ---------------------------------------------------------------------------

# Apply DLSS Updater (build-time).
# Args: $1 = root path (optional, defaults to $MNT)
# Returns 0 on success, 1 on failure
apply_dlss_updater_build() {
  local root="${1:-${MNT:-/}}"
  install_dlss_updater "$root"
}

# Apply DLSS Updater (rebuild/self-heal).
# Args: $1 = root path (optional, defaults to $NEWROOT)
# Returns 0 on success, 1 on failure
apply_dlss_updater_rebuild() {
  local root="${1:-${NEWROOT:-/}}"
  install_dlss_updater "$root"
}

# Apply DLSS Updater (live system).
# Args: $1 = root path (optional, defaults to /)
# Returns 0 on success, 1 on failure
apply_dlss_updater_live() {
  local root="${1:-/}"

  # Check if running as root
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    warn "Live installation requires root privileges"
    return 1
  fi

  install_dlss_updater "$root"
}
