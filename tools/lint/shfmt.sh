#!/bin/bash
#
# Lint: shfmt
#
# Checks shell script formatting using shfmt.
# Reads style from .editorconfig (indent, variant, etc.).
#
# Usage:
#   tools/lint/shfmt.sh [--repo-root DIR] [--install VERSION] [--fix]
#
# Options:
#   --install VERSION  Download shfmt if not found (e.g. --install v3.13.1)
#   --fix              Auto-fix formatting in-place (default: check only)
#
# Requirements:
#   shfmt must be installed, or use --install to fetch it automatically.
#
# Exit codes:
#   0 — no violations
#   1 — violations found
#   2 — usage error / shfmt not found

set -euo pipefail

REPO_ROOT=""
INSTALL_VERSION=""
FIX_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)
      REPO_ROOT="${2:?--repo-root requires a path}"
      shift 2
      ;;
    --install)
      INSTALL_VERSION="${2:?--install requires a version (e.g. v3.13.1)}"
      shift 2
      ;;
    --fix)
      FIX_MODE=true
      shift
      ;;
    -h | --help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$REPO_ROOT" ]]; then
  REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fi

# Find or install shfmt
SHFMT="shfmt"
if ! command -v shfmt &>/dev/null; then
  if [[ -n "$INSTALL_VERSION" ]]; then
    SHFMT="/tmp/shfmt"
    if [[ ! -x "$SHFMT" ]]; then
      echo "Downloading shfmt $INSTALL_VERSION..."
      curl -fsSL \
        "https://github.com/mvdan/sh/releases/download/${INSTALL_VERSION}/shfmt_${INSTALL_VERSION}_linux_amd64" \
        -o "$SHFMT"
      chmod +x "$SHFMT"
    fi
  else
    echo "ERROR: shfmt not found. Install it or use --install VERSION:" >&2
    echo "  apt install shfmt         # Debian/Ubuntu" >&2
    echo "  pacman -S shfmt           # Arch" >&2
    echo "  brew install shfmt        # macOS" >&2
    echo "  $0 --install v3.13.1      # Auto-download" >&2
    exit 2
  fi
fi

echo "Running shfmt..."
if [[ "$FIX_MODE" == true ]]; then
  "$SHFMT" -w "$REPO_ROOT"
  echo "PASS: shfmt formatted"
else
  "$SHFMT" -d "$REPO_ROOT"
  echo "PASS: shfmt clean"
fi
