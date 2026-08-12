#!/bin/bash
#
# flash-image.sh — flash a SteamOS installer image to a USB stick.
#
# Thin zenity wrapper around lib/flash.sh.  For the YAD GUI, use gui.sh instead.
# Requires: zenity, lsblk, dd
#
# Usage:
#   ./flash-image.sh [image.img]
#
# If no image is given, auto-discovers .img files in common build locations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/flash.sh"

# Override die() for zenity dialogs
die() { zenity --error --no-wrap --text "$1" 2>/dev/null || echo "ERROR: $1" >&2; exit 1; }

# This script runs as the user for GUI dialogs, then elevates to root
# for the actual flash operation.  No need to run with sudo.
#
# Usage: flash-image.sh [IMAGE] [DEVICE]
#   If DEVICE is provided, skips device selection and confirmation (for gui.sh).

# ---- parse args ----
IMG="${1:-}"
TARGET_DEV="${2:-}"

# ---- find the image ----
if [[ -z "$IMG" ]]; then
  script_dir="$SCRIPT_DIR"
  search_dirs=("$script_dir" "$script_dir/.nvidia-usb-work" "/dev/shm/nvidia-build" "/home/deck/Downloads/.nvidia-usb-work")
  imgs=()
  for d in "${search_dirs[@]}"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r f; do
      imgs+=("$f")
    done < <(find "$d" -maxdepth 1 -name '*nvidia*usbinstall*.img' -type f 2>/dev/null)
  done
  if ((${#imgs[@]})); then
    mapfile -t imgs < <(printf '%s\n' "${imgs[@]}" | sort -u)
  fi
  case ${#imgs[@]} in
    0) die "No *nvidia*usbinstall*.img found. Pass the image path as an argument." ;;
    1) IMG="${imgs[0]}" ;;
    *)
      IMG="$(zenity --list --title="Select Image" --text="Multiple images found:" \
        --column="Image" --width=700 --height=300 "${imgs[@]}")" || exit 0
      [[ -n "$IMG" ]] || die "No image selected."
      ;;
  esac
fi
[[ -f "$IMG" ]] || die "Image not found: $IMG"
IMG_SIZE="$(du -h "$IMG" | cut -f1)"

# ---- scan for target devices (skip if device already provided) ----
if [[ -z "$TARGET_DEV" ]]; then
  DEVICE_LIST="$(flash_scan_devices)"
  [[ -n "$DEVICE_LIST" ]] || die "No target USB devices found.\n\nPlug in a USB stick and try again."

  # ---- build zenity list ----
  ROWS=()
  while IFS=$'\t' read -r dev size tran model tag; do
    type_label="Internal"
    [[ "$tag" == "[removable]" ]] && type_label="Removable"
    ROWS+=("$dev" "$size" "$model" "$tran" "$type_label")
  done <<< "$DEVICE_LIST"

  TARGET="$(zenity --list \
    --title="Flash SteamOS Image" \
    --text="Select the target USB device.\n\nImage: $(basename "$IMG") ($IMG_SIZE)\n\n<b>ALL DATA ON THE SELECTED DEVICE WILL BE DESTROYED.</b>" \
    --column="Device" --column="Size" --column="Model" --column="Bus" --column="Type" \
    --width=750 --height=400 \
    --print-column=1 \
    --selectable-rows \
    "${ROWS[@]}")" || exit 0

  [[ -n "$TARGET" && -b "$TARGET" ]] || die "No device selected."
  TARGET_DEV="$(echo "$TARGET" | tr -d ' ')"
fi

# ---- check if target is the system disk (skip if device already confirmed) ----
if [[ -z "${2:-}" ]] && flash_is_system_disk "$TARGET_DEV"; then
  zenity --warning --title="Warning: System Disk" \
    --text="<b>$TARGET_DEV appears to be the disk you are running from.</b>\n\nIf this is your recovery USB, the OS is loaded into RAM so flashing is safe - but if something goes wrong, you will need to recreate the recovery USB from another machine.\n\nIf this is your internal drive, <b>DO NOT proceed</b> unless you know exactly what you are doing." \
    --width=500 2>/dev/null || exit 0
fi

# ---- confirm (skip if device already provided) ----
if [[ -z "${2:-}" ]]; then
  TARGET_HR="$(flash_device_size "$TARGET_DEV")"
  TARGET_MODEL="$(lsblk -dno MODEL "$TARGET_DEV" 2>/dev/null | xargs)"
  TARGET_TRAN="$(lsblk -dno TRAN "$TARGET_DEV" 2>/dev/null | xargs)"
  TARGET_DESC="$TARGET_DEV"
  [[ -n "$TARGET_MODEL" ]] && TARGET_DESC+=" — $TARGET_MODEL"
  [[ -n "$TARGET_TRAN" ]] && TARGET_DESC+=" ($TARGET_TRAN)"
  TARGET_DESC+=" ($TARGET_HR)"

  CONFIRM="$(zenity --question \
    --title="Confirm Flash" \
    --text="<b>About to flash:</b>\n\n  $(basename "$IMG") ($IMG_SIZE)\n\n<b>To:</b>\n\n  $TARGET_DESC\n\n<b>This PERMANENTLY DESTROYS all data on $TARGET_DEV.</b>\n\nThis cannot be undone." \
    --ok-label="Flash" --cancel-label="Cancel" \
    --width=500 2>&1)" || exit 0
fi

# ---- elevate to root ----
# flash_write requires root.  Elevate via pkexec (GUI-friendly) or sudo.
# Save the original user and display so we can run zenity as them.
ORIGINAL_USER="${SUDO_USER:-$USER}"
ORIGINAL_DISPLAY="${DISPLAY:-}"
if [[ $EUID -ne 0 ]]; then
  # When called from gui.sh (device provided), pass both args through
  if [[ -n "${2:-}" ]]; then
    exec sudo bash "$0" "$1" "$2"
  elif command -v pkexec >/dev/null 2>&1; then
    exec pkexec bash "$0" "$IMG"
  elif command -v sudo >/dev/null 2>&1; then
    exec sudo bash "$0" "$IMG"
  else
    die "Flash requires root. Run with sudo or install pkexec."
  fi
fi

# ---- flash ----
echo "Flashing $(basename "$IMG") to $TARGET_DEV..."
echo ""

# If called from gui.sh (device provided), skip zenity — gui.sh handles UX.
# Otherwise, show zenity progress with cancel confirmation.
if [[ -n "${2:-}" ]]; then
  # Called from gui.sh — just flash, output to console/log
  flash_write "$IMG" "$TARGET_DEV"
  RC=$?
else
  # Standalone — show zenity progress as the GUI user
  flash_write "$IMG" "$TARGET_DEV" &
  FLASH_PID=$!

  ZENITY_TEXT="Flashing <b>$(basename "$IMG")</b> to <b>$TARGET_DEV</b>...\n\nDo NOT remove the USB stick."
  while true; do
    DISPLAY="$ORIGINAL_DISPLAY" sudo -u "$ORIGINAL_USER" zenity --progress --title="Flashing" \
      --text="$ZENITY_TEXT" \
      --pulsate --auto-close --width=400 \
      --ok-label="" --cancel-label="Cancel" 2>/dev/null &
    ZENITY_PID=$!

    # Wait for either the flash or zenity to exit
    while kill -0 "$FLASH_PID" 2>/dev/null && kill -0 "$ZENITY_PID" 2>/dev/null; do
      sleep 0.5
    done

    # If flash finished, we're done
    if ! kill -0 "$FLASH_PID" 2>/dev/null; then
      kill "$ZENITY_PID" 2>/dev/null || true
      wait "$ZENITY_PID" 2>/dev/null || true
      break
    fi

    # User clicked Cancel — show confirmation
    kill "$ZENITY_PID" 2>/dev/null || true
    wait "$ZENITY_PID" 2>/dev/null || true

    if DISPLAY="$ORIGINAL_DISPLAY" sudo -u "$ORIGINAL_USER" zenity --question --title="Cancel Flash?" \
      --text="<b>Are you sure you want to cancel?</b>\n\nThe flash is still in progress.\nCanceling may leave the USB stick in an unusable state." \
      --ok-label="Cancel Flash" --cancel-label="Continue Flashing" \
      --width=400 2>/dev/null; then
      # Confirmed cancel
      echo "Canceling flash..."
      kill "$FLASH_PID" 2>/dev/null || true
      wait "$FLASH_PID" 2>/dev/null || true
      DISPLAY="$ORIGINAL_DISPLAY" sudo -u "$ORIGINAL_USER" zenity --info --title="Flash Canceled" \
        --text="Flashing was canceled.\n\nThe USB stick may need to be reformatted before reuse." \
        --width=400 2>/dev/null || true
      exit 1
    fi
    # User clicked "Continue Flashing" — loop back to show progress
    echo "Continuing flash..."
  done

  wait "$FLASH_PID" 2>/dev/null
  RC=$?
fi

if [[ $RC -ne 0 ]]; then
  die "Flashing failed. Check the device and try again."
fi

echo "Flashing complete!"
echo ""
echo "Next steps:"
echo "  1. Remove the USB stick"
echo "  2. Insert into target machine"
echo "  3. Boot from USB (UEFI, Secure Boot off)"
echo "  4. Double-click 'Install SteamOS (NVIDIA) to Hard Drive'"
echo "  5. Pick your disk and install"

# ---- done (standalone only) ----
if [[ -z "${2:-}" ]]; then
  DISPLAY="$ORIGINAL_DISPLAY" sudo -u "$ORIGINAL_USER" zenity --info --title="Flash Complete" \
    --text="<b>Flashing complete!</b>\n\n$(basename "$IMG") → $TARGET_DEV\n\n<b>Next steps:</b>\n1. Remove the USB stick\n2. Insert into target machine\n3. Boot from USB (UEFI, Secure Boot off)\n4. Double-click 'Install SteamOS (NVIDIA) to Hard Drive'\n5. Pick your disk and install" \
    --width=500 2>/dev/null || true
fi
