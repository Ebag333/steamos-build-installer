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

HAS_PERMS="no"
if [[ $EUID -eq 0 ]]; then
  HAS_PERMS="root"
elif command -v sudo >/dev/null 2>&1; then
  HAS_PERMS="sudo"
fi

MISSING_REQUIRED=()
MISSING_OPTIONAL=()

# Required tools -> package name
declare -A REQUIRED=(
  [awk]="gawk"
  [blkid]="util-linux"
  [btrfs]="btrfs-progs"
  [bzip2]="bzip2"
  [curl]="curl"
  [depmod]="kmod"
  [gzip]="gzip"
  [losetup]="util-linux"
  [pacman]="pacman"
  [partx]="util-linux"
  [pv]="pv"
  [python3]="python"
  [readelf]="binutils"
  [rsync]="rsync"
  [sed]="sed"
  [tar]="tar"
  [xz]="xz"
  [zstd]="zstd"
)

# Optional tools -> "package:description"
declare -A OPTIONAL=(
)

# ---- check phase ----
echo ""
echo -e "${CYAN}=== steamos-nvidia-installer dependency check ===${NC}"

# ---- WSL detection ----
if grep -qi microsoft /proc/version 2>/dev/null; then
  echo -e "${YELLOW}WARNING: WSL detected.${NC}"
  echo -e "${YELLOW}WSL lacks full kernel support needed for building:${NC}"
  echo "  - No real loop device support (losetup)"
  echo "  - No btrfs kernel module"
  echo "  - Limited systemd/udev support"
  echo ""
  echo -e "${YELLOW}The build will fail in WSL. Use one of these instead:${NC}"
  echo "  - Real Arch Linux (bare metal or VM)"
  echo "  - SteamOS recovery USB"
  echo "  - Docker with --privileged (partial support)"
  echo ""
  if [[ "$MODE" != "check-only" ]]; then
    read -rp "Continue anyway? [y/N]: " wsl_continue
    [[ "$wsl_continue" =~ ^[Yy] ]] || exit 1
  fi
fi

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

# Deduplicate package lists — filter empty lines so empty arrays stay empty.
mapfile -t REQUIRED_PKGS < <(printf '%s\n' "${MISSING_REQUIRED[@]}" | sort -u | grep -v '^$')
mapfile -t OPTIONAL_PKGS < <(printf '%s\n' "${MISSING_OPTIONAL[@]}" | sort -u | grep -v '^$')

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

# ---- required-only: no required deps means success ----
# Optional deps should never block the build or cause a nonzero exit.
# But in --install mode, we still want to install them.
if [[ ${#REQUIRED_PKGS[@]} -eq 0 && "$MODE" != "install" ]]; then
  echo -e "${GREEN}All required dependencies satisfied.${NC}"
  if [[ ${#OPTIONAL_PKGS[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Optional packages not installed: ${OPTIONAL_PKGS[*]}${NC}"
    echo -e "${YELLOW}Install manually if needed: sudo pacman -S ${OPTIONAL_PKGS[*]}${NC}"
  fi
  exit 0
fi

# ---- permission check ----
if [[ "$HAS_PERMS" == "root" ]]; then
  echo -e "${GREEN}Running as root — can install packages.${NC}"
elif [[ "$HAS_PERMS" == "sudo" ]]; then
  echo -e "${GREEN}User has sudo — can install packages.${NC}"
else
  echo -e "${YELLOW}Not root and no sudo access.${NC}"
  echo -e "${YELLOW}Cannot auto-install. Run as root or install manually:${NC}"
  echo "  sudo pacman -S ${REQUIRED_PKGS[*]}"
  exit 1
fi
echo ""

# ---- check-only mode: exit with error if required missing ----
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
