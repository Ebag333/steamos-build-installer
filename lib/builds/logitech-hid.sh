#!/bin/bash
#
# steamos-nvidia-installer — lib/drivers/logitech-hid.sh
# Logitech HID++ driver module.
# Builds upstream Logitech receiver and HID++ kernel modules.
#
# Sourced by the build backend and repatch — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/drivers/logitech-hid.sh is a library — source it from the wrapper, not run directly." >&2
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

LOGITECH_HID_DRIVER_NAME="logitech-hid"
LOGITECH_HID_DRIVER_DESC="Logitech receiver and HID++ kernel modules"

# Source files to download
LOGITECH_HID_SOURCE_FILES=(
  "hid-logitech-dj.c"
  "hid-logitech-hidpp.c"
  "hid-ids.h"
)

# Built module names
LOGITECH_HID_MODULES="hid-logitech-dj hid-logitech-hidpp"

# Default upstream source URL base (can be overridden by version in config)
LOGITECH_HID_UPSTREAM_BASE="https://raw.githubusercontent.com/torvalds/linux/${UPSTREAM_DRIVER_REF:-master}/drivers/hid"

# State directory for tracking builds
LOGITECH_HID_STATE_DIR="/var/lib/steamos-nvidia/drivers/logitech-hid"

# Register this driver
register_build "$LOGITECH_HID_DRIVER_NAME" "$LOGITECH_HID_DRIVER_DESC"

# ---------------------------------------------------------------------------
# State Management
# ---------------------------------------------------------------------------

# Get the stamp file path.
_get_stamp_file() {
  echo "$LOGITECH_HID_STATE_DIR/build.stamp"
}

# Read a value from the stamp file.
# Args: $1 = key
_stamp_value() {
  local key="$1"
  local stamp_file
  stamp_file="$(_get_stamp_file)"
  [[ -f "$stamp_file" ]] || return 0
  sed -n "s/^${key}=//p" "$stamp_file" | tail -n1
}

# Write the stamp file with current build info.
# Args: $1 = source fingerprint, $2 = installed SHA
_write_stamp() {
  local fingerprint="$1"
  local installed_sha="$2"
  local stamp_file
  stamp_file="$(_get_stamp_file)"

  mkdir -p "$(dirname "$stamp_file")"
  cat >"$stamp_file" <<STAMP
driver=$LOGITECH_HID_DRIVER_NAME
fingerprint=$fingerprint
installed_sha=$installed_sha
kernel=$KVER
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STAMP
}

# Compute fingerprint for source + environment.
# Args: $1 = source directory
# Output: SHA256 hash
_compute_fingerprint() {
  local src_dir="$1"

  # Hash source files
  local source_hash=""
  local f
  for f in "${LOGITECH_HID_SOURCE_FILES[@]}"; do
    if [[ -f "$src_dir/$f" ]]; then
      source_hash+="$(sha256sum "$src_dir/$f" | awk '{print $1}')"
    fi
  done

  # Hash kernel version and config
  local kernel_hash=""
  local kconfig="$MERGED/usr/lib/modules/$KVER/build/.config"
  if [[ -f "$kconfig" ]]; then
    kernel_hash="$(sha256sum "$kconfig" | awk '{print $1}')"
  fi

  # Combine and hash
  printf '%s%s%s%s' "$source_hash" "$kernel_hash" "$KVER" "$LOGITECH_HID_UPSTREAM_BASE" \
    | sha256sum | awk '{print $1}'
}

# Check if rebuild is needed.
# Args: $1 = source directory, $2 = installed module path (optional)
# Returns 0 if rebuild needed, 1 if current
_needs_rebuild() {
  local src_dir="$1"
  local installed_path="${2:-}"

  local fingerprint
  fingerprint="$(_compute_fingerprint "$src_dir")"

  local old_fingerprint
  old_fingerprint="$(_stamp_value fingerprint)"

  local old_installed_sha
  old_installed_sha="$(_stamp_value installed_sha)"

  # Check fingerprint
  if [[ "$old_fingerprint" == "$fingerprint" ]]; then
    # Check installed SHA if path provided
    if [[ -n "$installed_path" && -f "$installed_path" ]]; then
      local current_sha
      current_sha="$(sha256sum "$installed_path" | awk '{print $1}')"
      if [[ "$current_sha" == "$old_installed_sha" ]]; then
        return 1 # Current, no rebuild needed
      fi
    else
      return 1 # Fingerprint matches, assume current
    fi
  fi

  return 0 # Rebuild needed
}

# ---------------------------------------------------------------------------
# Backup Management
# ---------------------------------------------------------------------------

# Backup existing driver before replacing.
# Args: $1 = driver path, $2 = backup directory
_backup_driver() {
  local driver_path="$1"
  local backup_dir="$2"

  if [[ ! -f "$driver_path" ]]; then
    return 0 # Nothing to backup
  fi

  local sha
  sha="$(sha256sum "$driver_path" | awk '{print $1}')"
  local backup_path="$backup_dir/$(basename "$driver_path").$sha"

  if [[ ! -e "$backup_path" ]]; then
    mkdir -p "$backup_dir"
    cp -a "$driver_path" "$backup_path"
    log "  Backed up existing driver to $backup_path"
  fi
}

# ---------------------------------------------------------------------------
# Source Fetching
# ---------------------------------------------------------------------------

# Fetch Logitech HID source files from upstream kernel.
# Args: $1 = destination directory, $2 = version/ref (optional, defaults to config or master)
# Returns 0 on success, 1 on failure
fetch_logitech_hid_sources() {
  local dest_dir="${1:?fetch_logitech_hid_sources: missing destination}"
  local version="${2:-$(get_build_item_version "logitech-hid")}"

  # Use version as git ref, default to master if "latest"
  local ref="$version"
  [[ "$ref" == "latest" ]] && ref="master"

  # Construct URL base with the specific ref
  local upstream_base="https://raw.githubusercontent.com/torvalds/linux/$ref/drivers/hid"

  log "Fetching Logitech HID sources from upstream kernel (ref: $ref)"

  # Clean and create destination
  rm -rf "$dest_dir"
  mkdir -p "$dest_dir"

  # Download source files
  local f target
  for f in "${LOGITECH_HID_SOURCE_FILES[@]}"; do
    target="$dest_dir/$f"
    mkdir -p "$(dirname "$target")"

    log "  Downloading: $f"
    if ! download_with_retry "$upstream_base/$f" "$target.part"; then
      return 1
    fi

    # Patch kernel API changes
    if [[ "$f" == *.c ]]; then
      _patch_hid_source "$target.part"
    fi

    mv "$target.part" "$target"
  done

  # Copy usbhid.h from kernel headers (matches ABI)
  local usbhid_src="$MERGED/usr/lib/modules/$KVER/build/drivers/hid/usbhid/usbhid.h"
  if [[ -f "$usbhid_src" ]]; then
    log "  Copying usbhid.h from kernel headers"
    mkdir -p "$dest_dir/usbhid"
    cp "$usbhid_src" "$dest_dir/usbhid/usbhid.h"
  else
    log "  WARNING: usbhid.h not found in headers — downloading upstream (ABI mismatch risk)"
    mkdir -p "$dest_dir/usbhid"
    if ! download_with_retry "$LOGITECH_HID_UPSTREAM_BASE/usbhid/usbhid.h" "$dest_dir/usbhid/usbhid.h"; then
      return 1
    fi
  fi

  # Create Makefile
  cat >"$dest_dir/Makefile" <<'EOF'
obj-m += hid-logitech-dj.o
obj-m += hid-logitech-hidpp.o
EOF

  # Verify patches
  if grep -REn '\bkzalloc_objs\?\(' "$dest_dir"; then
    warn "Unpatched kzalloc_obj/kzalloc_objs use remains in HID source"
    return 1
  fi
  if grep -qE 'sizeof\(consumer_report\), 5, 1' "$dest_dir"/hid-logitech-*.c; then
    warn "hid_report_raw_event still has 6-arg form (bufsize patch failed)"
    return 1
  fi

  log "Logitech HID sources fetched to $dest_dir"
  return 0
}

# Patch HID source for kernel API compatibility.
# Args: $1 = source file to patch
_patch_hid_source() {
  local file="${1:?_patch_hid_source: missing file}"

  # kzalloc_obj was renamed/added after 6.16; replace with kzalloc
  sed -i 's/kzalloc_obj(\*\([a-zA-Z_][a-zA-Z_0-9]*\))/kzalloc(sizeof(*\1), GFP_KERNEL)/g' "$file"
  sed -i 's/kzalloc_obj(struct \([a-zA-Z_][a-zA-Z_0-9]*\))/kzalloc(sizeof(struct \1), GFP_KERNEL)/g' "$file"

  # kzalloc_objs(type, count) → kcalloc(count, sizeof(type), GFP_KERNEL)
  sed -i 's/kzalloc_objs(\([a-zA-Z_][a-zA-Z_0-9]*\), \([a-zA-Z_][a-zA-Z_0-9]*\))/kcalloc(\2, sizeof(\1), GFP_KERNEL)/g' "$file"

  # hid_report_raw_event bufsize arg patch
  sed -i 's/consumer_report, sizeof(consumer_report), 5, 1);/consumer_report, 5, 1);/' "$file"
}

# ---------------------------------------------------------------------------
# Module Building
# ---------------------------------------------------------------------------

# Build Logitech HID modules.
# Args: $1 = source directory
# Returns 0 on success, 1 on failure
build_logitech_hid_modules() {
  local src_dir="${1:?build_logitech_hid_modules: missing source dir}"

  log "Building Logitech HID modules for $KVER"

  # Check kernel headers
  if ! check_kernel_headers "$MERGED" "$KVER"; then
    return 1
  fi

  # Verify stock drivers are modules (not built-in)
  local kconfig="$MERGED/usr/lib/modules/$KVER/build/.config"
  if [[ -f "$kconfig" ]]; then
    for mod in HID_LOGITECH_DJ HID_LOGITECH_HIDPP; do
      local val
      val="$(grep "^CONFIG_${mod}=" "$kconfig" 2>/dev/null | cut -d= -f2)"
      case "$val" in
        m) log "  CONFIG_${mod}=m (module — replaceable)" ;;
        y)
          warn "CONFIG_${mod}=y (built-in) — cannot replace"
          return 1
          ;;
        *) log "  CONFIG_${mod} not set (ok — no conflict)" ;;
      esac
    done
  else
    log "  WARNING: kernel .config not found — skipping built-in check"
  fi

  # Prepare build directory in WORKDIR, bind-mount into chroot
  local hid_build_host="${WORKDIR:?}/hid-kmod"
  local hid_build_chroot="/tmp/hid-kmod"
  rm -rf "$hid_build_host"
  mkdir -p "$hid_build_host"
  cp -a "$src_dir/." "$hid_build_host/"
  mkdir -p "$MERGED$hid_build_chroot"
  mount --bind "$hid_build_host" "$MERGED$hid_build_chroot" \
    || {
      warn "Failed to bind-mount hid-kmod build dir into chroot"
      return 1
    }

  # Build modules
  if ! build_kernel_modules "$MERGED" "$KVER" "$hid_build_chroot" "$hid_build_chroot"; then
    umount "$MERGED$hid_build_chroot" 2>/dev/null
    return 1
  fi

  # Verify built modules
  local mod
  for mod in $LOGITECH_HID_MODULES; do
    local ko="$hid_build_chroot/$mod.ko"
    [[ -s "$MERGED$ko" ]] || {
      umount "$MERGED$hid_build_chroot" 2>/dev/null
      warn "$mod.ko missing or empty after build"
      return 1
    }

    chroot "$MERGED" modinfo "$ko" >/dev/null 2>&1 \
      || {
        umount "$MERGED$hid_build_chroot" 2>/dev/null
        warn "$mod.ko is not a valid module"
        return 1
      }

    local vermagic
    vermagic="$(chroot "$MERGED" modinfo -F vermagic "$ko" 2>/dev/null | head -1)"
    [[ "$vermagic" == "$KVER "* ]] \
      || {
        umount "$MERGED$hid_build_chroot" 2>/dev/null
        warn "$mod.ko vermagic '$vermagic' does not match $KVER"
        return 1
      }
  done

  # Backup existing drivers before installing
  local mod
  for mod in $LOGITECH_HID_MODULES; do
    local existing_path
    existing_path="$(chroot "$MERGED" modinfo -k "$KVER" -n "$mod" 2>/dev/null || true)"
    if [[ -n "$existing_path" && "$existing_path" != *"(builtin)"* ]]; then
      _backup_driver "$MERGED$existing_path" "$LOGITECH_HID_STATE_DIR/backups"
    fi
  done

  # Install modules
  if ! install_kernel_modules "$MERGED" "$KVER" "$hid_build_chroot" "$LOGITECH_HID_MODULES" "logitech"; then
    umount "$MERGED$hid_build_chroot" 2>/dev/null
    return 1
  fi

  # Verify modern Logitech receiver alias
  chroot "$MERGED" modinfo -F alias "$hid_build_chroot/hid-logitech-dj.ko" \
    | grep -qi 'v0000046Dp0000C547' \
    || {
      umount "$MERGED$hid_build_chroot" 2>/dev/null
      warn "hid-logitech-dj module lacks the 046d:c547 alias"
      return 1
    }

  # Verify installed paths
  if ! verify_installed_modules "$MERGED" "$KVER" "$LOGITECH_HID_MODULES" "logitech"; then
    umount "$MERGED$hid_build_chroot" 2>/dev/null
    return 1
  fi

  # Compute installed SHA
  local installed_sha=""
  local first_module="hid-logitech-dj"
  local installed_path
  installed_path="$(chroot "$MERGED" modinfo -k "$KVER" -n "$first_module" 2>/dev/null)"
  if [[ -n "$installed_path" && -f "$MERGED$installed_path" ]]; then
    installed_sha="$(sha256sum "$MERGED$installed_path" | awk '{print $1}')"
  fi

  # Write stamp
  local fingerprint
  fingerprint="$(_compute_fingerprint "$src_dir")"
  _write_stamp "$fingerprint" "$installed_sha"

  # Clean up bind mount
  umount "$MERGED$hid_build_chroot" 2>/dev/null
  rm -rf "$hid_build_host"

  log "Logitech HID modules built and installed for $KVER"
  return 0
}

# ---------------------------------------------------------------------------
# High-Level Interface
# ---------------------------------------------------------------------------

# Apply Logitech HID driver (build-time).
# Args: $1 = work directory
# Returns 0 on success, 1 on failure
apply_logitech_hid_build() {
  local workdir="${1:?apply_logitech_hid_build: missing work directory}"

  local src_dir="$workdir/hid-src"

  # Get version from config
  local version
  version="$(get_build_item_version "logitech-hid")"

  # Check if rebuild is needed
  if ! _needs_rebuild "$src_dir"; then
    log "Logitech HID modules are current — skipping rebuild"
    return 0
  fi

  # Fetch sources with version from config
  if ! fetch_logitech_hid_sources "$src_dir" "$version"; then
    return 1
  fi

  # Build modules
  if ! build_logitech_hid_modules "$src_dir"; then
    return 1
  fi

  # Create bundle for self-heal
  local bundle_dir="$MNT/usr/lib/steamos-nvidia/hid"
  if ! create_driver_bundle "$src_dir" "$bundle_dir"; then
    warn "Failed to create HID source bundle for self-heal"
    return 1
  fi

  return 0
}

# Apply Logitech HID driver (rebuild/self-heal).
# Args: $1 = bundle directory
# Returns 0 on success, 1 on failure
apply_logitech_hid_rebuild() {
  local bundle_dir="${1:?apply_logitech_hid_rebuild: missing bundle directory}"

  log "Rebuilding Logitech HID modules from bundle"

  # Load sources from bundle into WORKDIR, bind-mount into chroot
  local hid_build_host="${WORKDIR:?}/hid-kmod"
  local hid_build_chroot="/tmp/hid-kmod"
  local src_dir="$hid_build_host"
  if ! load_driver_bundle "$bundle_dir" "$src_dir"; then
    return 1
  fi

  # Check if rebuild is needed
  if ! _needs_rebuild "$src_dir"; then
    log "Logitech HID modules are current — skipping rebuild"
    rm -rf "$src_dir"
    return 0
  fi

  # Bind-mount into chroot for build
  mkdir -p "$MERGED$hid_build_chroot"
  mount --bind "$hid_build_host" "$MERGED$hid_build_chroot" \
    || {
      warn "Failed to bind-mount hid-kmod build dir into chroot"
      rm -rf "$src_dir"
      return 1
    }

  # Build modules
  if ! build_logitech_hid_modules "$src_dir"; then
    umount "$MERGED$hid_build_chroot" 2>/dev/null
    rm -rf "$src_dir"
    return 1
  fi

  # Clean up
  umount "$MERGED$hid_build_chroot" 2>/dev/null
  rm -rf "$src_dir"

  return 0
}

# Apply Logitech HID driver (live system).
# Args: $1 = work directory (optional, defaults to /tmp)
# Returns 0 on success, 1 on failure
apply_logitech_hid_live() {
  local workdir="${1:-/tmp/logitech-hid-build}"

  log "Installing Logitech HID modules on live system"

  # Check if running as root
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    warn "Live installation requires root privileges"
    return 1
  fi

  # Check if rebuild is needed
  local installed_path
  installed_path="$(modinfo -k "$(uname -r)" -n hid-logitech-dj 2>/dev/null || true)"
  if [[ -n "$installed_path" && -f "$installed_path" ]]; then
    if ! _needs_rebuild "$workdir/src" "$installed_path"; then
      log "Logitech HID modules are current — skipping rebuild"
      return 0
    fi
  fi

  # Handle read-only filesystem (SteamOS)
  local reenable_readonly=0
  if command -v steamos-readonly >/dev/null 2>&1; then
    if ! touch /usr/.write-test 2>/dev/null; then
      log "  /usr is read-only; temporarily disabling SteamOS read-only mode"
      steamos-readonly disable
      reenable_readonly=1
    fi
    rm -f /usr/.write-test 2>/dev/null
  fi

  # Cleanup function
  _cleanup_live() {
    if ((reenable_readonly)); then
      log "  Restoring SteamOS read-only mode"
      steamos-readonly enable || warn "failed to re-enable read-only mode"
    fi
  }
  trap _cleanup_live EXIT

  # Fetch sources
  if ! fetch_logitech_hid_sources "$workdir/src"; then
    return 1
  fi

  # Build modules (use current kernel)
  local kver
  kver="$(uname -r)"

  # Check kernel headers
  if [[ ! -d "/usr/lib/modules/$kver/build" ]]; then
    warn "Kernel headers not found for $kver"
    return 1
  fi

  # Prepare build directory
  local build_dir="$workdir/build"
  rm -rf "$build_dir"
  mkdir -p "$build_dir"
  cp -a "$workdir/src/." "$build_dir/"

  # Build modules
  log "  Building modules for $kver"
  if ! make -C "/usr/lib/modules/$kver/build" M="$build_dir" clean 2>&1; then
    warn "Failed to clean build directory"
    return 1
  fi

  if ! make -C "/usr/lib/modules/$kver/build" M="$build_dir" modules 2>&1; then
    warn "Failed to build modules"
    return 1
  fi

  # Backup existing drivers
  local mod
  for mod in $LOGITECH_HID_MODULES; do
    local existing_path
    existing_path="$(modinfo -k "$kver" -n "$mod" 2>/dev/null || true)"
    if [[ -n "$existing_path" && -f "$existing_path" && "$existing_path" != *"(builtin)"* ]]; then
      _backup_driver "$existing_path" "$LOGITECH_HID_STATE_DIR/backups"
    fi
  done

  # Install modules
  local install_base="/usr/lib/modules/$kver/updates/logitech"
  mkdir -p "$install_base"

  for mod in $LOGITECH_HID_MODULES; do
    local ko="$build_dir/$mod.ko"
    local install_path="$install_base/$mod.ko"

    if ! install -Dm644 "$ko" "$install_path"; then
      warn "Failed to install $mod.ko"
      return 1
    fi
  done

  # Run depmod
  depmod "$kver"

  # Verify installation
  for mod in $LOGITECH_HID_MODULES; do
    local new_path
    new_path="$(modinfo -k "$kver" -n "$mod" 2>/dev/null)"
    if [[ "$new_path" != */updates/logitech/* ]]; then
      warn "$mod not installed to /updates/logitech/"
      return 1
    fi
  done

  # Compute installed SHA and write stamp
  local installed_sha=""
  local first_module="hid-logitech-dj"
  local final_path
  final_path="$(modinfo -k "$kver" -n "$first_module" 2>/dev/null)"
  if [[ -n "$final_path" && -f "$final_path" ]]; then
    installed_sha="$(sha256sum "$final_path" | awk '{print $1}')"
  fi

  local fingerprint
  fingerprint="$(_compute_fingerprint "$workdir/src")"
  _write_stamp "$fingerprint" "$installed_sha"

  # Clean up
  rm -rf "$workdir"

  log "Logitech HID modules installed on live system"
  return 0
}
