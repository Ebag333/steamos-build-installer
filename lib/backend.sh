#!/bin/bash
#
# backend.sh — shared non-UI backend for steamos-nvidia.sh
#
# This file owns build/flash policy and orchestration.  Frontends should call
# it with named arguments only; do not add user-facing positional parameters.
#
# Normally invoked via steamos-nvidia.sh; can also be called directly:
#   sudo ./lib/backend.sh --action build --image /home/image/steamdeck-repair.img.bz2
#   sudo ./lib/backend.sh --action flash --image /home/image/foo-nvidia-usbinstall.img \
#        --device /dev/sda --confirm
#   ./lib/backend.sh --action list-images
#   ./lib/backend.sh --action list-devices

set -euo pipefail

BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$BACKEND_DIR/.." && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# Defaults shared by CLI + GUI.
# ---------------------------------------------------------------------------
ACTION=""
IMG=""
TARGET_DEV=""
CONFIG_FILE=""

UPDATE_MODE="selfheal"       # selfheal | hold | stock
ADD_INSTALLER=1
TRIM_CUDA=0
SKIP_SIG=0
BUILD_HW_SUPPORT=0
HW_SUPPORT_ITEMS=""          # space-separated items: logitech-hid linux-firmware libfprint fprintd bolt dkms
THUNDERBOLT=0
DEFAULT_SESSION=""           # "" | desktop | game
FIX_KEYRING=0
INITRAMFS_MODULES=""         # space-separated module list; empty = stock
GAMING_ITEMS=""              # space-separated: trim-cuda gamemode pci-realloc tb-host-reset resize-bar fix-keyring skip-sigcheck debug-boot
DEBUG_BOOT=0                 # 1 = add rd.debug rd.log=all to kernel cmdline
ROOTFS_SIZE=""
WORKDIR=""
WORKDIR_LOCATION="auto"      # auto | ram | disk
_WORKDIR_EXPLICIT=""

FLASH_CONFIRMED=0
ALLOW_SYSTEM_DISK=0

# Build-time globals expected by sourced libraries.
OUT=""
OUT_FINAL=""
IMG_BASE=""
LOOPDEV=""
# shellcheck disable=SC2034
UDEV_RULE=/run/udev/rules.d/89-steamos-nvidia-installer.rules
UPSTREAM_DRIVER_REF="${UPSTREAM_DRIVER_REF:-}"

backend_usage() {
  cat <<'EOF'
Usage:
  backend.sh --action <build|flash|list-images|list-devices|is-system-disk|configure|reboot> [options]

Common:
  --action ACTION
  --image FILE
  --config FILE

Build:
  --workingdir DIR          Canonical name for build workspace
  --workdir DIR             Compatibility alias for --workingdir
  --workdir-location MODE   auto | ram | disk
  --rootfs-size SIZE
  --session MODE            desktop | game
  --hold-updates
  --no-hold-updates
  --no-installer
  --trim-cuda
  --thunderbolt
  --hw-support
  --hw-support-items ITEMS  Space-separated: logitech-hid linux-firmware libfprint fprintd bolt dkms
  --initramfs MODULES   Space-separated module list for initramfs (empty = stock)
  --gaming-items ITEMS  Space-separated: trim-cuda gamemode pci-realloc tb-host-reset resize-bar fix-keyring skip-sigcheck debug-boot
  --debug-boot          Add rd.debug rd.log=all to kernel cmdline for boot debugging
  --skip-sigcheck
  --fix-keyring

Flash:
  --device /dev/sdX
  --confirm                 Required for destructive CLI/backend flash
  --allow-system-disk       Override system-disk protection

No positional parameters are accepted.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing.  Config is loaded first, then explicit args override it.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--config" ]]; then
    (( i + 1 < ${#args[@]} )) || { echo "--config requires a value" >&2; exit 2; }
    CONFIG_FILE="${args[$((i+1))]}"
    break
  fi
done

if [[ -n "$CONFIG_FILE" ]]; then
  [[ -f "$CONFIG_FILE" ]] || { echo "Config file not found: $CONFIG_FILE" >&2; exit 2; }
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

# shellcheck disable=SC2034
while [[ $# -gt 0 ]]; do
  case "$1" in
    --action)            ACTION="${2:?--action requires a value}"; shift 2 ;;
    --image)             IMG="${2:?--image requires a value}"; shift 2 ;;
    --device)            TARGET_DEV="${2:?--device requires a value}"; shift 2 ;;
    --config)            CONFIG_FILE="${2:?--config requires a value}"; shift 2 ;;

    --workingdir|--workdir)
                         WORKDIR="${2:?$1 requires a value}"; _WORKDIR_EXPLICIT=1; shift 2 ;;
    --workdir-location)  WORKDIR_LOCATION="${2:?--workdir-location requires a value}"; shift 2 ;;
    --rootfs-size)       ROOTFS_SIZE="${2:?--rootfs-size requires a value}"; shift 2 ;;
    --session)           DEFAULT_SESSION="${2:?--session requires a value}"; shift 2 ;;
    --hold-updates)      UPDATE_MODE="hold"; shift ;;
    --no-hold-updates)   UPDATE_MODE="stock"; shift ;;
    --no-installer)      ADD_INSTALLER=0; shift ;;
    --trim-cuda)         TRIM_CUDA=1; shift ;;
    --thunderbolt)       THUNDERBOLT=1; shift ;;
    --hw-support)        BUILD_HW_SUPPORT=1; shift ;;
    --hw-support-items)  HW_SUPPORT_ITEMS="${2:?--hw-support-items requires a list}"; BUILD_HW_SUPPORT=1; shift 2 ;;
    --initramfs)         INITRAMFS_MODULES="${2:?--initramfs requires a module list}"; shift 2 ;;
    --gaming-items)      GAMING_ITEMS="${2:?--gaming-items requires a list}"; shift 2 ;;
    --debug-boot)        DEBUG_BOOT=1; shift ;;
    --skip-sigcheck)     SKIP_SIG=1; shift ;;
    --fix-keyring)       FIX_KEYRING=1; shift ;;

    --confirm)           FLASH_CONFIRMED=1; shift ;;
    --allow-system-disk) ALLOW_SYSTEM_DISK=1; shift ;;

    -h|--help) backend_usage; exit 0 ;;
    --) shift; [[ $# -eq 0 ]] || { echo "Positional parameters are not supported." >&2; exit 2; } ;;
    *) echo "Unknown argument: $1" >&2; backend_usage >&2; exit 2 ;;
  esac
done

[[ -n "$ACTION" ]] || { echo "--action is required" >&2; backend_usage >&2; exit 2; }

# ---------------------------------------------------------------------------
# Shared flash backend.
# ---------------------------------------------------------------------------
load_flash_libs() {
  # shellcheck disable=SC1091
  source "$BACKEND_DIR/common.sh"
  # shellcheck disable=SC1091
  source "$BACKEND_DIR/flash.sh"
}

flash_image_is_complete() {
  local image="$1"
  [[ -f "$image" && -f "${image}.build-complete" ]]
}

flash_discover_images() {
  # During the current transition, RAM output is still a legitimate completed
  # location.  Once build publication is made canonical, remove /dev/shm here.
  local search_dirs=(
    "$PROJECT_DIR"
    "/home/image"
    "/dev/shm/nvidia-build"
    "$HOME/Downloads"
  )
  local d f
  local -a found=()

  for d in "${search_dirs[@]}"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      flash_image_is_complete "$f" || continue
      found+=("$(readlink -f "$f")")
    done < <(find "$d" -maxdepth 1 -name '*nvidia*usbinstall*.img' -type f 2>/dev/null)
  done

  ((${#found[@]})) || return 0

  # TSV: path, location, human size, modified epoch, modified display
  printf '%s\n' "${found[@]}" | sort -u | while IFS= read -r f; do
    local where
    case "$f" in
      /dev/shm/*) where="RAM build" ;;
      /home/image/*) where="Persistent output" ;;
      "$PROJECT_DIR"/*) where="Project output" ;;
      *) where="Other" ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$f" \
      "$where" \
      "$(du -h "$f" | cut -f1)" \
      "$(stat -c '%Y' "$f")" \
      "$(date -r "$f" '+%Y-%m-%d %H:%M:%S')"
  done | sort -t$'\t' -k4,4nr
}

flash_validate_image() {
  local image="$1"
  [[ -f "$image" ]] || { echo "Image not found: $image" >&2; return 1; }

  if [[ "$(basename "$image")" == *nvidia*usbinstall*.img ]] && ! flash_image_is_complete "$image"; then
    echo "Refusing NVIDIA installer image without .build-complete marker: $image" >&2
    return 1
  fi
}

backend_flash() {
  [[ $EUID -eq 0 ]] || { echo "Flash action requires root." >&2; exit 1; }
  [[ "$FLASH_CONFIRMED" -eq 1 ]] || {
    echo "Flash is destructive. Re-run with --confirm after the user has confirmed the target." >&2
    exit 2
  }
  [[ -n "$IMG" ]] || { echo "--image is required for flash" >&2; exit 2; }
  [[ -n "$TARGET_DEV" ]] || { echo "--device is required for flash" >&2; exit 2; }

  IMG="$(readlink -f "$IMG")"
  flash_validate_image "$IMG"
  [[ -b "$TARGET_DEV" ]] || { echo "Not a block device: $TARGET_DEV" >&2; exit 1; }

  if [[ "$ALLOW_SYSTEM_DISK" -ne 1 ]] && flash_is_system_disk "$TARGET_DEV"; then
    echo "Refusing to flash the current system disk: $TARGET_DEV" >&2
    echo "Use --allow-system-disk only if this has been explicitly verified." >&2
    exit 1
  fi

  flash_write "$IMG" "$TARGET_DEV"
}

# ---------------------------------------------------------------------------
# Shared build backend.  This is the former steamos-nvidia-installer.sh build
# orchestration moved out of the frontend.
# ---------------------------------------------------------------------------
load_build_libs() {
  local m
  for m in common common_system common_modules common_drivers overlay rootfs-etc setup \
         grub install-hw-libs \
         update-strategy installer finalize; do
    # shellcheck disable=SC1090
    source "$BACKEND_DIR/$m.sh"
  done
}

check_build_deps() {
  if [[ -f "$BACKEND_DIR/check-deps.sh" ]]; then
    bash "$BACKEND_DIR/check-deps.sh" --check-only || exit 1
    return 0
  fi

  local missing=()
  local cmd
  for cmd in losetup blkid btrfs bzip2 gzip xz pv rsync curl depmod sed awk tar zstd pacman python3 readelf sgdisk sfdisk; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    local pkgs=()
    for cmd in "${missing[@]}"; do
      case "$cmd" in
        btrfs)     pkgs+=(btrfs-progs) ;;
        readelf)   pkgs+=(binutils) ;;
        depmod)    pkgs+=(kmod) ;;
        sgdisk)    pkgs+=(gptfdisk) ;;
        *)         pkgs+=("$cmd") ;;
      esac
    done
    mapfile -t pkgs < <(printf "%s\n" "${pkgs[@]}" | sort -u)
    die "Missing host tools: ${missing[*]}. Install with: pacman -S ${pkgs[*]}"
  fi
}

normalize_build_options() {

  [[ -z "$ROOTFS_SIZE" || "$ROOTFS_SIZE" =~ ^[0-9]+[KMGkmg]?$ ]] \
    || die "--rootfs-size takes a size like 10G, 10240M, or 10240 (plain = MiB)"

  case "$DEFAULT_SESSION" in
    ""|desktop|game) ;;
    *) die "--session must be desktop or game" ;;
  esac

  case "$WORKDIR_LOCATION" in
    auto|ram|disk) ;;
    *) die "--workdir-location must be auto, ram, or disk" ;;
  esac

  case "$UPDATE_MODE" in
    selfheal|hold|stock) ;;
    *) die "Invalid update mode: $UPDATE_MODE" ;;
  esac

  if [[ -n "$ROOTFS_SIZE" ]]; then
    case "${ROOTFS_SIZE: -1}" in
      G|g) ROOTFS_SIZE=$(( ${ROOTFS_SIZE%[Gg]} * 1024 )) ;;
      M|m) ROOTFS_SIZE="${ROOTFS_SIZE%[Mm]}" ;;
      K|k) ROOTFS_SIZE=$(( ${ROOTFS_SIZE%[Kk]} / 1024 )) ;;
    esac
    (( ROOTFS_SIZE > 0 )) || die "--rootfs-size must be positive"
  fi
}

resolve_build_image() {
  if [[ -n "$IMG" ]]; then
    [[ -f "$IMG" ]] || die "Image not found: $IMG"
    IMG="$(realpath "$IMG")"
    return 0
  fi

  local -a candidates=()
  mapfile -t candidates < <(
    find "$PROJECT_DIR" -maxdepth 1 \
      \( -name '*.img' -o -name '*.img.bz2' -o -name '*.img.gz' -o -name '*.img.xz' -o -name '*.img.zst' \) \
      ! -name '*-nvidia*' | sort
  )

  case ${#candidates[@]} in
    0) die "No source image specified with --image and none was found beside the script." ;;
    1) IMG="$(realpath "${candidates[0]}")"; log "Auto-detected image: $IMG" ;;
    *) die "Multiple source images found; pass one explicitly with --image." ;;
  esac
}

backend_build() {
  [[ $EUID -eq 0 ]] || die "Build action requires root."

  load_build_libs
  normalize_build_options
  resolve_build_image
  check_build_deps

  [[ "$(basename "$IMG")" != *-nvidia* ]] \
    || die "Input looks like an already-patched image — start from the clean repair image."

  IMG_BASE="${IMG%.bz2}"
  IMG_BASE="${IMG_BASE%.gz}"
  IMG_BASE="${IMG_BASE%.xz}"
  IMG_BASE="${IMG_BASE%.zst}"

  OUT_FINAL="${IMG_BASE%.img}-nvidia-usbinstall.img"
  OUT="${OUT_FINAL}.building"

  [[ -n "$WORKDIR" ]] || WORKDIR="$(dirname "$OUT")/.nvidia-usb-work"

  # shellcheck disable=SC2034
  LOOPDEV=""
  # shellcheck disable=SC2154
  trap '_trap_rc=$?; trap - EXIT; set +e; cleanup; exit "$_trap_rc"' EXIT

  : "${UPSTREAM_DRIVER_REF:=master}"
  # shellcheck disable=SC2034
  UPSTREAM_DRIVER_SRC_BASE="https://raw.githubusercontent.com/torvalds/linux/$UPSTREAM_DRIVER_REF/drivers/hid"

  # Log mount namespace proof — verifies unshare isolation is active.
  log "Build mount namespace: $(readlink /proc/self/ns/mnt 2>/dev/null || echo '<unknown>')"
  log "Root mount propagation: $(findmnt -no PROPAGATION / 2>/dev/null || echo '<unknown>')"

  log "Starting steamos-nvidia build (hw=$BUILD_HW_SUPPORT rootfs=${ROOTFS_SIZE:-5120}M)"

  # Normalize gaming-items members that also have standalone switches.
  # This makes --gaming-items "pci-realloc debug-boot" equivalent to
  # passing both --gaming-items "pci-realloc" and --debug-boot.
  # shellcheck disable=SC2034
  [[ " $GAMING_ITEMS " == *" trim-cuda "* ]]     && TRIM_CUDA=1
  # shellcheck disable=SC2034
  [[ " $GAMING_ITEMS " == *" debug-boot "* ]]    && DEBUG_BOOT=1
  # shellcheck disable=SC2034
  [[ " $GAMING_ITEMS " == *" skip-sigcheck "* ]] && SKIP_SIG=1
  # shellcheck disable=SC2034
  [[ " $GAMING_ITEMS " == *" fix-keyring "* ]]   && FIX_KEYRING=1

  # Preserve the current builder behavior while the output/publication cleanup
  # is handled as a separate refactor.
  ORIG_OUT_FINAL="$OUT_FINAL"

  setup_resolve_workdir

  if [[ "$OUT_FINAL" != "$ORIG_OUT_FINAL" ]]; then
    local stale
    for stale in "$ORIG_OUT_FINAL" "${ORIG_OUT_FINAL}.building" \
                 "${ORIG_OUT_FINAL}.src-fingerprint" "${ORIG_OUT_FINAL}.build-complete"; do
      if [[ -e "$stale" ]]; then
        log "Removing stale build artifact from previous mode: $(basename "$stale")"
        rm -f "$stale"
      fi
    done
  fi

  MNT="$WORKDIR/mnt"
  # shellcheck disable=SC2034
  EFIMNT="$WORKDIR/efi"
  HOMEMNT="$WORKDIR/home"
  # shellcheck disable=SC2034
  UPPER="$WORKDIR/upper"
  # shellcheck disable=SC2034
  OVLWORK="$WORKDIR/ovlwork"
  # shellcheck disable=SC2034
  MERGED="$WORKDIR/merged"
  # shellcheck disable=SC2034
  OVL_IMG="$WORKDIR/overlay-work.img"
  # shellcheck disable=SC2034
  OVL_MNT="$WORKDIR/overlay-mnt"
  # shellcheck disable=SC2034
  OVL_LOOPDEV=""

  setup_clear_stale_state
  setup_dirs

  setup_copy_image
  progress_emit decompress
  setup_loop_mount

  echo '=== SHARED HOME ==='
  ls -l /dev/disk/by-partsets/shared/home || true
  readlink -f /dev/disk/by-partsets/shared/home || true

  echo
  echo '=== LOOP HOME PROPERTIES ==='
  udevadm info -q property -n "$HOMEPART" |
    grep -E 'ID_PART_ENTRY_(UUID|NAME)|UDISKS_IGNORE' || true

  echo
  echo '=== LINKS OWNED BY LOOP HOME ==='
  udevadm info -q symlink -n "$HOMEPART" || true

  # Preparation
  prepare_writable_rootfs
  progress_emit create_fs

  setup_mount_partitions
  setup_discover
  progress_emit mount

  # Overlay
  setup_overlay_chroot
  progress_emit setup_chroot

  # Kernel build environment
  install_kernel_headers

  # Sources needed for custom modules
  fetch_hid_sources
  progress_emit resolve_driver

  # Packages + NVIDIA
  install_hw_libs
  progress_emit install_hw

  # Custom modules
  build_hid
  progress_emit build_hid

  # Hardware configuration
  install_thunderbolt_support

  # Build payload
  compute_payload

  # Install payload
  install_payload
  progress_emit copy_payload

  if [[ "$UPDATE_MODE" == selfheal ]]; then
    log "Bundling self-heal helper libraries"
    local helper src_helper
    for helper in common_system common_modules common_drivers grub; do
      src_helper="$BACKEND_DIR/$helper.sh"
      [[ -f "$src_helper" ]] || die "Self-heal helper missing: $src_helper"
      install -m 0644 "$src_helper" "$MNT/usr/lib/steamos-nvidia/$helper.sh"
    done
  fi

  # ── Final parameter accumulation checkpoint ──────────────────────────────
  # All add_kernel_param() calls must happen BEFORE this point.
  # Anything added after apply_update_strategy() creates split-brain:
  # the initial image boots with it, but driver.conf won't contain it,
  # so the next self-heal loses it.

  # Phase 1: write accumulated params to persistent defaults.
  # Idempotent — safe to call even if install_payload already called
  # patch_grub_steamos earlier (which it no longer does, but future-proof).
  patch_persistent_defaults

  # Phase 2: authoritative direct patch of EFI grub.cfg.
  patch_kernel_cmdline

  # Phase 3: validate everything landed.
  finalize_grub
  progress_emit configure_grub

  # Capture FINAL EXTRA_CMDLINE_ADD in driver.conf so self-heal
  # reproduces the exact same kernel parameters.
  apply_update_strategy

  inject_log_collector
  install_one_click_installer
  progress_emit patch_installer

  if [[ -n "$DEFAULT_SESSION" ]]; then
    log "Setting default login mode to $DEFAULT_SESSION"
    local state_toml_content
    state_toml_content="$(cat <<EOF
version = 1

[services]

[session_manager]
default_login_mode = "$DEFAULT_SESSION"
EOF
)"

    # Write to rootfs — this gets dd'd to the internal disk by the
    # one-click installer, so the installed system boots to the right mode.
    local rootfs_cfg="$MNT/home/deck/.config/steamos-manager"
    mkdir -p "$rootfs_cfg"
    echo "$state_toml_content" > "$rootfs_cfg/state.toml"
    chown -R 1000:1000 "$rootfs_cfg"

    # Write to the live USB's home partition so the USB itself also
    # boots to the selected mode.
    local usb_cfg="$HOMEMNT/deck/.config/steamos-manager"
    mkdir -p "$usb_cfg"
    echo "$state_toml_content" > "$usb_cfg/state.toml"
    chown -R 1000:1000 "$usb_cfg"
  fi

  progress_emit finalize
  finalize
}

backend_configure() {
  [[ -f "$BACKEND_DIR/post-install.sh" ]] || {
    echo "post-install.sh not found in lib/" >&2
    exit 1
  }
  exec bash "$BACKEND_DIR/post-install.sh"
}

backend_reboot() {
  [[ $EUID -eq 0 ]] || { echo "Reboot action requires root." >&2; exit 1; }
  [[ -f "$BACKEND_DIR/post-install.sh" ]] || {
    echo "post-install.sh not found in lib/" >&2
    exit 1
  }
  exec bash "$BACKEND_DIR/post-install.sh" --reboot-only
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "$ACTION" in
  build)
    backend_build
    ;;
  flash)
    load_flash_libs
    backend_flash
    ;;
  list-images)
    flash_discover_images
    ;;
  list-devices)
    load_flash_libs
    flash_scan_devices
    ;;
  is-system-disk)
    [[ -n "$TARGET_DEV" ]] || { echo "--device is required" >&2; exit 2; }
    load_flash_libs
    flash_is_system_disk "$TARGET_DEV"
    ;;
  preflight)
    [[ -n "$IMG" ]] || { echo "--image is required" >&2; exit 2; }
    [[ -n "$TARGET_DEV" ]] || { echo "--device is required" >&2; exit 2; }
    load_flash_libs
    IMG="$(readlink -f "$IMG")"
    flash_preflight "$IMG" "$TARGET_DEV"
    ;;
  configure)
    backend_configure
    ;;
  reboot)
    backend_reboot
    ;;
  *)
    echo "Unknown action: $ACTION" >&2
    backend_usage >&2
    exit 2
    ;;
esac
