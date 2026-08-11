#!/bin/bash
#
# gui.sh — YAD-based GUI wizard for steamos-nvidia-installer.
#
# Provides a unified interface for building and flashing SteamOS NVIDIA images.
# Detects existing images, collects build/flash options, and dispatches to
# the appropriate backend.
#
# Usage:
#   ./gui.sh
#
# Requires: yad, bash 4+, the lib/ directory from this project.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source libraries
source "$SCRIPT_DIR/lib/gui-helpers.sh"
source "$SCRIPT_DIR/lib/flash.sh"
source "$SCRIPT_DIR/lib/common.sh"

# ---- dependency check ----
gui_check_deps || exit 1

# ---- scan for existing images ----
mapfile -t FOUND_IMAGES < <(gui_scan_images "$SCRIPT_DIR")
HAS_IMAGES="no"
[[ ${#FOUND_IMAGES[@]} -gt 0 ]] && HAS_IMAGES="yes"

# ---- default config ----
IMG=""
DRIVER_SPEC="latest"
UPDATE_MODE="selfheal"
ADD_INSTALLER=1
TRIM_CUDA=0
BUILD_HW_SUPPORT=0
THUNDERBOLT=0
DEFAULT_SESSION=""  # "" = stock, "desktop" = boot to desktop
ROOTFS_SIZE=5120
SKIP_SIG=0
FIX_KEYRING=0
WORKDIR=""
WORKDIR_LOCATION="auto"  # auto | ram | disk
FLASH_IMG=""
FLASH_DEV=""

# ---- main loop ----
while true; do
  gui_mode_dialog "$HAS_IMAGES"

  case "$GUI_MODE" in

    # ================================================================ BUILD
    build)
      # Pre-fill source image if exactly one was found
      local_detected=""
      if [[ ${#FOUND_IMAGES[@]} -eq 1 ]]; then
        local_detected="${FOUND_IMAGES[0]}"
      fi

      gui_build_form "$SCRIPT_DIR" "$local_detected" || continue

      # Validate source image
      [[ -n "$IMG" && -f "$IMG" ]] || {
        gui_error "No source image selected or file not found."
        continue
      }

      gui_build_confirm || continue

      # Write config to workdir
      if [[ -z "$WORKDIR" ]]; then
        WORKDIR="$(dirname "$IMG")/.nvidia-usb-work"
      fi
      mkdir -p "$WORKDIR"
      CONF="$WORKDIR/steamos-nvidia.conf"
      gui_write_config "$CONF"

      # Launch build in background, show progress
      LOGFILE="$WORKDIR/build.log"
      sudo bash "$SCRIPT_DIR/steamos-nvidia-installer.sh" --config "$CONF" \
        > "$LOGFILE" 2>&1 &
      BUILD_PID=$!

      gui_progress_log "Building Image" "$LOGFILE" "$BUILD_PID"

      wait "$BUILD_PID" 2>/dev/null
      RC=$?
      if [[ $RC -eq 0 ]]; then
        OUT_IMG="$(grep -oP '(?<=DONE — ).*' "$LOGFILE" | tail -1)"
        gui_done "Build Complete" \
          "<b>Image built successfully!</b>\n\nOutput: $OUT_IMG\n\nYou can now flash it to a USB stick."
        # Add to found images for potential flash step
        FOUND_IMAGES+=("$OUT_IMG")
        HAS_IMAGES="yes"
      else
        gui_error "Build failed with exit code $RC.\n\nCheck the log: $LOGFILE"
      fi
      ;;

    # ================================================================ FLASH
    flash)
      gui_flash_select_image "$SCRIPT_DIR" "${FOUND_IMAGES[@]}" || continue
      gui_flash_select_device || continue
      gui_flash_confirm || continue

      # Flash with progress
      LOGFILE="/tmp/steamos-flash.log"
      flash_write "$FLASH_IMG" "$FLASH_DEV" > "$LOGFILE" 2>&1 &
      FLASH_PID=$!

      gui_progress_log "Flashing Image" "$LOGFILE" "$FLASH_PID"

      wait "$FLASH_PID" 2>/dev/null
      RC=$?
      if [[ $RC -eq 0 ]]; then
        gui_done "Flash Complete" \
          "<b>Flashing complete!</b>\n\n$FLASH_IMG -> $FLASH_DEV\n\n<b>Next steps:</b>\n1. Remove the USB stick\n2. Insert into target machine\n3. Boot from USB (UEFI, Secure Boot off)\n4. Double-click 'Install SteamOS (NVIDIA) to Hard Drive'\n5. Pick your disk and install"
      else
        gui_error "Flash failed with exit code $RC.\n\nCheck the log: $LOGFILE"
      fi
      ;;

    # ================================================================ QUIT
    quit|*)
      exit 0
      ;;
  esac
done
