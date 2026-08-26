#!/bin/bash
#
# steamos-nvidia-installer — lib/common_drivers.sh
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
      LC_ALL=C comm -13 "$before" "$after" \
        | awk '{print $1}' \
        | grep -Ev "$BUILD_ONLY_RE" \
        | grep -vxFf "$extra_exclude"
    )
  else
    mapfile -t NEW_PKGS < <(
      LC_ALL=C comm -13 "$before" "$after" \
        | awk '{print $1}' \
        | grep -Ev "$BUILD_ONLY_RE"
    )
  fi

  # shellcheck disable=SC2034
  mapfile -t REMOVED_PKGS < <(
    LC_ALL=C comm -23 \
      <(awk '{print $1}' "$before" | LC_ALL=C sort -u) \
      <(awk '{print $1}' "$after" | LC_ALL=C sort -u)
  )
}

# Snapshot the overlay/chroot's installed package state in the stable format
# consumed by compute_new_pkgs().
# Args: $1 = output file
snapshot_driver_packages() {
  local output="${1:?snapshot_driver_packages: missing output file}"

  mkdir -p "$(dirname "$output")"
  in_chroot "pacman -Q" | LC_ALL=C sort >"$output"
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
      while IFS= read -r path; do
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
    while IFS= read -r f; do
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
  rsync -a --force --files-from="$FILELIST.rel" "$MERGED/" "$MNT/"

  # Copy kernel modules (including HID) from overlay to image
  log "Copying kernel modules from overlay to image"
  rsync -a "$UPPER/usr/lib/modules/$KVER/updates" "$MNT/usr/lib/modules/$KVER/"

  # Copy pacman keyring — not owned by any package, so excluded from filelist.
  if [[ -d "$MERGED/etc/pacman.d/gnupg" ]]; then
    log "Copying pacman keyring into image rootfs"
    mkdir -p "$MNT/etc/pacman.d"
    rsync -a "$MERGED/etc/pacman.d/gnupg/" "$MNT/etc/pacman.d/gnupg/"
  fi

  # Verify HID modules landed in the image (only if logitech-hid was selected).
  verify_built_modules "$MNT" "$KVER" die

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

  # Bundle post-install.sh for manual configuration.
  log "Installing post-install configuration script"
  cp "$SCRIPT_DIR/lib/post-install.sh" "$MERGED/usr/local/bin/steamos-nvidia-post-install"
  chmod +x "$MERGED/usr/local/bin/steamos-nvidia-post-install"
  cp "$SCRIPT_DIR/lib/post-install.sh" "$MNT/usr/local/bin/steamos-nvidia-post-install"
  chmod +x "$MNT/usr/local/bin/steamos-nvidia-post-install"

  # Desktop shortcut — /home is a separate SteamOS partition mounted at
  # $HOMEMNT during image construction.  Do not write this under $MNT/home
  # or $MERGED/home: those paths are hidden as soon as the real /home mounts
  # at boot and the shortcut would disappear.
  log "Installing NVIDIA Setup desktop shortcut on the real home partition"
  local desktop_file="$HOMEMNT/deck/Desktop/NVIDIA Setup.desktop"
  mkdir -p "$HOMEMNT/deck/Desktop"
  install -m 755 "$SCRIPT_DIR/lib/configs/NVIDIA Setup.desktop" "$desktop_file"
  chown 1000:1000 "$desktop_file"

  # Run user-provided custom script if present (fail open).
  local _custom="/home/.steamos-nvidia/recovery/custom.sh"
  if [[ -x "$_custom" ]]; then
    log "Running custom script: $_custom"
    if bash "$_custom" 2>&1; then
      log "Custom script completed successfully"
    else
      warn "Custom script exited with non-zero status (non-fatal)"
    fi
  else
    log "No custom script at $_custom — skipping"
  fi
}

fetch_hid_sources() {
  # Default to Linux master for the latest device IDs.  Use parameter
  # defaults so UPSTREAM_DRIVER_SRC_BASE always tracks the ref, even if the
  # wrapper set UPSTREAM_DRIVER_REF without also setting the base URL.
  : "${UPSTREAM_DRIVER_REF:=master}"
  : "${UPSTREAM_DRIVER_SRC_BASE:=https://raw.githubusercontent.com/torvalds/linux/$UPSTREAM_DRIVER_REF/drivers/hid}"
  log "HID source ref: $UPSTREAM_DRIVER_REF"

  # Re-download every run so we always get the correct version.
  DRIVER_SRC_DIR="$WORKDIR/hid-src"
  rm -rf "$DRIVER_SRC_DIR"
  mkdir -p "$DRIVER_SRC_DIR"

  local HID_DRIVER_FILES=(
    "hid-logitech-dj.c"
    "hid-logitech-hidpp.c"
    "hid-ids.h"
  )

  local f target
  for f in "${HID_DRIVER_FILES[@]}"; do
    target="$DRIVER_SRC_DIR/$f"
    mkdir -p "$(dirname "$target")"

    log "Downloading upstream HID source: $f"
    curl_retry 3 -sfL \
      "$UPSTREAM_DRIVER_SRC_BASE/$f" \
      -o "$target.part" \
      || die "download failed: $UPSTREAM_DRIVER_SRC_BASE/$f"

    # Patch kernel API changes between master and the image's headers.
    if [[ "$f" == *.c ]]; then
      # kzalloc_obj was renamed/added after 6.16; replace with kzalloc.
      sed -i 's/kzalloc_obj(\*\([a-zA-Z_][a-zA-Z_0-9]*\))/kzalloc(sizeof(*\1), GFP_KERNEL)/g' "$target.part"
      sed -i 's/kzalloc_obj(struct \([a-zA-Z_][a-zA-Z_0-9]*\))/kzalloc(sizeof(struct \1), GFP_KERNEL)/g' "$target.part"
      # kzalloc_objs(type, count) → kcalloc(count, sizeof(type), GFP_KERNEL)
      sed -i 's/kzalloc_objs(\([a-zA-Z_][a-zA-Z_0-9]*\), \([a-zA-Z_][a-zA-Z_0-9]*\))/kcalloc(\2, sizeof(\1), GFP_KERNEL)/g' "$target.part"
      # hid_report_raw_event gained a 6th arg (bufsize) after 6.16; the
      # new call is:
      #   hid_report_raw_event(hid, type, data, bufsize, size, interrupt)
      # old 6.16 call was:
      #   hid_report_raw_event(hid, type, data, size, interrupt)
      # Strip the bufsize arg (sizeof(consumer_report)) so the call
      # matches the 6.16 signature the image's headers expect.
      sed -i \
        's/consumer_report, sizeof(consumer_report), 5, 1);/consumer_report, 5, 1);/' \
        "$target.part"
    fi

    mv "$target.part" "$target"
  done

  # usbhid.h is an internal kernel header — use the image's own copy
  # (matches the kernel ABI) rather than downloading master's version.
  local usbhid_src="$MERGED/usr/lib/modules/$KVER/build/drivers/hid/usbhid/usbhid.h"
  if [[ -f "$usbhid_src" ]]; then
    log "Copying usbhid.h from image kernel headers"
    mkdir -p "$DRIVER_SRC_DIR/usbhid"
    cp "$usbhid_src" "$DRIVER_SRC_DIR/usbhid/usbhid.h"
  else
    log "WARNING: usbhid.h not found in image headers — downloading master (ABI mismatch risk)"
    mkdir -p "$DRIVER_SRC_DIR/usbhid"
    curl_retry 3 -sfL "$UPSTREAM_DRIVER_SRC_BASE/usbhid/usbhid.h" \
      -o "$DRIVER_SRC_DIR/usbhid/usbhid.h" \
      || die "download failed: usbhid/usbhid.h"
  fi

  cat >"$DRIVER_SRC_DIR/Makefile" <<'EOF'
obj-m += hid-logitech-dj.o
obj-m += hid-logitech-hidpp.o
EOF

  # Verify compatibility patches actually removed the incompatible APIs.
  if grep -REn '\bkzalloc_objs\?\(' "$DRIVER_SRC_DIR"; then
    die "Unpatched kzalloc_obj/kzalloc_objs use remains in HID source"
  fi
  if grep -qE 'sizeof\(consumer_report\), 5, 1' "$DRIVER_SRC_DIR"/hid-logitech-*.c; then
    die "hid_report_raw_event still has 6-arg form (bufsize patch failed)"
  fi

  log "Upstream HID sources fetched to $DRIVER_SRC_DIR"
}

build_hid() {
  log "Building upstream Logitech receiver and HID++ modules for $KVER"

  [[ -d "$DRIVER_SRC_DIR" ]] || die "HID source directory not found — fetch_hid_sources must run first"

  # Verify the stock Logitech drivers are built as modules (=m), not
  # built-in (=y).  A built-in driver can't be replaced by a .ko in
  # /updates — the kernel will always load the built-in version.
  local kconfig="$MERGED/usr/lib/modules/$KVER/build/.config"
  if [[ -f "$kconfig" ]]; then
    for mod in HID_LOGITECH_DJ HID_LOGITECH_HIDPP; do
      local val
      val="$(grep "^CONFIG_${mod}=" "$kconfig" 2>/dev/null | cut -d= -f2)"
      case "$val" in
        m) log "  CONFIG_${mod}=m (module — replaceable)" ;;
        y) die "CONFIG_${mod}=y (built-in) — our .ko cannot replace the built-in driver" ;;
        *) log "  CONFIG_${mod} not set (ok — no conflict)" ;;
      esac
    done
  else
    log "WARNING: kernel .config not found at $kconfig — skipping built-in check"
  fi

  # Use WORKDIR for build artifacts, bind-mount into chroot
  local hid_build_host="${WORKDIR:?}/hid-kmod"
  local hid_build_chroot="/tmp/hid-kmod"
  rm -rf "$hid_build_host"
  mkdir -p "$hid_build_host"
  cp -a "$DRIVER_SRC_DIR/." "$hid_build_host/"
  mkdir -p "$MERGED$hid_build_chroot"
  mount --bind "$hid_build_host" "$MERGED$hid_build_chroot" \
    || die "Failed to bind-mount hid-kmod build dir into chroot"

  in_chroot \
    "make -C /usr/lib/modules/$KVER/build M=$hid_build_chroot clean"

  in_chroot \
    "make -C /usr/lib/modules/$KVER/build M=$hid_build_chroot modules"

  # Post-build verification: each module must exist, be valid, and have
  # vermagic matching the target kernel.
  for mod in hid-logitech-dj hid-logitech-hidpp; do
    local ko="$hid_build_chroot/$mod.ko"
    [[ -s "$MERGED$ko" ]] || {
      umount "$MERGED$hid_build_chroot" 2>/dev/null
      die "$mod.ko missing or empty after build"
    }

    in_chroot "modinfo '$ko'" >/dev/null 2>&1 \
      || {
        umount "$MERGED$hid_build_chroot" 2>/dev/null
        die "$mod.ko is not a valid module"
      }

    local vermagic
    vermagic="$(in_chroot "modinfo -F vermagic '$ko'" 2>/dev/null | head -1)"
    [[ "$vermagic" == "$KVER "* ]] \
      || {
        umount "$MERGED$hid_build_chroot" 2>/dev/null
        die "$mod.ko vermagic '$vermagic' does not match $KVER"
      }
  done

  in_chroot \
    "install -Dm644 \
      $hid_build_chroot/hid-logitech-dj.ko \
      /usr/lib/modules/$KVER/updates/logitech/hid-logitech-dj.ko"

  in_chroot \
    "install -Dm644 \
      $hid_build_chroot/hid-logitech-hidpp.ko \
      /usr/lib/modules/$KVER/updates/logitech/hid-logitech-hidpp.ko"

  # Run depmod so the overlay's module database recognizes /updates/logitech/
  # as higher priority than the stock kernel module in the lower layer.
  in_chroot "depmod $KVER"

  # Verify the built module has the modern Logitech receiver alias.
  in_chroot \
    "modinfo -F alias $hid_build_chroot/hid-logitech-dj.ko \
      | grep -qi 'v0000046Dp0000C547'" \
    || {
      umount "$MERGED$hid_build_chroot" 2>/dev/null
      die "upstream hid-logitech-dj module lacks the 046d:c547 alias"
    }

  # Verify the installed module path — what the image will actually load
  # after depmod — points to our /updates replacement, not the stock driver.
  for mod in hid-logitech-dj hid-logitech-hidpp; do
    local installed_path
    installed_path="$(in_chroot "modinfo -k $KVER -n $mod" 2>/dev/null)"
    [[ "$installed_path" == */updates/logitech/* ]] \
      || {
        umount "$MERGED$hid_build_chroot" 2>/dev/null
        die "$mod resolves to $installed_path — not our replacement in /updates/logitech/"
      }
  done

  # Clean up bind mount
  umount "$MERGED$hid_build_chroot" 2>/dev/null
  rm -rf "$hid_build_host"

  log "Built upstream Logitech HID modules for $KVER"
}

# Configure the OS update channel (variant + branch) and optionally suppress
# the OOBE first-boot flow.  Writes config files directly (offline-safe)
# rather than calling atomupd-manager, which requires a live D-Bus session.
#
# Uses globals: TARGET_VARIANT, UPDATE_BRANCH, MNT
configure_update_channel() {
  local variant="${TARGET_VARIANT:-steamdeck}"
  local branch="${UPDATE_BRANCH:-stable}"
  local suppress_oobe=0

  [[ "$variant" == "steamdeck" ]] && suppress_oobe=1

  log "Configuring update channel: variant=$variant branch=$branch (suppress_oobe=$suppress_oobe)"

  # ── 1) Write atomupd preferences.conf (offline — no D-Bus needed) ────────
  _apply_update_branch "$MNT" "$branch" "$variant"

  if ((suppress_oobe)); then
    # ── 2) Neutralize the destructive OOBE Steam reset in steam-jupiter ────
    apply_optimization_for_item "neutralize-oobe" "chroot" "$MNT" \
      || die "failed to neutralize destructive OOBE Steam reset in steam-jupiter"
  fi

  # ── 3) Stamp variant in manifest.json (canonical path, not symlink) ──────
  # /etc/steamos-atomupd/manifest.json may symlink into /usr/lib; resolve
  # inside the target root namespace so relative symlinks don't escape.
  local manifest_target manifest
  manifest_target="$(chroot "$MNT" readlink -f /usr/lib/steamos-atomupd/manifest.json 2>/dev/null)" \
    || manifest_target="/usr/lib/steamos-atomupd/manifest.json"
  manifest="$MNT$manifest_target"
  if [[ -f "$manifest" ]]; then
    log "  Setting variant=$variant in $manifest_target"
    sed -i "s/\"variant\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"variant\": \"$variant\"/" "$manifest"
  else
    die "manifest.json not found at $manifest_target"
  fi

  # ── 4) Stamp VARIANT_ID in os-release (canonical path, not symlink) ──────
  local osrelease_target os_release
  osrelease_target="$(chroot "$MNT" readlink -f /etc/os-release 2>/dev/null)" \
    || osrelease_target="/etc/os-release"
  os_release="$MNT$osrelease_target"
  if [[ -f "$os_release" ]]; then
    log "  Setting VARIANT_ID=$variant in $osrelease_target"
    if grep -q "^VARIANT_ID=" "$os_release"; then
      sed -i "s/^VARIANT_ID=.*/VARIANT_ID=$variant/" "$os_release"
    else
      echo "VARIANT_ID=$variant" >>"$os_release"
    fi
  else
    die "/etc/os-release not found at $osrelease_target"
  fi

  # ── 5) Verify final state ────────────────────────────────────────────────
  log "Verifying update channel configuration"
  local verify_failed=0
  local prefs="$MNT/etc/steamos-atomupd/preferences.conf"

  # preferences.conf — variant
  if ! grep -q "^Variant=$variant$" "$prefs"; then
    warn "  VERIFY FAILED: preferences.conf Variant != $variant"
    verify_failed=1
  else
    log "  OK preferences.conf Variant=$variant"
  fi

  # preferences.conf — branch (delegate to system-config verify)
  if ! _verify_update_branch "$MNT" "$branch"; then
    warn "  VERIFY FAILED: preferences.conf Branch != $branch"
    verify_failed=1
  else
    log "  OK preferences.conf Branch=$branch"
  fi

  # manifest.json
  if ! grep -q "\"variant\"[[:space:]]*:[[:space:]]*\"$variant\"" "$manifest"; then
    warn "  VERIFY FAILED: manifest.json variant != $variant"
    verify_failed=1
  else
    log "  OK manifest.json variant=$variant"
  fi

  # os-release
  if ! grep -q "^VARIANT_ID=$variant$" "$os_release"; then
    warn "  VERIFY FAILED: os-release VARIANT_ID != $variant"
    verify_failed=1
  else
    log "  OK os-release VARIANT_ID=$variant"
  fi

  if ((verify_failed)); then
    die "Update channel verification failed — build aborted"
  fi

  log "Update channel configured and verified"
}
