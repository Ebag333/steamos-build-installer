#!/bin/bash
#
# Install lint dependencies (shellcheck, shfmt).
# Detects the system package manager automatically.
#
# Usage:
#   tools/install_deps.sh
#
# Exit codes:
#   0 — all dependencies installed
#   1 — installation failed

set -euo pipefail

install_package() {
  local pkg="$1"
  if command -v pacman &>/dev/null; then
    sudo pacman -S --needed --noconfirm "$pkg"
  elif command -v apt-get &>/dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y -qq "$pkg"
  elif command -v brew &>/dev/null; then
    brew install "$pkg"
  else
    echo "ERROR: No supported package manager found (pacman, apt, brew)" >&2
    exit 1
  fi
}

echo "Installing lint dependencies..."
install_package shellcheck
install_package shfmt
echo "Done"
