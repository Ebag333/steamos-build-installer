#!/bin/bash
#
# install-amd-mesa.sh — Verify AMD Mesa/RADV packages inside the chroot.
# Package installation is handled by BUILD_DEPS in recipe.conf.
# Runs as INSTALL_CMD via the build-recipe framework.
#
set -euo pipefail

PACKAGES=(
  mesa
  lib32-mesa
  vulkan-radeon
  lib32-vulkan-radeon
)

echo "=== AMD Mesa package verification ==="

# ── Verify installation ─────────────────────────────────────────────────
echo "  Verifying installation"
ALL_OK=1
for pkg in "${PACKAGES[@]}"; do
  if pkg_info="$(pacman -Q "$pkg" 2>/dev/null)"; then
    version="$(echo "$pkg_info" | awk '{print $2}')"
    echo "    OK $pkg $version"
  else
    echo "    FAIL $pkg — not found after install" >&2
    ALL_OK=0
  fi
done

if [[ "$ALL_OK" -eq 0 ]]; then
  echo "ERROR: One or more AMD Mesa packages failed verification" >&2
  exit 1
fi

echo "=== AMD Mesa packages verified successfully ==="
