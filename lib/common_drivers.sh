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

# Discover kernel package in a rootfs's pacman local db.
# Sets KPKG_DIR, KPKG_FULL, KPKG_NAME, KPKG_VERREL globals.
# Args: $1 = root path
discover_kernel_pkg() {
  local root="${1:?discover_kernel_pkg: missing root}"
  PACDB="$root/usr/lib/holo/pacmandb/local"

  KPKG_DIR=""
  for d in "$PACDB"/linux-neptune-*-[0-9]*; do
    [[ -d "$d" ]] || continue
    case "$(basename "$d")" in *-headers-* | *firmware* | *rtw*) continue ;; esac
    KPKG_DIR="$d"
    break
  done
  [[ -n "$KPKG_DIR" ]] || die "Kernel package not found in $root pacman db"

  KPKG_FULL="$(basename "$KPKG_DIR")"
  KPKG_NAME="${KPKG_FULL%-*-*}"
  KPKG_VERREL="${KPKG_FULL#"$KPKG_NAME"-}"
}

# Construct the headers URL for a kernel package.
# Sets HDR_URL global.  Call after discover_kernel_pkg().
# Args: $1 = root path
construct_hdr_url() {
  local root="${1:?construct_hdr_url: missing root}"

  local jupiter_repo mirror
  jupiter_repo="$(awk -F'[][]' '/^\[jupiter-/{print $2; exit}' "$root/etc/pacman.conf")"
  mirror="$(awk '/^Server/{print $3; exit}' "$root/etc/pacman.d/mirrorlist")"

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
        | grep -vxFf "$extra_exclude"
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

  for pkg in "$@"; do
    rm -rf "$dest_root/usr/lib/holo/pacmandb/local/$pkg"-[0-9]*
    for entry in "$overlay_upper/usr/lib/holo/pacmandb/local/$pkg"-[0-9]*; do
      [[ -d "$entry" ]] && rsync -a "$entry" "$dest_root/usr/lib/holo/pacmandb/local/" && break
    done
  done
}

# remove_replaced_packages ROOT PKG...
#   Remove files and pacman DB entries for packages that were replaced during
#   the overlay transaction.  Files are queried from the overlay's pacman DB
#   (via in_chroot) before the entry is deleted.  Directories are skipped since
#   they are shared across packages.
remove_replaced_packages() {
  local root="$1"
  shift
  local pkg f

  for pkg in "$@"; do
    log "  Removing replaced package files: $pkg"
    while IFS="" read -r f; do
      [[ "$f" == */ ]] && continue
      rm -f "$root$f" 2>/dev/null || true
    done < <(in_chroot "pacman -Qlq $pkg" 2>/dev/null)
    rm -rf "$root/usr/lib/holo/pacmandb/local/$pkg"-[0-9]* 2>/dev/null || true
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

  generate_payload_filelist "$filelist" "$workdir" "${NEW_PKGS[@]}"
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
  in_chroot \
    "pacman --config '$PACCONF' -U $PACOPTS /tmp/headers.pkg.tar.zst"
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

  log "Registering payload packages in the image's pacman db"
  register_payload_pkgs "$MNT" "$UPPER" "${NEW_PKGS[@]}"

  # Remove files and DB entries for packages that were replaced/removed in the
  # overlay transaction (e.g. linux-firmware-neptune-jupiter replaced by
  # linux-firmware).  Without this, orphaned files from the old package linger.
  if [[ ${#REMOVED_PKGS[@]} -gt 0 ]]; then
    log "Removing replaced packages from image: ${REMOVED_PKGS[*]}"
    remove_replaced_packages "$MNT" "${REMOVED_PKGS[@]}"
  fi

  log "Running depmod + ldconfig in the image"
  run_depmod_ldconfig "$MNT" "$KVER"

  log "Writing modprobe config (blacklist nouveau, enable nvidia KMS)"
  mkdir -p "$MERGED/etc/modprobe.d"
  cp "$SCRIPT_DIR/lib/configs/99-nvidia-patch.conf" "$MERGED/etc/modprobe.d/99-nvidia-patch.conf"
  mkdir -p "$MNT/etc/modprobe.d"
  cp "$SCRIPT_DIR/lib/configs/99-nvidia-patch.conf" "$MNT/etc/modprobe.d/99-nvidia-patch.conf"

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

  enable_nvidia_power_services "$MNT"

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
