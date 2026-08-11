#!/bin/bash
#
# steamos-nvidia-installer.sh — turn a CLEAN SteamOS OOBE repair image into a
# one-click USB installer with NVIDIA (RTX) driver support baked in.
#
# Installs the CURRENT Arch Linux nvidia-open driver by default (Valve's own
# mirror only pins an older 575.x) — or any branch you name with --driver.
# The version is resolved once at build time, pinned to
# permanent archive.archlinux.org URLs, and the on-device self-heal repatch
# reuses those exact packages, so the installed system stays on one known
# driver even across OS updates. Safety: NVIDIA's userspace
# blobs target ancient glibc, and the Arch-compiled helpers the newer
# drivers need (egl-wayland2) are small — but the build still extracts every
# downloaded package and verifies no binary needs a newer glibc than the
# image ships (frozen SteamOS 3.8 = glibc 2.41; current Arch = 2.43, so
# blind installs of Arch-compiled libs are NOT safe in general).
#
#   sudo ./steamos-nvidia-installer.sh steamdeck-oobe-repair-<ver>.img[.bz2|.gz|.xz|.zst]
#
# Output: <image>-nvidia-usbinstall.img  →  dd to a USB stick, boot it on the
# target machine (UEFI, Secure Boot off), double-click
# "Install SteamOS (NVIDIA) to Hard Drive", pick a disk, done.
# The input image (plain .img or compressed .img.bz2/.gz/.xz/.zst) is copied
# first and never modified.
#
# What it does, in one pass over one copy:
#   1. Builds nvidia-open (DKMS) against the image's exact neptune kernel in
#      a throwaway overlayfs chroot, using Valve's frozen Arch mirror — the
#      toolchain/headers never enter the image. Copies only the driver
#      payload (modules, nvidia-utils, lib32, egl-*, GSP firmware) into the
#      rootfs and registers it in the pacman db.
#   2. Blacklists nouveau + enables nvidia-drm KMS via modprobe.d AND the
#      kernel cmdline (grub.cfg on the efi partition + /etc/default/grub —
#      the latter is what the installed system's regenerated grub uses).
#   3. Makes OS updates SELF-HEALING (default): updating from within Steam
#      works — Valve's updater stages the new OS in the spare A/B slot as
#      usual, then a wrapper around steamos-update rebuilds the NVIDIA
#      driver for the new OS (in a chroot on the new slot, from that
#      version's own repo branch) before the reboot prompt appears. If the
#      rebuild fails, the update is cancelled and the machine keeps booting
#      the current working system. Alternatives: --hold-updates makes Steam
#      always report "up to date" (old behaviour), --no-hold-updates leaves
#      stock update behaviour (an OS update then removes the driver!).
#   4. Adds the one-click installer: Valve's own repair_device.sh (which
#      installs by CLONING the running system, so the driver propagates)
#      patched for generic hardware — target-disk override, /dev/sdX
#      partition-suffix autodetect, NVMe-sanitize skipped on non-NVMe —
#      plus a zenity disk-picker wrapper, a desktop icon, and NOPASSWD sudo
#      for deck (remove /etc/sudoers.d/zz-deck-nopasswd on the installed
#      system once you set a password).
#
# Options:
#   --driver SPEC      Which NVIDIA driver to install. "latest" (default) =
#                      whatever current Arch ships. Otherwise a branch or
#                      version prefix — 580, 580.105.08, 580.105.08-4 — and
#                      the newest matching build is taken from the Arch
#                      archive. SteamOS itself ships 575.x; nvidia-open
#                      needs Turing (RTX 20xx) or newer whichever you pick.
#   --hold-updates     Hard-hold OS updates instead of self-healing (Steam
#                      always shows "up to date").
#   --no-hold-updates  Stock update behaviour — DANGER: an OS update boots an
#                      unpatched system (A/B fallback saves you, driver lost).
#   --no-installer     Skip step 4 (produce a plain bootable patched OS).
#   --trim-cuda        Drop CUDA/OpenCL/NVVM/OptiX libs (~350 MB smaller).
#   --hw-support       Build and install extra hardware support:
#                      - libratbag (from source) for modern Logitech mice
#                      - Logitech HID kernel modules (hid-logitech-dj,
#                        hid-logitech-hidpp) from upstream Linux
#                      - libfprint + fprintd for fingerprint readers
#                      Requires network access during the build.
#   --rootfs-size SIZE Root partition size. Accepts K, M, G suffixes
#                      (e.g. 10G, 10240M, 10240). Plain numbers are MiB.
#                      Default: 5120 (5 GiB as shipped by Valve). The
#                      installed rootfs-A and rootfs-B partitions are sized
#                      to this value and the btrfs filesystem is expanded
#                      to fill them automatically.
#   --skip-sigcheck    Disable pacman signature checks in the build chroot.
#   --fix-keyring      Force-initialise the pacman keyring in the build chroot
#                      with the standard Arch Linux + SteamOS holo keys.  Use
#                      when the frozen image keyring is too old to verify
#                      current packages.
#   --workdir DIR      Build dir. Default: auto-detects — uses disk if ≥9 GB
#                      free, otherwise falls back to /dev/shm (RAM). Kept
#                      between runs for caching. Use --workdir to override.
#
# Host needs: Arch-ish Linux, losetup, btrfs-progs, rsync, curl, kmod, zstd,
# python3, readelf (binutils), and bzip2/gzip/xz/zstd if using a compressed image.
# Notes: nvidia-open = RTX 20xx+ (Turing) only. Target machines need UEFI +
# Secure Boot off. First boot of an installed system lands in the gamescope
# Steam setup; if it black-screens: Ctrl+Alt+F3 → steamos-session-select plasma.

set -euo pipefail

# ----------------------------------------------------------------- modules
# This file is a thin wrapper: the per-stage logic lives in ./lib/*.sh and is
# SOURCED here so the whole run shares one shell (state, mounts, traps and
# helpers persist across stages). The wrapper decides the order. Run the
# verification tool after edits to prove nothing was lost:
#   python3 tools/verify-refactor.py
#   lib/common.sh            log/warn/die, in_chroot, cleanup trap
#   lib/setup.sh             copy image, loop + partition mounts, discovery
#   lib/resolve-driver.sh    resolve + download pinned NVIDIA packages, glibc check
#   lib/build-driver.sh      overlay chroot build + payload computation
#   lib/fetch-hid.sh         (optional) download upstream HID sources
#   lib/build-hid.sh         (optional) build Logitech HID kernel modules
#   lib/install-hw-libs.sh   (optional) libratbag, libfprint, fprintd
#   lib/install-driver.sh    copy payload into the image rootfs
#   lib/update-strategy.sh   hold / self-heal / stock update behaviour
#   lib/installer.sh         kernel cmdline + one-click installer
#   lib/finalize.sh          sanity checks, sync, unmount, summary
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for m in common setup resolve-driver build-driver fetch-hid build-hid install-hw-libs \
         install-driver update-strategy thunderbolt installer finalize; do
  source "$SCRIPT_DIR/lib/$m.sh"
done

# ------------------------------------------------------------------- args
UPDATE_MODE=selfheal   # selfheal | hold | stock
ADD_INSTALLER=1
TRIM_CUDA=0
SKIP_SIG=0
BUILD_HW_SUPPORT=0
THUNDERBOLT=0
FIX_KEYRING=0
DRIVER_SPEC=latest     # latest | <branch or version prefix, e.g. 580>
ROOTFS_SIZE=""          # MiB; empty = Valve's default 5120

# Upstream HID driver sources (currently Logitech receiver/HID++).
# Defaults to Linux master for latest device IDs; the source is
# automatically patched for compatibility with the image's kernel headers.
# Override with UPSTREAM_DRIVER_REF=ref to pin to a specific tag.
UPSTREAM_DRIVER_REF="${UPSTREAM_DRIVER_REF:-}"
UPSTREAM_DRIVER_SRC_BASE="https://raw.githubusercontent.com/torvalds/linux/$UPSTREAM_DRIVER_REF/drivers/hid"

WORKDIR=""
IMG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --driver)          DRIVER_SPEC="${2:?--driver needs an argument}"; shift ;;
    --hold-updates)    UPDATE_MODE=hold ;;
    --no-hold-updates) UPDATE_MODE=stock ;;
    --no-installer)    ADD_INSTALLER=0 ;;
    --hw-support)      BUILD_HW_SUPPORT=1 ;;
    --thunderbolt)     THUNDERBOLT=1 ;;
    --trim-cuda)       TRIM_CUDA=1 ;;
    --rootfs-size)     ROOTFS_SIZE="${2:?--rootfs-size needs an argument (MiB)}"; shift ;;
    --skip-sigcheck)   SKIP_SIG=1 ;;
    --fix-keyring)     FIX_KEYRING=1 ;;
    --workdir)         WORKDIR="${2:?--workdir needs an argument}"; _WORKDIR_EXPLICIT=1; shift ;;
    -h|--help)         sed -n '2,82p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)                die "Unknown option: $1" ;;
    *)                 IMG="$1" ;;
  esac
  shift
done

# ------------------------------------------------------------------ checks
[[ $EUID -eq 0 ]] || die "Run as root (sudo)."
[[ "$DRIVER_SPEC" == latest || "$DRIVER_SPEC" =~ ^[0-9]+(\.[0-9]+)*(-[0-9]+)?$ ]] \
  || die "--driver takes 'latest' or a version prefix like 580 / 580.105.08 / 580.105.08-4"
[[ -z "$ROOTFS_SIZE" || "$ROOTFS_SIZE" =~ ^[0-9]+[KMGkmg]?$ ]] \
  || die "--rootfs-size takes a size like 10G, 10240M, or 10240 (plain = MiB)"
if [[ -n "$ROOTFS_SIZE" ]]; then
  case "${ROOTFS_SIZE: -1}" in
    G|g) ROOTFS_SIZE=$(( ${ROOTFS_SIZE%[Gg]} * 1024 )) ;;
    M|m) ROOTFS_SIZE=${ROOTFS_SIZE%[Mm]} ;;
    K|k) ROOTFS_SIZE=$(( ${ROOTFS_SIZE%[Kk]} / 1024 )) ;;
  esac
  (( ROOTFS_SIZE > 0 )) || die "--rootfs-size must be a positive value"
fi
if [[ -z "$IMG" ]]; then
  # No image given — look for exactly one clean repair image next to the script.
  # Supports plain .img and compressed .img.bz2/.gz/.xz/.zst.
  script_dir="$(dirname "$(realpath "$0")")"
  mapfile -t candidates < <(find "$script_dir" -maxdepth 1 \
    \( -name '*.img' -o -name '*.img.bz2' -o -name '*.img.gz' -o -name '*.img.xz' -o -name '*.img.zst' \) \
    ! -name '*-nvidia*' | sort)
  case ${#candidates[@]} in
    0) die "No image given and no *.img[.bz2|.gz|.xz|.zst] found in $script_dir. Usage: $0 [options] <clean-oobe-repair.img[.bz2|.gz|.xz|.zst]>" ;;
    1) IMG="${candidates[0]}"; log "Auto-detected image: $IMG" ;;
    *) die "Multiple images in $script_dir — pass one explicitly:$(printf '\n  %s' "${candidates[@]}")" ;;
  esac
fi
[[ -f "$IMG" ]] || die "Image not found: $IMG"

# Check for the decompression tool if the input is compressed.
case "$IMG" in
  *.bz2) command -v bzip2 >/dev/null || die "Missing host tool: bzip2 (needed for .bz2 input)" ;;
  *.gz)  command -v gzip  >/dev/null || die "Missing host tool: gzip  (needed for .gz  input)" ;;
  *.xz)  command -v xz    >/dev/null || die "Missing host tool: xz    (needed for .xz  input)" ;;
  *.zst) command -v zstd   >/dev/null || die "Missing host tool: zstd  (needed for .zst input)" ;;
esac

for tool in losetup blkid btrfs rsync curl depmod sed awk tar zstd pacman python3 readelf; do
  command -v "$tool" >/dev/null || die "Missing host tool: $tool"
done

IMG="$(realpath "$IMG")"
# Strip any compression extension first, then replace .img with the output name.
IMG_BASE="${IMG%.bz2}"; IMG_BASE="${IMG_BASE%.gz}"; IMG_BASE="${IMG_BASE%.xz}"; IMG_BASE="${IMG_BASE%.zst}"
OUT="${IMG_BASE%.img}-nvidia-usbinstall.img"
# match the FILENAME only — the containing dir may itself be called
# "steamos-nvidia-installer" (the repo clone), which must not trip this guard
[[ "$(basename "$IMG")" == *-nvidia* ]] && die "Input looks like an already-patched image — start from the clean repair image."
[[ -e "$OUT" ]] && { warn "Removing previous output $OUT"; rm -f "$OUT" "${OUT}.src-fingerprint"; }

[[ -n "$WORKDIR" ]] || WORKDIR="$(dirname "$OUT")/.nvidia-usb-work"
LOOPDEV=""
UDEV_RULE=/run/udev/rules.d/90-steamos-nvidia-installer.rules

# ---------------------------------------------------------------- cleanup
trap cleanup EXIT

# ------------------------------------------------------------- orchestrate
log "Starting steamos-nvidia-installer (driver=$DRIVER_SPEC hw=$BUILD_HW_SUPPORT rootfs=${ROOTFS_SIZE:-5120}M)"
setup_resolve_workdir

# Re-derive paths now that $WORKDIR may have changed (e.g. to /dev/shm).
MNT="$WORKDIR/mnt"
EFIMNT="$WORKDIR/efi"
HOMEMNT="$WORKDIR/home"
UPPER="$WORKDIR/upper"
OVLWORK="$WORKDIR/ovlwork"
MERGED="$WORKDIR/merged"

setup_clear_stale_state
setup_dirs
setup_udev_guard

setup_copy_image
setup_loop_mount
setup_mount_partitions
setup_discover

resolve_driver_packages
check_glibc_compat
fetch_hid_sources

setup_overlay_chroot
build_driver
build_hid
install_thunderbolt_support
install_hw_libs
compute_payload

install_payload

apply_update_strategy

patch_kernel_cmdline
install_one_click_installer

finalize
