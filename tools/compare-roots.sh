#!/bin/bash
#
# compare-roots.sh — compare configuration between SteamOS A/B root partitions.
#
# Usage: ./compare-roots.sh [file1] [file2] ...
#
# Without arguments: compares common configuration hotspots.
# With arguments: compares specific files relative to /etc.
#
# Examples:
#   ./compare-roots.sh                              # compare hotspots
#   ./compare-roots.sh mkinitcpio.conf              # compare one file
#   ./compare-roots.sh modprobe.d/99-nvidia-patch.conf  # compare specific config

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---- find rootfs partitions ----
_find_rootfs_parts() {
  local parts=()
  while IFS= read -r line; do
    local name partlabel
    name="$(echo "$line" | awk '{print $1}')"
    partlabel="$(echo "$line" | awk '{print $2}')"
    case "$partlabel" in
      rootfs-A | rootfs-B) parts+=("/dev/$name:$partlabel") ;;
    esac
  done < <(lsblk -dno NAME,PARTLABEL /dev/nvme[0-9]* 2>/dev/null)
  echo "${parts[@]}"
}

# ---- mount a partition read-only ----
_mount_ro() {
  local dev="$1" mnt="$2"
  mkdir -p "$mnt"
  mount -o ro "$dev" "$mnt" 2>/dev/null || return 1
}

# ---- compare a single file between roots ----
_compare_file() {
  local rel_path="$1"
  local a_path="$ROOTFS_A/$rel_path"
  local b_path="$ROOTFS_B/$rel_path"
  local a_exists=false b_exists=false

  [[ -f "$a_path" ]] && a_exists=true
  [[ -f "$b_path" ]] && b_exists=true

  if ! $a_exists && ! $b_exists; then
    echo -e "  ${YELLOW}SKIP${NC} $rel_path (not found on either)"
    return 0
  fi

  if $a_exists && ! $b_exists; then
    echo -e "  ${RED}ONLY-A${NC} $rel_path"
    return 0
  fi

  if ! $a_exists && $b_exists; then
    echo -e "  ${RED}ONLY-B${NC} $rel_path"
    return 0
  fi

  if diff -q "$a_path" "$b_path" >/dev/null 2>&1; then
    echo -e "  ${GREEN}SAME${NC} $rel_path"
  else
    echo -e "  ${RED}DIFF${NC} $rel_path"
    diff -u "$a_path" "$b_path" | head -20
    echo ""
  fi
}

# ---- main ----
echo -e "${CYAN}=== SteamOS A/B Root Comparison ===${NC}"
echo ""

# Find rootfs partitions
mapfile -t rootfs_parts < <(_find_rootfs_parts | tr ' ' '\n')

if [[ ${#rootfs_parts[@]} -lt 2 ]]; then
  echo -e "${RED}Error: Could not find both rootfs-A and rootfs-B partitions.${NC}"
  echo "Found: ${rootfs_parts[*]:-none}"
  exit 1
fi

# Parse partition info
PART_A="" PART_B="" LABEL_A="" LABEL_B=""
for entry in "${rootfs_parts[@]}"; do
  IFS=':' read -r dev label <<<"$entry"
  case "$label" in
    rootfs-A)
      PART_A="$dev"
      LABEL_A="$label"
      ;;
    rootfs-B)
      PART_B="$dev"
      LABEL_B="$label"
      ;;
  esac
done

echo -e "  A: $PART_A ($LABEL_A)"
echo -e "  B: $PART_B ($LABEL_B)"
echo ""

# Mount read-only
MNT_A="/tmp/compare-rootfs-a"
MNT_B="/tmp/compare-rootfs-b"

cleanup() { # lint-ignore: no-shadow
  umount "$MNT_A" 2>/dev/null || true
  umount "$MNT_B" 2>/dev/null || true
  rmdir "$MNT_A" "$MNT_B" 2>/dev/null || true
}
trap cleanup EXIT

echo "Mounting partitions read-only..."
_mount_ro "$PART_A" "$MNT_A" || {
  echo "Failed to mount A"
  exit 1
}
_mount_ro "$PART_B" "$MNT_B" || {
  echo "Failed to mount B"
  exit 1
}

ROOTFS_A="$MNT_A"
ROOTFS_B="$MNT_B"

# ---- compare files ----
if [[ $# -gt 0 ]]; then
  # Compare specific files
  for f in "$@"; do
    _compare_file "$f"
  done
else
  # Compare common hotspots
  echo -e "${CYAN}Comparing configuration hotspots:${NC}"
  echo ""

  _compare_file "etc/mkinitcpio.conf"
  _compare_file "etc/mkinitcpio.conf.d/99-steamos-build.conf"
  _compare_file "etc/mkinitcpio.conf.d/20-steamdeck.conf"
  _compare_file "etc/modprobe.d/99-nvidia-patch.conf"
  _compare_file "etc/modprobe.d/steamos-build.conf"
  _compare_file "etc/dracut.conf.d/99-steamos-build.conf"
  _compare_file "etc/dracut.conf.d/steamos-image-recipes.conf"
  _compare_file "etc/default/grub"
  _compare_file "etc/pacman.conf"
  _compare_file "etc/pacman.d/mirrorlist"
  _compare_file "etc/udev/rules.d/98-thunderbolt-rescan.rules"
  _compare_file "etc/udev/rules.d/99-steamos-tb-autoauth.rules"
  _compare_file "home/.steamos-build/lib/driver.conf"
  _compare_file "home/.steamos-build/lib/repatch.sh"
  _compare_file "usr/bin/steamos-update"
  _compare_file "etc/systemd/system/multi-user.target.wants/bolt.service"
  _compare_file "home/deck/.config/steamos-manager/state.toml"

  echo ""

  # Count differences
  total=0 diffs=0
  echo -e "${CYAN}Summary:${NC}"
  for f in etc/mkinitcpio.conf etc/mkinitcpio.conf.d/99-steamos-build.conf \
    etc/modprobe.d/99-nvidia-patch.conf etc/dracut.conf.d/99-steamos-build.conf \
    home/.steamos-build/lib/driver.conf; do
    total=$((total + 1))
    if [[ -f "$ROOTFS_A/$f" && -f "$ROOTFS_B/$f" ]]; then
      if ! diff -q "$ROOTFS_A/$f" "$ROOTFS_B/$f" >/dev/null 2>&1; then
        diffs=$((diffs + 1))
      fi
    elif [[ -f "$ROOTFS_A/$f" || -f "$ROOTFS_B/$f" ]]; then
      diffs=$((diffs + 1))
    fi
  done

  if [[ $diffs -eq 0 ]]; then
    echo -e "  ${GREEN}All key configuration files match.${NC}"
  else
    echo -e "  ${RED}$diffs/$total key configuration files differ.${NC}"
  fi
fi
