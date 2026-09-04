#!/bin/bash
#
# install-intel-gpu.sh — Install Intel GPU packages inside the chroot.
# Runs as INSTALL_CMD via the build-recipe framework.
#
set -euo pipefail

# ── 1. Define packages ──────────────────────────────────────────────────
PACKAGES=(
  intel-gmmlib
  intel-media-driver
  vulkan-intel
  lib32-vulkan-intel
)

echo "=== Intel GPU package install ==="

# ── 2. Separate already-installed from missing ───────────────────────────
INSTALL_LIST=()
ALREADY=()

for pkg in "${PACKAGES[@]}"; do
  if pacman -Q "$pkg" &>/dev/null; then
    ALREADY+=("$pkg")
  else
    INSTALL_LIST+=("$pkg")
  fi
done

if [[ ${#ALREADY[@]} -gt 0 ]]; then
  echo "  Already installed: ${ALREADY[*]}"
fi

# ── 3. Install missing packages ─────────────────────────────────────────
if [[ ${#INSTALL_LIST[@]} -gt 0 ]]; then
  echo "  Installing: ${INSTALL_LIST[*]}"
  # DB sync is handled by the pipeline before this script runs.
  if ! pacman -S --noconfirm "${INSTALL_LIST[@]}"; then
    echo "ERROR: Failed to install Intel GPU packages" >&2
    exit 1
  fi
else
  echo "  All Intel GPU packages already present"
fi

# ── 4. Verify installation ──────────────────────────────────────────────
echo "  Verifying installation"
ALL_OK=1
for pkg in "${PACKAGES[@]}"; do
  if pacman -Q "$pkg" &>/dev/null; then
    version="$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}')"
    echo "    OK $pkg $version"
  else
    echo "    FAIL $pkg — not found after install" >&2
    ALL_OK=0
  fi
done

if [[ "$ALL_OK" -ne 0 ]]; then
  echo "ERROR: One or more Intel GPU packages failed verification" >&2
  exit 1
fi

echo "=== Intel GPU packages installed successfully ==="
