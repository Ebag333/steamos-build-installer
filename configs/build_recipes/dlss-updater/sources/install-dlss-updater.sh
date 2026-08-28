#!/bin/bash
#
# install-dlss-updater.sh — Download and stage DLSS Updater flatpak.
# Runs on the host (not in chroot). Stages the flatpak for first-boot
# installation via systemd user service.
#
# Usage: install-dlss-updater.sh ROOT
#   ROOT: target rootfs mount point (e.g. /dev/shm/nvidia-build/mnt)
#
set -euo pipefail

ROOT="${1:?install-dlss-updater.sh: missing root path}"
REPO="Recol/DLSS-Updater"
STAGE_DIR="$ROOT/usr/share/steamos-build/flatpaks"
SERVICE_DIR="$ROOT/etc/systemd/user"
WANTS_DIR="$ROOT/etc/systemd/user/default.target.wants"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "=== DLSS Updater flatpak install ==="

# ── 1. Query GitHub API for latest release ───────────────────────────────
echo "  Querying latest release from $REPO"
URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
  | grep -oE '"browser_download_url": *"[^"]+\.flatpak"' \
  | head -1 | cut -d'"' -f4)"

if [[ -z "$URL" ]]; then
  echo "ERROR: No flatpak release found for $REPO" >&2
  exit 1
fi

FILE="${URL##*/}"
VERSION="$(echo "$FILE" | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")"
echo "  Version: $VERSION"
echo "  URL: $URL"

# ── 2. Download ──────────────────────────────────────────────────────────
TMP="/tmp/$FILE"
echo "  Downloading $FILE"
curl -fSL "$URL" -o "$TMP" || {
  echo "ERROR: Failed to download $URL" >&2
  exit 1
}

SHA="$(sha256sum "$TMP" | awk '{print $1}')"
echo "  SHA256: $SHA"

# ── 3. Stage flatpak ─────────────────────────────────────────────────────
echo "  Staging to $STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp "$TMP" "$STAGE_DIR/dlss-updater.flatpak"
rm -f "$TMP"

# ── 4. Install systemd service ───────────────────────────────────────────
echo "  Installing systemd user service"
mkdir -p "$SERVICE_DIR" "$WANTS_DIR"

if [[ -f "$SCRIPT_DIR/lib/configs/steamos-build-flatpak-install.service" ]]; then
  cp "$SCRIPT_DIR/lib/configs/steamos-build-flatpak-install.service" "$SERVICE_DIR/"
fi

if [[ -f "$SCRIPT_DIR/lib/configs/install-staged-flatpaks.sh" ]]; then
  install -m 755 "$SCRIPT_DIR/lib/configs/install-staged-flatpaks.sh" "$ROOT/usr/lib/steamos-build/install-staged-flatpaks"
fi

ln -sf /etc/systemd/user/steamos-build-flatpak-install.service \
  "$WANTS_DIR/steamos-build-flatpak-install.service"

# ── 5. Write stamp ───────────────────────────────────────────────────────
STAMP_DIR="$ROOT/var/lib/steamos-build/builds/dlss-updater"
mkdir -p "$STAMP_DIR"
cat >"$STAMP_DIR/build.stamp" <<STAMP
driver=dlss-updater
version=$VERSION
installed_sha=$SHA
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STAMP

echo "=== DLSS Updater $VERSION staged successfully ==="
