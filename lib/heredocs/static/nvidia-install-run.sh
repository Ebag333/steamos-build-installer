#!/bin/bash
# Restricted sudo helper for the one-click installer.
# Only allows running repair_device.sh as root with the required env vars.
set -euo pipefail

SCRIPT="/home/deck/tools/repair_device.sh"

# Reject anything that isn't our installer script.
if [[ "${1:-}" != "$SCRIPT" ]]; then
  echo "nvidia-install-run: only $SCRIPT is permitted" >&2
  exit 1
fi

shift
exec "$SCRIPT" "$@"
