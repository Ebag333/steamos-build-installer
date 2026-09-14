#!/bin/bash
#
# check-deps.sh — verify host has all required tools for steamos-build-installer.
# Run this before building to catch missing dependencies early.
#
# Usage:
#   ./check-deps.sh [--install | --check-only]
#
# Without flags: checks deps and offers to install missing ones.
# --install: auto-install without prompting.
# --check-only: just check, don't offer to install.

set -euo pipefail

# Source structured logging library.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logging.sh
source "$SCRIPT_DIR/logging.sh" 2>/dev/null || {
  # Fallback shim if logging.sh is unavailable.
  log_info() { # lint-ignore: no-shadow
    printf '[check-deps] INFO: %s\n' "${3:-}" >&2
  }
  log_notice() { # lint-ignore: no-shadow
    printf '[check-deps] NOTICE: %s\n' "${3:-}" >&2
  }
  log_warn() { # lint-ignore: no-shadow
    printf '[check-deps] WARN: %s\n' "${3:-}" >&2
  }
  log_error() { # lint-ignore: no-shadow
    printf '[check-deps] ERROR: %s\n' "${3:-}" >&2
  }
  log_die() { # lint-ignore: no-shadow
    printf '[check-deps] ERROR: %s\n' "${3:-}" >&2
    exit 1
  }
}

# Initialize logging (console-only, no log file for this standalone script).
log_init --console-level info --no-color 2>/dev/null || true

# Inline pacman install (standalone script, doesn't need full library)
_pacman_install() {
  if [[ $EUID -eq 0 ]]; then
    pacman --noconfirm --needed -S "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo pacman --noconfirm --needed -S "$@"
  else
    log_error deps no-perms "Cannot install — no root/sudo access."
    exit 1
  fi
}

MODE="interactive" # interactive | install | check-only
case "${1:-}" in
  --install) MODE="install" ;;
  --check-only) MODE="check-only" ;;
  "") ;; # no argument, keep default
  *)
    log_error args arg-error "Unknown option: $1"
    log_error args arg-error "Usage: $0 [--install | --check-only]"
    exit 1
    ;;
esac

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
  [lspci]="pciutils"
  [pacman]="pacman"
  [pactree]="pacman-contrib"
  [partx]="util-linux"
  [pv]="pv"
  [python3]="python"
  [readelf]="binutils"
  [rsync]="rsync"
  [sed]="sed"
  [sgdisk]="gptfdisk"
  [tar]="tar"
  [xz]="xz"
  [yad]="yad"
  [zstd]="zstd"
)

# Optional tools -> "package:description"
declare -A OPTIONAL=(
)

# ---- check phase ----
log_notice deps start "steamos-build-installer dependency check"

# ---- WSL detection ----
if grep -qi microsoft /proc/version 2>/dev/null; then
  log_warn deps wsl-detected "WSL detected."
  log_warn deps wsl-limits "WSL lacks full kernel support needed for building:"
  log_warn deps wsl-detail "  - No real loop device support (losetup)"
  log_warn deps wsl-detail "  - No btrfs kernel module"
  log_warn deps wsl-detail "  - Limited systemd/udev support"
  log_warn deps wsl-alternatives "The build will fail in WSL. Use one of these instead:"
  log_warn deps wsl-alternatives "  - Real Arch Linux (bare metal or VM)"
  log_warn deps wsl-alternatives "  - SteamOS recovery USB"
  log_warn deps wsl-alternatives "  - Docker with --privileged (partial support)"
  if [[ "$MODE" != "check-only" ]]; then
    read -rp "Continue anyway? [y/N]: " wsl_continue || {
      echo "Aborted."
      exit 1
    }
    [[ "$wsl_continue" =~ ^[Yy] ]] || exit 1
  fi
fi

REQUIRED_TOTAL=${#REQUIRED[@]}
REQUIRED_PASSED=0

while IFS= read -r cmd; do
  pkg="${REQUIRED[$cmd]}"
  if command -v "$cmd" >/dev/null 2>&1; then
    ((++REQUIRED_PASSED))
  else
    log_error deps missing "$cmd ($pkg)"
    MISSING_REQUIRED+=("$pkg")
  fi
done < <(printf '%s\n' "${!REQUIRED[@]}" | sort)

OPTIONAL_TOTAL=${#OPTIONAL[@]}
OPTIONAL_PASSED=0

if [[ ${#OPTIONAL[@]} -gt 0 ]]; then
  while IFS= read -r cmd; do
    IFS=':' read -r pkg desc <<<"${OPTIONAL[$cmd]}"
    if command -v "$cmd" >/dev/null 2>&1; then
      ((++OPTIONAL_PASSED))
    else
      log_warn deps missing-optional "$cmd ($desc)"
      MISSING_OPTIONAL+=("$pkg")
    fi
  done < <(printf '%s\n' "${!OPTIONAL[@]}" | sort)
fi

# ---- summary ----
if [[ ${#MISSING_REQUIRED[@]} -eq 0 ]]; then
  log_info deps summary "Dependency check: ${REQUIRED_PASSED}/${REQUIRED_TOTAL} required tools present"
else
  log_error deps summary "Dependency check failed: ${REQUIRED_PASSED}/${REQUIRED_TOTAL} required tools present"
fi

if [[ ${#OPTIONAL[@]} -gt 0 ]]; then
  if [[ ${#MISSING_OPTIONAL[@]} -eq 0 ]]; then
    log_info deps summary "Optional check: ${OPTIONAL_PASSED}/${OPTIONAL_TOTAL} optional tools present"
  else
    log_warn deps summary "Optional check: ${OPTIONAL_PASSED}/${OPTIONAL_TOTAL} optional tools present"
  fi
fi

# Deduplicate package lists — filter empty lines so empty arrays stay empty.
mapfile -t REQUIRED_PKGS < <(printf '%s\n' "${MISSING_REQUIRED[@]}" | sort -u | awk 'NF')
mapfile -t OPTIONAL_PKGS < <(printf '%s\n' "${MISSING_OPTIONAL[@]}" | sort -u | awk 'NF')

# ---- exit early if nothing missing ----
if [[ ${#REQUIRED_PKGS[@]} -eq 0 && ${#OPTIONAL_PKGS[@]} -eq 0 ]]; then
  log_info deps all-present "All dependencies satisfied. Ready to build."
  exit 0
fi

# ---- show what's missing ----
if [[ ${#REQUIRED_PKGS[@]} -gt 0 ]]; then
  log_error deps missing-required "Missing required: ${REQUIRED_PKGS[*]}"
fi
if [[ ${#OPTIONAL_PKGS[@]} -gt 0 ]]; then
  log_warn deps missing-optional "Missing optional: ${OPTIONAL_PKGS[*]}"
fi

# ---- required-only: no required deps means success ----
# Optional deps should never block the build or cause a nonzero exit.
# But in --install mode, we still want to install them.
if [[ ${#REQUIRED_PKGS[@]} -eq 0 && "$MODE" != "install" ]]; then
  log_info deps required-ok "All required dependencies satisfied."
  if [[ ${#OPTIONAL_PKGS[@]} -gt 0 ]]; then
    log_warn deps optional-skipped "Optional packages not installed: ${OPTIONAL_PKGS[*]}"
    log_warn deps optional-install-hint "Install manually if needed: sudo pacman -S ${OPTIONAL_PKGS[*]}"
  fi
  exit 0
fi

# ---- permission check ----
if [[ "$HAS_PERMS" == "root" ]]; then
  log_info deps perms-ok "Running as root — can install packages."
elif [[ "$HAS_PERMS" == "sudo" ]]; then
  log_info deps perms-ok "User has sudo — can install packages."
else
  log_warn deps no-perms "Not root and no sudo access."
  log_warn deps no-perms "Cannot auto-install. Run as root or install manually:"
  log_warn deps no-perms "  sudo pacman -S ${REQUIRED_PKGS[*]}"
  exit 1
fi

# ---- check-only mode: exit with error if required missing ----
if [[ "$MODE" == "check-only" ]]; then
  log_error deps check-failed "Dependency check failed. Install missing packages and re-run."
  exit 1
fi

# ---- install mode: skip prompt ----
if [[ "$MODE" == "install" ]]; then
  TO_INSTALL=("${REQUIRED_PKGS[@]}" "${OPTIONAL_PKGS[@]}")
  log_info deps installing "Installing: ${TO_INSTALL[*]}"
  _pacman_install "${TO_INSTALL[@]}"
  # shellcheck disable=SC1010  # "done" is a log category, not a keyword
  log_info deps done "Done."
  exit 0
fi

# ---- interactive mode: ask user ----
echo "What would you like to install?"
echo ""
echo "  1) Yes (all)       — install required + optional"
echo "  2) Yes (required)  — install required only"
echo "  3) No              — exit without installing"
echo ""
read -rp "Choice [1/2/3]: " choice || {
  echo "Aborted."
  exit 1
}

case "$choice" in
  1)
    TO_INSTALL=("${REQUIRED_PKGS[@]}" "${OPTIONAL_PKGS[@]}")
    ;;
  2)
    TO_INSTALL=("${REQUIRED_PKGS[@]}")
    ;;
  *)
    log_warn deps skipped "Skipping install. Install manually with:"
    log_warn deps skipped "  sudo pacman -S ${REQUIRED_PKGS[*]}"
    exit 1
    ;;
esac

log_info deps installing "Installing: ${TO_INSTALL[*]}"
_pacman_install "${TO_INSTALL[@]}"
# shellcheck disable=SC1010  # "done" is a log category, not a keyword
log_info deps done "Done. Run ./check-deps.sh again to verify."
