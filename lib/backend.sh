#!/bin/bash
#
# backend.sh — shared non-UI backend for steamos-build.sh
#
# This file owns build/flash policy and orchestration.  Frontends should call
# it with named arguments only; do not add user-facing positional parameters.
#
# Normally invoked via steamos-build.sh; can also be called directly:
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
# shellcheck disable=SC2034  # consumed by lib/finalize.sh and lib/installer.sh
ADD_INSTALLER=1
HW_SUPPORT_ITEMS=""    # space-separated items: linux-firmware libfprint fprintd bolt dkms
DEFAULT_SESSION="game" # desktop | game
INITRAMFS_MODULES=""   # space-separated module list; empty = stock
GAMING_ITEMS=""        # space-separated: (all items now handled by optimization system)
# shellcheck disable=SC2034  # consumed by lib/common_drivers.sh, lib/finalize.sh, and lib/flashless.sh
TARGET_VARIANT="steamdeck" # steamdeck | steamdeck-oobe
UPDATE_BRANCH="stable"     # stable | beta | preview | rc | bc | pc | main
PACMAN_REPO="valve"        # valve | main
BASE_OS_MODE="additive"    # additive | upgrade
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
UDEV_RULE=/run/udev/rules.d/89-steamos-build-installer.rules
UPSTREAM_DRIVER_REF="${UPSTREAM_DRIVER_REF:-}"

backend_usage() {
  cat <<'EOF'
Usage:
  backend.sh --action <build|flash|flashless|live|validate|preflight|list-images|list-devices|is-system-disk|reboot> [options]

Common:
  --action ACTION           Required: build, flash, flashless, live, validate, preflight, list-images, list-devices, is-system-disk, reboot
  --image FILE              Source image path (for build)
  --config FILE             Build configuration file (required for build, flash, live)

Build:
  All build settings are configured via --config file.
  --output-dir DIR          Directory for finished image (default: same as source)

Flash:
  --device /dev/sdX         Target device for flash action
  --confirm                 Required for destructive CLI/backend flash
  --allow-system-disk       Override system-disk protection

Live:
  Config file uses the same format as build.

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
    [[ $((i + 1)) -lt ${#args[@]} ]] || {
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
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

# shellcheck disable=SC2034
# shellcheck source=lib/args.sh
source "$BACKEND_DIR/args.sh"

while [[ $# -gt 0 ]]; do
  if parse_common_arg "$1" "${2:-}"; then
    shift "$_ARG_SHIFT"
    continue
  fi

  case "$1" in
    --confirm)
      FLASH_CONFIRMED=1
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
    "/dev/shm/steamos-build"
    "$HOME/Downloads"
  )
  [[ -n "${OUTPUT_DIR:-}" ]] && search_dirs+=("$OUTPUT_DIR")
  local d f
  local -a found=()

  for d in "${search_dirs[@]}"; do
    [[ -d "$d" ]] || continue
    while IFS="" read -r f; do
      [[ -n "$f" ]] || continue
      flash_image_is_complete "$f" || continue
      found+=("$(readlink -f "$f")")
    done < <(find "$d" -maxdepth 1 -name '*nvidia*usbinstall*.img' -type f 2>/dev/null)
  done

  ((${#found[@]})) || return 0

  # TSV: path, location, human size, modified epoch, modified display
  local _sorted
  _sorted="$(printf '%s\n' "${found[@]}" | sort -u)"
  while IFS="" read -r f; do
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
  done <<< "$_sorted" | sort -t$'\t' -k4,4nr
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
# Shared build backend.  This is the former steamos-build-installer.sh build
# orchestration moved out of the frontend.
# ---------------------------------------------------------------------------
load_build_libs() {
  # Source library loader and pipeline
  # shellcheck source=lib/library-loader.sh
  source "$BACKEND_DIR/library-loader.sh"

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
  for cmd in losetup blkid btrfs bzip2 gzip xz pv rsync curl depmod sed awk tar zstd pacman pactree python3 readelf sgdisk sfdisk; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    local pkgs=()
    for cmd in "${missing[@]}"; do
      case "$cmd" in
        btrfs) pkgs+=(btrfs-progs) ;;
        readelf) pkgs+=(binutils) ;;
        depmod) pkgs+=(kmod) ;;
        pactree) pkgs+=(pacman-contrib) ;;
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

  case "$BASE_OS_MODE" in
    additive | upgrade) ;;
    *) die "Invalid base OS mode: $BASE_OS_MODE" ;;
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
  local _cleanup_done=0
  trap '_trap_rc=$?; trap - EXIT; set +e; [[ "${_cleanup_done:-0}" -eq 0 ]] && cleanup; exit "$_trap_rc"' EXIT

  : "${UPSTREAM_DRIVER_REF:=master}"
  # shellcheck disable=SC2034
  UPSTREAM_DRIVER_SRC_BASE="https://raw.githubusercontent.com/torvalds/linux/$UPSTREAM_DRIVER_REF/drivers/hid"

  # Log mount namespace proof — verifies unshare isolation is active.
  log "Build mount namespace: $(readlink /proc/self/ns/mnt 2>/dev/null || echo '<unknown>')"
  log "Root mount propagation: $(findmnt -no PROPAGATION / 2>/dev/null || echo '<unknown>')"

  log "Starting steamos-build build (rootfs=${ROOTFS_SIZE:-5120}M)"

  # Register and run the build pipeline
  register_build_pipeline
  if ! run_pipeline; then
    die "Build pipeline failed"
  fi
}

# ---------------------------------------------------------------------------
# Validate backend — image mounting and cleanup
# ---------------------------------------------------------------------------

VALIDATE_MNT=""
VALIDATE_LOOP=""
VALIDATE_ROOTFS=""
VALIDATE_VARPART=""
VALIDATE_UDEV_RULE="/run/udev/rules.d/89-steamos-validate.rules"

validate_mount_image() {
  local img="$1"

  # Install udev guard BEFORE attaching loop — prevents udisks2 from
  # seeing the partitions and triggering an automount popup.
  mkdir -p /run/udev/rules.d
  cat >"$VALIDATE_UDEV_RULE" <<'EOF'
# steamos-validate — suppress udisks2 automount for all loop partitions
SUBSYSTEM=="block", KERNEL=="loop[0-9]*p*", ENV{UDISKS_IGNORE}="1", ENV{SYSTEMD_READY}="0"
EOF
  udevadm control --reload-rules
  log "Installed udev guard: $VALIDATE_UDEV_RULE"

  log "Attaching loop device: $img"
  VALIDATE_LOOP="$(losetup -f --show --partscan "$img")" \
    || die "Failed to attach loop device"
  log "  Loop: $VALIDATE_LOOP"
  udevadm settle --timeout=10

  log "Scanning partitions on $VALIDATE_LOOP"
  local part label
  for part in "$VALIDATE_LOOP"p*; do
    label="$(blkid -s PARTLABEL -o value "$part" 2>/dev/null)" || continue
    log "  $part: ${label:-<unknown>}"
    case "$label" in
      rootfs-A | rootfs) VALIDATE_ROOTFS="$part" ;;
      var-A | var) VALIDATE_VARPART="$part" ;;
    esac
  done

  [[ -n "$VALIDATE_ROOTFS" ]] || die "No rootfs partition found in $img"
  log "  rootfs: $VALIDATE_ROOTFS"
  log "  var:    ${VALIDATE_VARPART:-<not found>}"

  log "Mounting $VALIDATE_ROOTFS on $VALIDATE_MNT (read-only)"
  mount -o ro "$VALIDATE_ROOTFS" "$VALIDATE_MNT" \
    || die "Failed to mount rootfs"

  # Mount var if it exists as a separate partition.
  # Recovery images may have var baked into rootfs; skip if not found.
  if [[ -n "$VALIDATE_VARPART" ]]; then
    mkdir -p "$VALIDATE_MNT/var"
    log "Mounting $VALIDATE_VARPART on $VALIDATE_MNT/var (read-only)"
    mount -o ro "$VALIDATE_VARPART" "$VALIDATE_MNT/var" \
      || die "Failed to mount var"
  fi

  log "Mount complete"
}

validate_cleanup() {
  local _had_e=0
  [[ -o errexit ]] && _had_e=1
  set +e
  # Unmount var before rootfs-A (reverse order)
  if [[ -n "$VALIDATE_MNT" ]] && mountpoint -q "$VALIDATE_MNT/var" 2>/dev/null; then
    umount "$VALIDATE_MNT/var" 2>/dev/null
  fi
  if [[ -n "$VALIDATE_MNT" ]] && mountpoint -q "$VALIDATE_MNT" 2>/dev/null; then
    umount "$VALIDATE_MNT" 2>/dev/null
  fi
  if [[ -n "${VALIDATE_LOOP:-}" ]]; then
    losetup -d "$VALIDATE_LOOP" 2>/dev/null
  fi
  [[ -d "$VALIDATE_MNT" ]] && rmdir "$VALIDATE_MNT" 2>/dev/null
  # Remove udev guard and reload
  rm -f "$VALIDATE_UDEV_RULE" 2>/dev/null
  udevadm control --reload-rules 2>/dev/null
  [[ "$_had_e" -eq 1 ]] && set -e
}

backend_validate() {
  # shellcheck source=lib/library-loader.sh
  source "$BACKEND_DIR/library-loader.sh"
  load_workflow_libs "validate" "$BACKEND_DIR"

  # Source the validate pipeline
  # shellcheck source=lib/pipelines/pipeline_validate.sh
  source "$BACKEND_DIR/pipelines/pipeline_validate.sh"

  # Pass config via environment for the pipeline to read
  export VALIDATE_CONFIG="${CONFIG_FILE:-}"

  if [[ -n "$IMG" ]]; then
    # ── Offline image validation ──────────────────────────────────────
    [[ $EUID -eq 0 ]] || die "Image validation requires root (needed for loop/mount)."
    [[ -f "$IMG" ]] || die "Image not found: $IMG"
    IMG="$(readlink -f "$IMG")"

    VALIDATE_MNT="$(mktemp -d /tmp/steamos-validate.XXXXXX)"

    trap 'validate_cleanup' EXIT

    log "=== Mounts before ==="
    local _loop_state
    _loop_state="$(losetup -a 2>/dev/null)" || true
    if [[ -n "$_loop_state" ]]; then
      log "$_loop_state"
    else
      log "  (no active loop devices)"
    fi

    validate_mount_image "$IMG"

    export VALIDATE_ROOT="$VALIDATE_MNT"
    export MERGED="$VALIDATE_MNT"
    export OPT_MODE="chroot"
    export OPT_ROOT="$VALIDATE_MNT"

    log ""
    log "╔═══════════════════════════════════════════════════════════╗"
    log "║  VALIDATING OFFLINE IMAGE                                ║"
    log "╠═══════════════════════════════════════════════════════════╣"
    log "║  Image:    $IMG"
    log "║  Rootfs:   $VALIDATE_ROOTFS"
    log "║  Var:      ${VALIDATE_VARPART:-<not separate>}"
    log "║  Mount:    $VALIDATE_MNT"
    log "║  Mode:     chroot"
    log "╚═══════════════════════════════════════════════════════════╝"
    log ""
  else
    # ── Live system validation ────────────────────────────────────────
    export VALIDATE_ROOT="${VALIDATE_ROOT:-/}"

    log ""
    log "╔═══════════════════════════════════════════════════════════╗"
    log "║  VALIDATING LIVE SYSTEM                                  ║"
    log "╠═══════════════════════════════════════════════════════════╣"
    log "║  Root:     $VALIDATE_ROOT"
    log "║  Mode:     live"
    log "╚═══════════════════════════════════════════════════════════╝"
    log ""
  fi

  register_validate_pipeline
  local rc=0
  run_pipeline || rc=$?

  # Run cleanup before reporting final state
  if [[ -n "$VALIDATE_MNT" ]]; then
    validate_cleanup
    trap - EXIT
  fi

  if [[ -n "$VALIDATE_MNT" ]]; then
    log ""
    log "=== Mounts after ==="
    local _loop_after
    _loop_after="$(losetup -a 2>/dev/null)" || true
    if [[ -n "$_loop_after" ]]; then
      log "$_loop_after"
    else
      log "  (no active loop devices)"
    fi
  fi

  return "$rc"
}

backend_live() {
  [[ $EUID -eq 0 ]] || die "Live configuration requires root."

  [[ -n "$CONFIG_FILE" ]] || die "--config is required for live configuration"
  [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"

  # Validate config values (same checks as build)
  case "${DEFAULT_SESSION:-}" in
    "" | desktop | game) ;;
    *) die "Invalid session: $DEFAULT_SESSION" ;;
  esac

  case "${UPDATE_MODE:-selfheal}" in
    selfheal | hold | stock) ;;
    *) die "Invalid update mode: $UPDATE_MODE" ;;
  esac

  case "${BASE_OS_MODE:-additive}" in
    additive | upgrade) ;;
    *) die "Invalid base OS mode: $BASE_OS_MODE" ;;
  esac

  load_build_libs
  # shellcheck source=/dev/null
  source "$BACKEND_DIR/pipelines/pipeline_live.sh"

  register_live_pipeline
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

  # Detect available slots
  local -a options=()
  local slot_a="" slot_b=""

  while IFS=$'\t' read -r dev label; do
    case "$label" in
      rootfs-A) slot_a="$dev" ;;
      rootfs-B) slot_b="$dev" ;;
    esac
  done < <(lsblk -rno PATH,PARTLABEL 2>/dev/null | awk '$2 == "rootfs-A" || $2 == "rootfs-B"')

  [[ -n "$slot_a" ]] && options+=("A" "Root A ($slot_a)")
  [[ -n "$slot_b" ]] && options+=("B" "Root B ($slot_b)")

  if [[ ${#options[@]} -eq 0 ]]; then
    echo "No root partitions found." >&2
    exit 1
  fi

  local selected
  if command -v yad >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
    selected="$(yad --list \
      --title="Boot Selector" \
      --text="Select which root to boot into on next restart:" \
      --column="Slot" --column="Device" \
      --width=400 --height=200 \
      --selectable-rows \
      --print-column=1 \
      "${options[@]}" 2>/dev/null)" || exit 0
    selected="$(echo "$selected" | tr -d '|' | tr -d '\n' | xargs)"
  else
    local -a slot_labels=()
    [[ -n "$slot_a" ]] && slot_labels+=("A")
    [[ -n "$slot_b" ]] && slot_labels+=("B")

    echo ""
    echo "Reboot to which slot?"
    local idx=0
    [[ -n "$slot_a" ]] && echo "  $((++idx))) Root A ($slot_a)"
    [[ -n "$slot_b" ]] && echo "  $((++idx))) Root B ($slot_b)"
    read -rp "Choice: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#slot_labels[@]})); then
      selected="${slot_labels[$((choice - 1))]}"
    else
      exit 0
    fi
  fi

  local conf_file="/esp/SteamOS/conf/${selected}.conf"
  if [[ ! -f "$conf_file" ]]; then
    echo "Boot config not found: $conf_file" >&2
    exit 1
  fi

  local now
  now="$(date -u +%Y%m%d%H%M%S)"

  sed -i "s/^boot-requested-at:.*/boot-requested-at: $now/" "$conf_file" \
    || {
      echo "Failed to set boot-requested-at for $selected" >&2
      exit 1
    }

  # Clear the other slot
  local other="A"
  [[ "$selected" == "A" ]] && other="B"
  local other_conf="/esp/SteamOS/conf/${other}.conf"
  [[ -f "$other_conf" ]] \
    && sed -i "s/^boot-requested-at:.*/boot-requested-at: 0/" "$other_conf" 2>/dev/null

  echo "Boot slot set: $selected will boot on next restart"
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
  live)
    backend_live
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
