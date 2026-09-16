#!/bin/bash
#
# install-intel-gpu.sh — Verify Intel GPU packages inside the chroot.
# Package installation is handled by BUILD_DEPS in recipe.conf.
# Runs as INSTALL_CMD via the build-recipe framework.
#
set -euo pipefail

PACKAGES=(
  intel-gmmlib
  intel-media-driver
  vulkan-intel
  lib32-vulkan-intel
)

echo "=== Intel GPU package verification ==="

# ── Verify installation ─────────────────────────────────────────────────
echo "  Verifying installation"
ALL_OK=1
for pkg in "${PACKAGES[@]}"; do
  if qout="$(pacman -Q "$pkg" 2>/dev/null)"; then
    version="${qout#* }"
    echo "    OK $pkg $version"
  else
    echo "    FAIL $pkg — not found after install" >&2
    ALL_OK=0
  fi
done

if [[ "$ALL_OK" -eq 0 ]]; then
  echo "ERROR: One or more Intel GPU packages failed verification" >&2
  exit 1
fi

echo "=== Intel GPU packages verified successfully ==="
