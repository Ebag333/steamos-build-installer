#!/bin/bash
#
# check-deps.sh — verify host has all required tools for steamos-nvidia-installer.
# Run this before building to catch missing dependencies early.
#
# Usage:
#   ./check-deps.sh [--install | --check-only]
#
# Without flags: checks deps and offers to install missing ones.
# --install: auto-install without prompting.
# --check-only: just check, don't offer to install.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

MODE="interactive"  # interactive | install | check-only
[[ "${1:-}" == "--install" ]] && MODE="install"
[[ "${1:-}" == "--check-only" ]] && MODE="check-only"

# ---- permission check ----
can_install() {
  if [[ $EUID -eq 0 ]]; then
    return 0
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

HAS_PERMS="no"
if [[ $EUID -eq 0 ]]; then
  HAS_PERMS="root"
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  HAS_PERMS="sudo"
fi

MISSING_REQUIRED=()
MISSING_OPTIONAL=()

# Required tools -> package name
declare -A REQUIRED=(
  [losetup]="util-linux"
  [blkid]="util-linux"
  [btrfs]="btrfs-progs"
  [rsync]="rsync"
  [curl]="curl"
  [depmod]="kmod"
  [sed]="sed"
  [awk]="gawk"
  [tar]="tar"
  [zstd]="zstd"
  [pacman]="pacman"
  [python3]="python3"
  [readelf]="binutils"
)

# Optional tools -> "package:description"
declare -A OPTIONAL=(
  [bzip2]="bzip2:compressed .bz2 image support"
  [gzip]="gzip:compressed .gz image support"
  [xz]="xz:compressed .xz image support"
  [pv]="pv:flash progress bar"
  [yad]="yad:GUI wizard"
  [zenity]="zenity:CLI flash wrapper GUI"
)

# ---- check phase ----
echo ""
echo -e "${CYAN}=== steamos-nvidia-installer dependency check ===${NC}"
echo ""
echo -e "${CYAN}Required tools:${NC}"

for cmd in $(echo "${!REQUIRED[@]}" | tr ' ' '\n' | sort); do
  pkg="${REQUIRED[$cmd]}"
  if command -v "$cmd" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $cmd"
  else
    echo -e "  ${RED}✗${NC} $cmd ($pkg)"
    MISSING_REQUIRED+=("$pkg")
  fi
done

echo ""
echo -e "${CYAN}Optional tools:${NC}"

for cmd in $(echo "${!OPTIONAL[@]}" | tr ' ' '\n' | sort); do
  IFS=':' read -r pkg desc <<< "${OPTIONAL[$cmd]}"
  if command -v "$cmd" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $cmd ($desc)"
  else
    echo -e "  ${YELLOW}○${NC} $cmd ($desc)"
    MISSING_OPTIONAL+=("$pkg")
  fi
done

echo ""

# Deduplicate package lists
REQUIRED_PKGS=($(printf '%s\n' "${MISSING_REQUIRED[@]}" | sort -u))
OPTIONAL_PKGS=($(printf '%s\n' "${MISSING_OPTIONAL[@]}" | sort -u))

# ---- exit early if nothing missing ----
if [[ ${#REQUIRED_PKGS[@]} -eq 0 && ${#OPTIONAL_PKGS[@]} -eq 0 ]]; then
  echo -e "${GREEN}All dependencies satisfied. Ready to build.${NC}"
  exit 0
fi

# ---- show what's missing ----
if [[ ${#REQUIRED_PKGS[@]} -gt 0 ]]; then
  echo -e "${RED}Missing required: ${REQUIRED_PKGS[*]}${NC}"
fi
if [[ ${#OPTIONAL_PKGS[@]} -gt 0 ]]; then
  echo -e "${YELLOW}Missing optional: ${OPTIONAL_PKGS[*]}${NC}"
fi
echo ""

# ---- permission check ----
if [[ "$HAS_PERMS" == "root" ]]; then
  echo -e "${GREEN}Running as root — can install packages.${NC}"
elif [[ "$HAS_PERMS" == "sudo" ]]; then
  echo -e "${GREEN}User has sudo — can install packages.${NC}"
else
  echo -e "${YELLOW}Not root and no sudo access.${NC}"
  if [[ ${#REQUIRED_PKGS[@]} -gt 0 || ${#OPTIONAL_PKGS[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Cannot auto-install. Run as root or install manually:${NC}"
    echo "  sudo pacman -S ${REQUIRED_PKGS[*]}"
    exit 1
  fi
fi
echo ""

# ---- check-only mode: exit with error ----
if [[ "$MODE" == "check-only" ]]; then
  exit ${#REQUIRED_PKGS[@]}
fi

# ---- install mode: skip prompt ----
if [[ "$MODE" == "install" ]]; then
  TO_INSTALL=("${REQUIRED_PKGS[@]}" "${OPTIONAL_PKGS[@]}")
  echo "Installing: ${TO_INSTALL[*]}"
  if [[ "$HAS_PERMS" == "root" ]]; then
    pacman -S --noconfirm "${TO_INSTALL[@]}"
  elif [[ "$HAS_PERMS" == "sudo" ]]; then
    sudo pacman -S --noconfirm "${TO_INSTALL[@]}"
  else
    echo -e "${RED}Cannot install — no root/sudo access.${NC}"
    exit 1
  fi
  echo -e "${GREEN}Done.${NC}"
  exit 0
fi

# ---- interactive mode: ask user ----
echo -e "${CYAN}What would you like to install?${NC}"
echo ""
echo "  1) Yes (all)       — install required + optional"
echo "  2) Yes (required)  — install required only"
echo "  3) No              — exit without installing"
echo ""
read -rp "Choice [1/2/3]: " choice

case "$choice" in
  1)
    TO_INSTALL=("${REQUIRED_PKGS[@]}" "${OPTIONAL_PKGS[@]}")
    ;;
  2)
    TO_INSTALL=("${REQUIRED_PKGS[@]}")
    ;;
  *)
    echo "Skipping install. Install manually with:"
    echo "  sudo pacman -S ${REQUIRED_PKGS[*]}"
    exit 1
    ;;
esac

echo ""
echo "Installing: ${TO_INSTALL[*]}"
if [[ "$HAS_PERMS" == "root" ]]; then
  pacman -S --noconfirm "${TO_INSTALL[@]}"
elif [[ "$HAS_PERMS" == "sudo" ]]; then
  sudo pacman -S --noconfirm "${TO_INSTALL[@]}"
else
  echo -e "${RED}Cannot install — no root/sudo access.${NC}"
  exit 1
fi
echo ""
echo -e "${GREEN}Done. Run ./check-deps.sh again to verify.${NC}"