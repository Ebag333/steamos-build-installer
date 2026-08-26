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

UPDATE_MODE="selfheal" # selfheal | hold | stock
ADD_INSTALLER=1
HW_SUPPORT_ITEMS=""        # space-separated items: linux-firmware libfprint fprintd bolt dkms
DEFAULT_SESSION="game"     # desktop | game
INITRAMFS_MODULES=""       # space-separated module list; empty = stock
GAMING_ITEMS=""            # space-separated: (all items now handled by optimization system)
TARGET_VARIANT="steamdeck" # steamdeck | steamdeck-oobe
UPDATE_BRANCH="stable"     # stable | beta | preview | rc | bc | pc | main
ROOTFS_SIZE=""
OUTPUT_DIR="" # empty = same directory as source image
WORKDIR=""
WORKDIR_LOCATION="auto" # auto | ram | disk
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
  backend.sh --action <build|flash|flashless|list-images|list-devices|is-system-disk|configure|reboot> [options]

Common:
  --action ACTION           Required: build, flash, flashless, validate, list-images, list-devices, is-system-disk, configure, reboot
  --image FILE              Source image path (for build)
  --config FILE             Build configuration file

Build:
  All build settings are configured via --config file.
  --output-dir DIR          Directory for finished image (default: same as source)

Flash:
  --device /dev/sdX         Target device for flash action
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
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--config" ]]; then
    ((i + 1 < ${#args[@]})) || {
      echo "--config requires a value" >&2
      exit 2
    }
    CONFIG_FILE="${args[$((i + 1))]}"
    break
  fi
done

if [[ -n "$CONFIG_FILE" ]]; then
  [[ -f "$CONFIG_FILE" ]] || {
    echo "Config file not found: $CONFIG_FILE" >&2
    exit 2
  }
  # shellcheck source=steamos-nvidia.example.conf
  source "$CONFIG_FILE"
fi

# shellcheck disable=SC2034
while [[ $# -gt 0 ]]; do
  case "$1" in
    --action)
      ACTION="${2:?--action requires a value}"
      shift 2
      ;;
    --image)
      IMG="${2:?--image requires a value}"
      shift 2
      ;;
    --device)
      TARGET_DEV="${2:?--device requires a value}"
      shift 2
      ;;
    --config)
      CONFIG_FILE="${2:?--config requires a value}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:?--output-dir requires a value}"
      shift 2
      ;;

    --confirm)
      FLASH_CONFIRMED=1
      shift
      ;;
    --allow-system-disk)
      ALLOW_SYSTEM_DISK=1
      shift
      ;;

    -h | --help)
      backend_usage
      exit 0
      ;;
    --)
      shift
      [[ $# -eq 0 ]] || {
        echo "Positional parameters are not supported." >&2
        exit 2
      }
      ;;
    *)
      echo "Unknown argument: $1" >&2
      backend_usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$ACTION" ]] || {
  echo "--action is required" >&2
  backend_usage >&2
  exit 2
}

# ---------------------------------------------------------------------------
# Shared flash backend.
# ---------------------------------------------------------------------------
load_flash_libs() {
  # shellcheck source=lib/common.sh
  source "$BACKEND_DIR/common.sh"
  # shellcheck source=lib/flash.sh
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
  [[ -n "${OUTPUT_DIR:-}" ]] && search_dirs+=("$OUTPUT_DIR")
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
  [[ -f "$image" ]] || {
    echo "Image not found: $image" >&2
    return 1
  }

  if [[ "$(basename "$image")" == *nvidia*usbinstall*.img ]] && ! flash_image_is_complete "$image"; then
    echo "Refusing NVIDIA installer image without .build-complete marker: $image" >&2
    return 1
  fi
}

backend_flash() {
  [[ $EUID -eq 0 ]] || {
    echo "Flash action requires root." >&2
    exit 1
  }
  [[ "$FLASH_CONFIRMED" -eq 1 ]] || {
    echo "Flash is destructive. Re-run with --confirm after the user has confirmed the target." >&2
    exit 2
  }
  [[ -n "$IMG" ]] || {
    echo "--image is required for flash" >&2
    exit 2
  }
  [[ -n "$TARGET_DEV" ]] || {
    echo "--device is required for flash" >&2
    exit 2
  }

  IMG="$(readlink -f "$IMG")"
  flash_validate_image "$IMG"
  [[ -b "$TARGET_DEV" ]] || {
    echo "Not a block device: $TARGET_DEV" >&2
    exit 1
  }

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
  # Source library loader and pipeline
  # shellcheck source=lib/library-loader.sh
  source "$BACKEND_DIR/library-loader.sh"
  # shellcheck source=lib/pipeline.sh
  source "$BACKEND_DIR/pipeline.sh"
  # shellcheck source=lib/workflow-common.sh
  source "$BACKEND_DIR/workflow-common.sh"

  # Source pipeline definition
  # shellcheck source=lib/pipelines/pipeline_build.sh
  source "$BACKEND_DIR/pipelines/pipeline_build.sh"

  # Load all build workflow libraries
  load_workflow_libs "build" "$BACKEND_DIR"
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
        btrfs) pkgs+=(btrfs-progs) ;;
        readelf) pkgs+=(binutils) ;;
        depmod) pkgs+=(kmod) ;;
        sgdisk) pkgs+=(gptfdisk) ;;
        *) pkgs+=("$cmd") ;;
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
    "" | desktop | game) ;;
    *) die "--session must be desktop or game" ;;
  esac

  case "$WORKDIR_LOCATION" in
    auto | ram | disk) ;;
    *) die "--workdir-location must be auto, ram, or disk" ;;
  esac

  case "$UPDATE_MODE" in
    selfheal | hold | stock) ;;
    *) die "Invalid update mode: $UPDATE_MODE" ;;
  esac

  if [[ -n "$ROOTFS_SIZE" ]]; then
    case "${ROOTFS_SIZE: -1}" in
      G | g) ROOTFS_SIZE=$((${ROOTFS_SIZE%[Gg]} * 1024)) ;;
      M | m) ROOTFS_SIZE="${ROOTFS_SIZE%[Mm]}" ;;
      K | k) ROOTFS_SIZE=$((${ROOTFS_SIZE%[Kk]} / 1024)) ;;
    esac
    ((ROOTFS_SIZE > 0)) || die "--rootfs-size must be positive"
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
    1)
      IMG="$(realpath "${candidates[0]}")"
      log "Auto-detected image: $IMG"
      ;;
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

  local out_basename="${IMG_BASE%.img}-nvidia-usbinstall.img"
  out_basename="$(basename "$out_basename")"

  # Output directory: explicit OUTPUT_DIR, or same directory as source image.
  if [[ -n "${OUTPUT_DIR:-}" ]]; then
    mkdir -p "$OUTPUT_DIR"
    OUT_FINAL="$OUTPUT_DIR/$out_basename"
  else
    OUT_FINAL="$(dirname "$IMG_BASE")/$out_basename"
  fi
  OUT="${OUT_FINAL}.building"

  [[ -n "$WORKDIR" ]] || WORKDIR="$(dirname "$OUT")/.nvidia-usb-work"

  # shellcheck disable=SC2034
  LOOPDEV=""
  local _trap_rc
  trap '_trap_rc=$?; trap - EXIT; set +e; cleanup; exit "$_trap_rc"' EXIT

  : "${UPSTREAM_DRIVER_REF:=master}"
  # shellcheck disable=SC2034
  UPSTREAM_DRIVER_SRC_BASE="https://raw.githubusercontent.com/torvalds/linux/$UPSTREAM_DRIVER_REF/drivers/hid"

  # Log mount namespace proof — verifies unshare isolation is active.
  log "Build mount namespace: $(readlink /proc/self/ns/mnt 2>/dev/null || echo '<unknown>')"
  log "Root mount propagation: $(findmnt -no PROPAGATION / 2>/dev/null || echo '<unknown>')"

  log "Starting steamos-nvidia build (rootfs=${ROOTFS_SIZE:-5120}M)"

  # Register and run the build pipeline
  register_build_pipeline
  if ! run_pipeline; then
    die "Build pipeline failed"
  fi
}

backend_configure() {
  [[ -f "$BACKEND_DIR/post-install.sh" ]] || {
    echo "post-install.sh not found in lib/" >&2
    exit 1
  }
  exec bash "$BACKEND_DIR/post-install.sh"
}

backend_validate() {
  load_workflow_libs "validate" "$BACKEND_DIR"

  # Source the validate pipeline
  # shellcheck source=lib/pipelines/pipeline_validate.sh
  source "$BACKEND_DIR/pipelines/pipeline_validate.sh"

  # Pass config and root via environment for the pipeline to read
  export VALIDATE_CONFIG="${CONFIG_FILE:-}"
  export VALIDATE_ROOT="${VALIDATE_ROOT:-/}"
  export VALIDATE_ITEMS="${VALIDATE_ITEMS:-}"

  register_validate_pipeline
  if ! run_pipeline; then
    exit 1
  fi
}

backend_flashless() {
  [[ $EUID -eq 0 ]] || die "Flashless install requires root."
  [[ -n "$IMG" ]] || die "--image is required for flashless install"
  [[ -f "$IMG" ]] || die "Image not found: $IMG"
  IMG="$(readlink -f "$IMG")"

  load_build_libs
  flashless_install "$IMG"
}

backend_reboot() {
  [[ $EUID -eq 0 ]] || {
    echo "Reboot action requires root." >&2
    exit 1
  }
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
  flashless)
    backend_flashless
    ;;
  list-images)
    flash_discover_images
    ;;
  list-devices)
    load_flash_libs
    flash_scan_devices
    ;;
  is-system-disk)
    [[ -n "$TARGET_DEV" ]] || {
      echo "--device is required" >&2
      exit 2
    }
    load_flash_libs
    flash_is_system_disk "$TARGET_DEV"
    ;;
  preflight)
    [[ -n "$IMG" ]] || {
      echo "--image is required" >&2
      exit 2
    }
    [[ -n "$TARGET_DEV" ]] || {
      echo "--device is required" >&2
      exit 2
    }
    load_flash_libs
    IMG="$(readlink -f "$IMG")"
    flash_preflight "$IMG" "$TARGET_DEV"
    ;;
  configure)
    backend_configure
    ;;
  validate)
    backend_validate
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
