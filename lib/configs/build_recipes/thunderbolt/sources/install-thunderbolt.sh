#!/bin/bash
#
# install-thunderbolt.sh — Install Thunderbolt dock support inside the chroot.
# The bolt package is installed by BUILD_DEPS in recipe.conf.
# Runs as INSTALL_CMD via the build-recipe framework.
#
set -euo pipefail

echo "=== Thunderbolt dock support install ==="

# ── 1. Install PCI rescan script ───────────────────────────────────────
echo "  Installing thunderbolt-rescan.sh"
for src in /tmp/build/sources/thunderbolt-rescan.sh /tmp/build/sources/98-thunderbolt-rescan.rules; do
  if [[ ! -f "$src" ]]; then
    echo "ERROR: Source file $src not found — build pipeline may not have staged sources" >&2
    exit 1
  fi
done
if ! install -Dm755 /tmp/build/sources/thunderbolt-rescan.sh /usr/local/bin/thunderbolt-rescan.sh; then
  echo "ERROR: Failed to install thunderbolt-rescan.sh" >&2
  exit 1
fi
echo "    OK /usr/local/bin/thunderbolt-rescan.sh"

# ── 2. Install udev rules ──────────────────────────────────────────────
echo "  Installing 98-thunderbolt-rescan.rules"
if ! install -Dm644 /tmp/build/sources/98-thunderbolt-rescan.rules /etc/udev/rules.d/98-thunderbolt-rescan.rules; then
  echo "ERROR: Failed to install 98-thunderbolt-rescan.rules" >&2
  exit 1
fi
echo "    OK /etc/udev/rules.d/98-thunderbolt-rescan.rules"

# ── 3. Enable bolt.service ─────────────────────────────────────────────
echo "  Enabling bolt.service"
mkdir -p /etc/systemd/system/multi-user.target.wants
bolt_service="/usr/lib/systemd/system/bolt.service"
if [[ ! -f "$bolt_service" ]]; then
  echo "ERROR: $bolt_service not found — bolt package may be broken" >&2
  exit 1
fi
ln -sf "$bolt_service" /etc/systemd/system/multi-user.target.wants/bolt.service
echo "    OK /etc/systemd/system/multi-user.target.wants/bolt.service"

# ── 4. Verify all installed files ──────────────────────────────────────
echo "  Verifying installation"
ALL_OK=1
for f in \
  /usr/local/bin/thunderbolt-rescan.sh \
  /etc/udev/rules.d/98-thunderbolt-rescan.rules \
  /etc/systemd/system/multi-user.target.wants/bolt.service; do
  if [[ -e "$f" ]]; then
    echo "    OK $f"
  else
    echo "    FAIL $f — not found after install" >&2
    ALL_OK=0
  fi
done

if [[ "$ALL_OK" -eq 0 ]]; then
  echo "ERROR: One or more Thunderbolt files failed verification" >&2
  exit 1
fi

echo "=== Thunderbolt dock support installed successfully ==="
