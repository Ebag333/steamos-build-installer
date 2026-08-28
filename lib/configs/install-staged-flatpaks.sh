#!/usr/bin/env bash
set -euo pipefail

STAGE_DIR="/usr/share/steamos-build/flatpaks"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/steamos-build/flatpaks"

mkdir -p "$STATE_DIR"

shopt -s nullglob

for bundle in "$STAGE_DIR"/*.flatpak; do
  name="$(basename "$bundle")"
  hash="$(sha256sum "$bundle" | awk '{print $1}')"
  marker="$STATE_DIR/$name.sha256"

  # This exact staged bundle has already been successfully processed.
  if [[ -f "$marker" ]] \
    && [[ "$(cat "$marker")" == "$hash" ]]; then
    continue
  fi

  echo "Installing staged Flatpak: $name"

  if flatpak install \
    --user \
    --noninteractive \
    --or-update \
    "$bundle"; then
    printf '%s\n' "$hash" >"$marker"
    echo "Installed staged Flatpak: $name"
  else
    echo "Failed to install staged Flatpak: $name" >&2
    exit 1
  fi
done
