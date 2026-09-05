#!/bin/bash
#
# steamos-build-installer — lib/common_drivers.sh
# Driver helpers: kernel discovery, header resolution, payload computation/application.
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/common_drivers.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Build-only packages excluded from payload.
BUILD_ONLY_RE='^(dkms|nvidia-open-dkms|patch|gcc|make|binutils|libisl|libmpc|mpfr|pahole|python-setuptools|linux-neptune.*-headers|.*-headers|git|meson|ninja|pkgconf|autoconf|automake|bison|debugedit|fakeroot|flex|groff|m4|libtool|texinfo|base-devel|ffnvcodec-headers)$'

# Kernel cmdline additions for nvidia.
# shellcheck disable=SC2034
NVIDIA_CMDLINE_ADD='rd.driver.blacklist=nouveau modprobe.blacklist=nouveau nvidia-drm.modeset=1 nvidia-drm.fbdev=1'

# Debug kernel cmdline additions (verbose initramfs logging).
# shellcheck disable=SC2034
DEBUG_CMDLINE_ADD='rd.debug rd.log=all'

# Check if nvidia was selected for this build.
# Returns 0 if nvidia is selected, 1 if not.
# Checks HW_NVIDIA_REQUESTED (set by install_hw_libs) or falls back to
# checking if nvidia-utils is installed in the image.
nvidia_is_selected() {
  # Fast path: flag set by install_hw_libs
  if [[ "${HW_NVIDIA_REQUESTED:-0}" -eq 1 ]]; then
    return 0
  fi
  # Check HW_SUPPORT_ITEMS for nvidia packages (used by validator)
  if [[ -n "${HW_SUPPORT_ITEMS:-}" ]]; then
    if [[ " $HW_SUPPORT_ITEMS " == *" nvidia-open-dkms "* || " $HW_SUPPORT_ITEMS " == *" nvidia-utils "* ]]; then
      return 0
    fi
  fi
  # Fallback: check if nvidia-utils is in the image
  if [[ -n "${MNT:-}" ]] && pacman -Q --dbpath "$MNT/usr/lib/holo/pacmandb" nvidia-utils &>/dev/null; then
    return 0
  fi
  return 1
}

# Discover kernel package in a rootfs's pacman local db.
# Sets KPKG_DIR, KPKG_FULL, KPKG_NAME, KPKG_VERREL globals.
# Args: $1 = root path
discover_kernel_pkg() {
  local root="${1:?discover_kernel_pkg: missing root}"
  local dbpath="$root/usr/lib/holo/pacmandb"

  KPKG_NAME="$(
    pacman --dbpath "$dbpath" -Qq 2>/dev/null \
      | grep -E '^linux-neptune-[0-9]+$' \
      | head -n1
  )"

  [[ -n "$KPKG_NAME" ]] \
    || die "Kernel package not found in $root pacman db"

  KPKG_VERREL="$(
    pacman --dbpath "$dbpath" -Q "$KPKG_NAME" 2>/dev/null \
      | awk 'NR == 1 {print $2}'
  )"

  [[ -n "$KPKG_VERREL" ]] \
    || die "Could not determine version for kernel package $KPKG_NAME"

  KPKG_FULL="${KPKG_NAME}-${KPKG_VERREL}"
  KPKG_DIR="$dbpath/local/$KPKG_FULL"

  [[ -d "$KPKG_DIR" ]] \
    || die "Kernel package DB entry not found: $KPKG_DIR"
}

# Construct the headers URL for a kernel package.
# Sets HDR_URL global.  Call after discover_kernel_pkg().
# Args: $1 = root path
construct_hdr_url() {
  local root="${1:?construct_hdr_url: missing root}"

  local jupiter_repo mirror
  jupiter_repo="$(awk -F'[][]' '/^\[jupiter-/{print $2; exit}' "$root/etc/pacman.conf")"
  mirror="$(awk '/^Server/{print $3; exit}' "$root/etc/pacman.d/mirrorlist")"

  [[ -n "$jupiter_repo" ]] || die "construct_hdr_url: could not find jupiter repo in $root/etc/pacman.conf"
  [[ -n "$mirror" ]] || die "construct_hdr_url: could not find mirror in $root/etc/pacman.d/mirrorlist"

  HDR_URL="${mirror/\$repo/$jupiter_repo}"
  HDR_URL="${HDR_URL/\$arch/x86_64}/${KPKG_NAME}-headers-${KPKG_VERREL}-x86_64.pkg.tar.zst"
}

# Compute new/changed and removed runtime packages from before/after pacman
# snapshots.  Sets NEW_PKGS and REMOVED_PKGS arrays.
#
# NEW_PKGS intentionally compares full "name version" records so upgrades are
# copied into the payload.  REMOVED_PKGS compares package NAMES only: a version
# upgrade must not be mistaken for package removal, otherwise the freshly
# registered upgraded package would be deleted from the destination pacman DB.
#
# Args: $1 = before file, $2 = after file, $3 = extra exclude file (optional)
compute_new_pkgs() {
  local before="${1:?compute_new_pkgs: missing before file}"
  local after="${2:?compute_new_pkgs: missing after file}"
  local extra_exclude="${3:-}"

  # shellcheck disable=SC2034
  if [[ -n "$extra_exclude" && -f "$extra_exclude" ]]; then
    mapfile -t NEW_PKGS < <(
      env LC_ALL=C comm -13 "$before" "$after" \
        | awk '{print $1}' \
        | grep -Ev "$BUILD_ONLY_RE" \
        | awk -v excl="$extra_exclude" 'BEGIN{while((getline l < excl)>0) e[l]=1} !e[$0]'
    )
  else
    mapfile -t NEW_PKGS < <(
      env LC_ALL=C comm -13 "$before" "$after" \
        | awk '{print $1}' \
        | grep -Ev "$BUILD_ONLY_RE"
    )
  fi

  # shellcheck disable=SC2034
  mapfile -t REMOVED_PKGS < <(
    env LC_ALL=C comm -23 \
      <(awk '{print $1}' "$before" | env LC_ALL=C sort -u) \
      <(awk '{print $1}' "$after" | env LC_ALL=C sort -u)
  )
}

# Snapshot the overlay/chroot's installed package state in the stable format
# consumed by compute_new_pkgs().
# Args: $1 = output file
snapshot_driver_packages() {
  local output="${1:?snapshot_driver_packages: missing output file}"

  mkdir -p "$(dirname "$output")"
  in_chroot "pacman -Q" | env LC_ALL=C sort >"$output"
}

# Generate payload file list from packages.
# Args: $1 = output file, $2 = workdir (optional, defaults to $WORKDIR), remaining = package names
generate_payload_filelist() {
  local output="${1:?generate_payload_filelist: missing output file}"
  shift
  local workdir="${WORKDIR:-}"
  # If second arg is a directory, use it as workdir and shift
  if [[ $# -gt 0 && -d "$1" ]]; then
    workdir="$1"
    shift
  fi
  : >"$output"
  for pkg in "$@"; do in_chroot "pacman -Qlq $pkg" >>"$output"; done

  # Append custom payload files registered by build modules (e.g. AoTofu).
  local custom="$workdir/custom-payload-files.txt"
  if [[ -f "$custom" ]]; then
    # Validate each registered file exists in the target root
    local merged="${MERGED:-}"
    if [[ -n "$merged" ]]; then
      local path
      while IFS="" read -r path; do
        [[ -e "$merged$path" || -L "$merged$path" ]] \
          || die "Registered custom payload file is missing: $path"
      done <"$custom"
    fi
    cat "$custom" >>"$output"
  fi
}

# Register a custom payload file for inclusion in the image.
# Build modules call this for files not owned by any pacman package.
# Args: $1 = chroot-relative path (e.g. /usr/lib/dri/nvidia_drv_video.so)
register_custom_payload_file() {
  local path="${1:?register_custom_payload_file: missing path}"
  local custom="${WORKDIR:?WORKDIR not set}/custom-payload-files.txt"
  mkdir -p "$(dirname "$custom")"
  echo "$path" >>"$custom"
  sort -u -o "$custom" "$custom"
}

# Register payload packages in a target rootfs's pacman db.
# Args: $1 = target root, $2 = overlay upper, remaining = package names
register_payload_pkgs() {
  local dest_root="${1:?register_payload_pkgs: missing dest root}"
  local overlay_upper="${2:?register_payload_pkgs: missing overlay upper}"
  shift 2

  local db="$dest_root/usr/lib/holo/pacmandb/local"
  local pkg new_ver old_ver src

  mkdir -p "$db"

  for pkg in "$@"; do
    # Exact version installed in the overlay.
    new_ver="$(
      chroot "$MERGED" pacman -Q "$pkg" 2>/dev/null \
        | awk 'NR == 1 {print $2}'
    )"

    [[ -n "$new_ver" ]] \
      || die "Unable to determine overlay version for package: $pkg"

    src="$overlay_upper/usr/lib/holo/pacmandb/local/$pkg-$new_ver"

    [[ -d "$src" ]] \
      || die "Pacman DB entry not found in overlay upper: $pkg-$new_ver"

    # Remove exact previous version of this same package from destination.
    old_ver="$(
      pacman \
        --dbpath "$dest_root/usr/lib/holo/pacmandb" \
        -Q "$pkg" 2>/dev/null \
        | awk 'NR == 1 {print $2}'
    )" || true

    if [[ -n "$old_ver" ]]; then
      rm -rf -- "$db/$pkg-$old_ver"
    fi

    rsync -a -- "$src" "$db/"
  done
}

# remove_replaced_packages ROOT PKG...
#   Remove files and pacman DB entries for packages that were replaced during
#   the overlay transaction.  Files are queried from the overlay's pacman DB
#   (via in_chroot) before the entry is deleted.  Directories are skipped since
#   they are shared across packages.
remove_replaced_packages() {
  local root="${1:?remove_replaced_packages: missing root}"
  shift

  local dbpath="$root/usr/lib/holo/pacmandb"
  local pkg f ver

  for pkg in "$@"; do
    log "  Removing replaced package files: $pkg"

    # Query the OLD package while it is still registered in the destination.
    while IFS="" read -r f; do
      [[ -z "$f" || "$f" == */ ]] && continue
      rm -f -- "$root$f" 2>/dev/null || true
    done < <(
      pacman \
        --dbpath "$dbpath" \
        -Qlq "$pkg" 2>/dev/null
    )

    ver="$(
      pacman \
        --dbpath "$dbpath" \
        -Q "$pkg" 2>/dev/null \
        | awk 'NR == 1 {print $2}'
    )" || true

    if [[ -n "$ver" ]]; then
      rm -rf -- "$dbpath/local/$pkg-$ver"
    fi
  done
}

# Finalize and copy the driver/hardware payload from the overlay into a target
# rootfs.  The caller captures the BEFORE package snapshot immediately before
# making overlay changes; this function captures AFTER and owns the rest of the
# payload transaction.
#
# This deliberately copies /updates separately from package file lists because
# DKMS/custom kernel modules may be build artifacts rather than runtime package
# contents.
#
# Args:
#   $1 = destination rootfs
#   $2 = before package snapshot
#   $3 = workspace directory (optional; defaults to $WORKDIR)
#
# Requires globals: MERGED, UPPER, KVER
copy_driver_payload() {
  local dest_root="${1:?copy_driver_payload: missing destination root}"
  local before="${2:?copy_driver_payload: missing before snapshot}"
  local workdir="${3:-${WORKDIR:-}}"
  local merged="${MERGED:?copy_driver_payload: MERGED is not set}"
  local upper="${UPPER:?copy_driver_payload: UPPER is not set}"
  local kver="${KVER:?copy_driver_payload: KVER is not set}"

  [[ -n "$workdir" ]] \
    || die "copy_driver_payload: workspace directory is not set"
  [[ -f "$before" ]] \
    || die "copy_driver_payload: before snapshot not found: $before"
  [[ -d "$dest_root" ]] \
    || die "copy_driver_payload: destination root not found: $dest_root"

  local after="$workdir/driver-after.txt"
  local filelist="$workdir/driver-files.txt"
  local filelist_rel="$workdir/driver-files.rel"

  snapshot_driver_packages "$after"
  compute_new_pkgs "$before" "$after" "$workdir/build-only-exclusions.txt"

  if [[ ${#NEW_PKGS[@]} -eq 0 ]]; then
    log "No runtime package changes — module-only payload"
  else
    log "Payload packages: ${NEW_PKGS[*]}"
  fi

  if [[ ${#NEW_PKGS[@]} -gt 0 ]]; then
    generate_payload_filelist "$filelist" "$workdir" "${NEW_PKGS[@]}"
  else
    : >"$filelist"
  fi
  sed 's|^/||' "$filelist" >"$filelist_rel"

  log "Copying driver/hardware payload into target rootfs"

  if [[ -s "$filelist_rel" ]]; then
    rsync -a --force --files-from="$filelist_rel" "$merged/" "$dest_root/"
  fi

  # The pacman keyring is initialized in the overlay chroot but is not owned
  # by any package, so it is excluded from the payload filelist.  Copy it
  # explicitly — without it, pacman -S fails on the installed system.
  if [[ -d "$merged/etc/pacman.d/gnupg" ]]; then
    log "Copying pacman keyring into target rootfs"
    mkdir -p "$dest_root/etc/pacman.d"
    rsync -a "$merged/etc/pacman.d/gnupg/" "$dest_root/etc/pacman.d/gnupg/"
  fi

  # NVIDIA DKMS and custom-built modules are copied independently of package
  # payload filtering.  This also handles a module-only transaction.
  if [[ -d "$upper/usr/lib/modules/$kver/updates" ]]; then
    log "Copying kernel module updates"
    mkdir -p "$dest_root/usr/lib/modules/$kver"
    rsync -a \
      "$upper/usr/lib/modules/$kver/updates" \
      "$dest_root/usr/lib/modules/$kver/"
  fi

  if [[ ${#NEW_PKGS[@]} -gt 0 ]]; then
    log "Registering payload packages in target pacman database"
    register_payload_pkgs "$dest_root" "$upper" "${NEW_PKGS[@]}"
  fi

  # Remove files and DB entries for packages whose NAMES disappeared from the
  # overlay transaction (e.g. linux-firmware-neptune-jupiter replaced by
  # linux-firmware).  Without this, orphaned files from the old package linger.
  # Version upgrades are deliberately excluded by compute_new_pkgs().
  if [[ ${#REMOVED_PKGS[@]} -gt 0 ]]; then
    log "Removing replaced packages from target: ${REMOVED_PKGS[*]}"
    remove_replaced_packages "$dest_root" "${REMOVED_PKGS[@]}"
  fi

  log "Running depmod + ldconfig in target rootfs"
  run_depmod_ldconfig "$dest_root" "$kver"

  # common_modules.sh owns build-output verification.  All normal builder and
  # repatch callers source it before common_drivers.sh.
  if declare -F verify_built_modules >/dev/null 2>&1; then
    verify_built_modules "$dest_root" "$kver" die
  fi
}

install_kernel_headers() {
  log "Downloading exact-match kernel headers"
  in_chroot "curl -sfL '$HDR_URL' -o /tmp/headers.pkg.tar.zst"

  log "Installing exact-match kernel headers"
  pacman_install_local -- /tmp/headers.pkg.tar.zst
}

# Verify that a propagated package in the final image matches the overlay.
# Args: $1 = package name
# Uses globals: MERGED, MNT
verify_propagated_package() {
  local pkg="$1"
  local expected actual
  expected="$(chroot "$MERGED" pacman -Q "$pkg" 2>/dev/null)" || return 1
  actual="$(chroot "$MNT" pacman -Q "$pkg" 2>/dev/null)" || {
    die "Package missing from final image after propagation: $pkg"
  }
  if [[ "$actual" != "$expected" ]]; then
    die "Package state mismatch after propagation: $pkg
  overlay: $expected
  image:   $actual"
  fi
}

# rsync the payload into the real image rootfs and register its packages.
install_payload() {
  log "Copying driver payload into the image rootfs"
  # shellcheck disable=SC2034
  # shellcheck disable=SC2153 # FILELIST is set in lib/common.sh
  rsync -a --force --files-from="$FILELIST.rel" "$MERGED/" "$MNT/"

  # Copy kernel modules (including HID) from overlay to image
  if [[ -d "$UPPER/usr/lib/modules/$KVER/updates" ]]; then
    log "Copying kernel modules from overlay to image"
    mkdir -p "$MNT/usr/lib/modules/$KVER"
    rsync -a "$UPPER/usr/lib/modules/$KVER/updates" "$MNT/usr/lib/modules/$KVER/"
  fi

  # Copy pacman keyring — not owned by any package, so excluded from filelist.
  if [[ -d "$MERGED/etc/pacman.d/gnupg" ]]; then
    log "Copying pacman keyring into image rootfs"
    mkdir -p "$MNT/etc/pacman.d"
    rsync -a "$MERGED/etc/pacman.d/gnupg/" "$MNT/etc/pacman.d/gnupg/"
  fi

  # Verify HID modules landed in the image (only if logitech-hid was selected).
  if declare -F verify_built_modules >/dev/null 2>&1; then
    verify_built_modules "$MNT" "$KVER" die
  fi

  if [[ ${#NEW_PKGS[@]} -gt 0 ]]; then
    log "Registering payload packages in the image's pacman db"
    register_payload_pkgs "$MNT" "$UPPER" "${NEW_PKGS[@]}"
  fi

  # Remove files and DB entries for packages that were replaced/removed in the
  # overlay transaction (e.g. linux-firmware-neptune-jupiter replaced by
  # linux-firmware).  Without this, orphaned files from the old package linger.
  if [[ ${#REMOVED_PKGS[@]} -gt 0 ]]; then
    log "Removing replaced packages from image: ${REMOVED_PKGS[*]}"
    remove_replaced_packages "$MNT" "${REMOVED_PKGS[@]}"
  fi

  log "Running depmod + ldconfig in the image"
  run_depmod_ldconfig "$MNT" "$KVER"

  # Only install nvidia modprobe config if nvidia packages are present
  if [[ -d "$MNT/usr/share/nvidia" ]] || [[ -f "$MNT/usr/bin/nvidia-smi" ]]; then
    log "Writing modprobe config (blacklist nouveau, enable nvidia KMS)"
    mkdir -p "$MERGED/etc/modprobe.d"
    cp "$SCRIPT_DIR/lib/configs/99-nvidia-patch.conf" "$MERGED/etc/modprobe.d/99-nvidia-patch.conf"
    mkdir -p "$MNT/etc/modprobe.d"
    cp "$SCRIPT_DIR/lib/configs/99-nvidia-patch.conf" "$MNT/etc/modprobe.d/99-nvidia-patch.conf"
  else
    log "Skipping nvidia modprobe config (nvidia not installed)"
  fi

  log "Restoring module autoloading in initramfs"
  mount_chroot_fs "$MNT"

  # Only reconfigure initramfs if the user explicitly opted in.
  #   INITRAMFS_MODULES unset   → stock: leave initramfs alone
  #   INITRAMFS_MODULES="a b c" → custom: regenerate with user-selected modules
  if [[ -n "${INITRAMFS_MODULES+x}" && -n "${INITRAMFS_MODULES:-}" ]]; then
    log "  Custom initramfs modules: $INITRAMFS_MODULES"
    mount_effective_etc "$MNT"
    apply_initramfs "$MNT" "$KVER" "$INITRAMFS_MODULES"
    unmount_effective_etc "$MNT"
  else
    log "  Stock initramfs — not reconfiguring (use --initramfs to customize)"
  fi

  umount_chroot_fs "$MNT" strict

  if nvidia_is_selected; then
    enable_nvidia_power_services "$MNT"
  else
    log "Skipping nvidia power services (nvidia not selected)"
  fi

  # Bundle scan-hardware.sh for manual use.
  log "Installing hardware scan tool"
  mkdir -p "$MERGED/usr/local/bin/diagnostics"
  cp "$SCRIPT_DIR/lib/scan-hardware.sh" "$MERGED/usr/local/bin/diagnostics/scan-hardware"
  chmod +x "$MERGED/usr/local/bin/diagnostics/scan-hardware"
  mkdir -p "$MNT/usr/local/bin/diagnostics"
  cp "$SCRIPT_DIR/lib/scan-hardware.sh" "$MNT/usr/local/bin/diagnostics/scan-hardware"
  chmod +x "$MNT/usr/local/bin/diagnostics/scan-hardware"

  # Run user-provided custom script if present (fail open).
  # Uses "/" (live system) — the custom script lives on /home, not inside the image.
  run_custom_script "/"
}

# Configure the OS update channel (variant + branch) and optionally suppress
# the OOBE first-boot flow.  Delegates to system-config.sh for all writes.
#
# Uses globals: TARGET_VARIANT, UPDATE_BRANCH, MNT
configure_update_channel() {
  local variant="${TARGET_VARIANT:-steamdeck}"
  local branch="${UPDATE_BRANCH:-stable}"

  log "Configuring update channel: variant=$variant branch=$branch"

  apply_system_config variant "$MNT" "$variant"
  apply_system_config update-branch "$MNT" "$branch"

  log "Verifying update channel configuration"
  verify_system_config variant "$MNT" "$variant"
  verify_system_config update-branch "$MNT" "$branch"

  log "Update channel configured and verified"
}

# Copy built kernel modules from the build overlay to the target image.
# This is the new "copy back" mechanism that only copies built artifacts,
# not the entire pacman transaction.
#
# Args: none (uses globals: $MERGED, $MNT, $KVER, $BUILT_MODULE_FILES)
# ---------------------------------------------------------------------------
copy_built_modules_to_image() {
  local workdir="${WORKDIR:?copy_built_modules_to_image: WORKDIR is not set}"
  [[ -n "${MERGED:-}" ]] || die "copy_built_modules_to_image: MERGED is not set"
  [[ -n "${MNT:-}" ]] || die "copy_built_modules_to_image: MNT is not set"
  [[ -n "${KVER:-}" ]] || die "copy_built_modules_to_image: KVER is not set"

  # Check if there are any modules to copy
  local has_modules=0
  if [[ -d "$MERGED/usr/lib/modules/$KVER/updates" ]]; then
    has_modules=1
  fi
  if [[ -d "$workdir/packages" ]] && compgen -G "$workdir/packages/*.pkg.tar.*" >/dev/null; then
    has_modules=1
  fi

  if [[ "$has_modules" -eq 0 ]]; then
    log "No built modules — skipping module installation"
    return 0
  fi

  log "Copying built modules from build overlay to image"

  # Copy kernel modules from overlay to image
  if [[ -d "$MERGED/usr/lib/modules/$KVER/updates" ]]; then
    log "  Copying kernel module updates"
    mkdir -p "$MNT/usr/lib/modules/$KVER"
    rsync -a "$MERGED/usr/lib/modules/$KVER/updates" "$MNT/usr/lib/modules/$KVER/"
  fi

  # Copy any custom-built packages (from build recipes)
  if [[ -d "$workdir/packages" ]]; then
    local pkg
    for pkg in "$workdir/packages"/*.pkg.tar.*; do
      [[ -f "$pkg" ]] || continue
      log "  Installing built package: $(basename "$pkg")"
      install_build_artifact "$MNT" "$pkg"
    done
  fi

  # Run depmod to update module dependencies (fatal if modules were installed)
  log "  Running depmod"
  if ! chroot "$MNT" depmod "$KVER" 2>/dev/null; then
    die "depmod failed — module dependencies not generated for $KVER"
  fi

  log "Built modules copied to image"
}
