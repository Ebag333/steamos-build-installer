#!/bin/bash
# One-click SteamOS (NVIDIA-patched) installer/upgrader. Picks an internal
# disk, then runs Valve's repair_device.sh which clones the running USB
# system onto it.
#   $1 = all    → full install: wipes the disk (default)
#   $1 = system → upgrade: reimages the OS partitions, KEEPS games & data
set -eu

MODE="${1:-all}"
case "$MODE" in
  all)
    TITLE="Install SteamOS (NVIDIA) to Hard Drive"
    PICK_TEXT="Select the disk to install SteamOS onto.\n\nEVERYTHING ON THE SELECTED DISK WILL BE ERASED."
    CONFIRM_LABEL="ERASE AND INSTALL"
    CONFIRM_TEXT_TPL="About to install SteamOS (NVIDIA-patched) onto:\n\n    %s\n\nThis PERMANENTLY DESTROYS everything on that disk.\nThe install takes several minutes. The machine powers off when done:\nremove the USB stick, then boot from %s."
    ;;
  system)
    TITLE="Upgrade SteamOS (NVIDIA) — keeps games & data"
    PICK_TEXT="Select the disk with the existing SteamOS installation to upgrade.\n\nThe OS partitions are reinstalled from this USB; the home partition\n(games, saves, Steam login) is NOT touched."
    CONFIRM_LABEL="UPGRADE"
    CONFIRM_TEXT_TPL="About to upgrade the SteamOS installation on:\n\n    %s\n\nGames and user data on that disk are preserved.\nOS customisations outside /home will be lost.\nThe machine powers off when done: remove the USB stick and boot."
    ;;
  *) echo "Usage: $0 [all|system]" >&2; exit 1 ;;
esac

_err_exit() { zenity --error --no-wrap --text "$1" 2>/dev/null || echo "ERROR: $1" >&2; exit 1; }

# Disk we're running from (the USB) — never offer it as a target.
# Fail closed: if we can't determine the source disk, refuse to proceed
# rather than risk offering the USB as an install target.
SRC_PART="$(findmnt -no SOURCE /)"
SRC_DISK="$(lsblk -no PKNAME "$SRC_PART" 2>/dev/null | head -1)"
if [[ -z "$SRC_DISK" ]]; then
  _err_exit "Cannot determine which disk contains the USB rootfs.\nRefusing to proceed — the USB might be offered as an install target."
fi

mapfile -t CANDIDATES < <(lsblk -dn -o NAME,SIZE,MODEL,TRAN,TYPE | \
  awk -v src="$SRC_DISK" '$NF=="disk" && $1!=src && $1 !~ /^(loop|zram|sr|nbd|ram)/ {NF--; print}')

[[ ${#CANDIDATES[@]} -gt 0 ]] || _err_exit "No target disk found.\nThis machine appears to have no internal drive (other than this USB)."

ROWS=()
for c in "${CANDIDATES[@]}"; do
  name="${c%% *}"; rest="${c#* }"
  ROWS+=(FALSE "/dev/$name" "$rest")
done

TARGET=$(zenity --list --radiolist --title "$TITLE" \
  --text "$PICK_TEXT" \
  --column "" --column "Disk" --column "Size / Model / Bus" \
  --width 640 --height 340 "${ROWS[@]}") || exit 0
[[ -n "$TARGET" && -b "$TARGET" ]] || _err_exit "No disk selected."

# Upgrade mode only makes sense on a disk that already has the SteamOS layout
if [[ "$MODE" == system ]]; then
  if ! lsblk -no PARTLABEL "$TARGET" 2>/dev/null | grep -qx "rootfs-A"; then
    _err_exit "No existing SteamOS installation found on $TARGET.\nUse \"Install SteamOS (NVIDIA) to Hard Drive\" for a fresh install."
  fi
fi

CONFIRM_TEXT="${CONFIRM_TEXT_TPL//%s/$TARGET}"
zenity --question --no-wrap --title "Final confirmation" --ok-label "$CONFIRM_LABEL" --cancel-label "Cancel" \
  --text "$CONFIRM_TEXT" || exit 0

# POWEROFF=1: end with a shutdown prompt so the user can pull the USB
# nvidia-install-run is the restricted sudo helper — only repair_device.sh.
exec sudo env STEAMOS_TARGET_DISK="$TARGET" POWEROFF=1 \
  /usr/local/bin/nvidia-install-run \
  "$(dirname "$(readlink -f "$0")")/repair_device.sh" "$MODE"
