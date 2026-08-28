#!/bin/bash
#
# steamos-build-installer — lib/optimizations/oobe.sh
# OOBE (Out-of-Box Experience) optimizations.
# Handles: neutralize-oobe
#
# Sourced by entry.sh — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/optimizations/oobe.sh is a library — source it from entry.sh, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Module Entry Point
# ---------------------------------------------------------------------------
# Called by entry.sh to apply an OOBE optimization.
#
# Usage: apply_oobe_optimization ITEM
#   ITEM - Optimization name (neutralize-oobe)
#
# Returns 0 on success, 1 on failure.

apply_oobe_optimization() {
  local item="${1:?apply_oobe_optimization: missing item name}"

  case "$item" in
    neutralize-oobe)
      _apply_neutralize_oobe
      ;;
    *)
      warn "Unknown oobe optimization: $item"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Module Verify Entry Point
# ---------------------------------------------------------------------------
# Check whether an OOBE optimization is currently applied.
# Works in all contexts: chroot, live.
#
# Usage: verify_oobe_optimization ITEM
#   ITEM - Optimization name (neutralize-oobe)
#
# Returns 0 if applied (true), 1 if not applied (false).

verify_oobe_optimization() {
  local item="${1:?verify_oobe_optimization: missing item name}"

  case "$item" in
    neutralize-oobe)
      _verify_neutralize_oobe
      ;;
    *)
      warn "Unknown oobe optimization: $item"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# neutralize-oobe — Apply
# ---------------------------------------------------------------------------
# Neutralize the destructive OOBE Steam reset in steam-jupiter.
# The stock script runs `rm -rf --one-file-system "$STEAM_DIR" "$STEAM_LINKS"`
# which wipes user data on first boot.  We replace it with a no-op comment.
#
# Handles both argument orderings seen across SteamOS versions:
#   rm -rf --one-file-system "$STEAM_DIR" "$STEAM_LINKS"
#   rm -rf --one-file-system "$STEAM_LINKS" "$STEAM_DIR"
#
# Self-validates: after patching, verifies the destructive line is absent.
# If the line survived (whitespace change, restructure), returns failure
# so the caller can abort rather than shipping a silently unpatched image.
#
# Context handling:
#   - chroot/rebuild: Patch steam-jupiter in target rootfs
#   - live: Patch steam-jupiter on running system

_apply_neutralize_oobe() {
  local root
  root="$(get_root)"
  local jupiter="${root}/usr/bin/steam-jupiter"

  if [[ ! -f "$jupiter" ]]; then
    warn "steam-jupiter not found at ${jupiter#${root}} — cannot neutralize OOBE data wipe"
    return 1
  fi

  log "Patching steam-jupiter to remove OOBE data wipe"

  # Handle both argument orderings seen across SteamOS versions
  sed -i 's/rm -rf --one-file-system "\$STEAM_DIR" "\$STEAM_LINKS"/: # neutralized by steamos-build-installer/' "$jupiter"
  sed -i 's/rm -rf --one-file-system "\$STEAM_LINKS" "\$STEAM_DIR"/: # neutralized by steamos-build-installer/' "$jupiter"

  # Fail closed: if the destructive line survived (whitespace change,
  # restructure), return failure rather than shipping a silently
  # unpatched image.
  if grep -Eq 'rm -rf --one-file-system "\$STEAM_(DIR|LINKS)" "\$STEAM_(DIR|LINKS)"' "$jupiter"; then
    warn "Failed to neutralize destructive OOBE Steam reset in steam-jupiter"
    return 1
  fi

  log "steam-jupiter: destructive reset line confirmed absent"
  return 0
}

# ---------------------------------------------------------------------------
# neutralize-oobe — Verify
# ---------------------------------------------------------------------------
# Check whether the destructive OOBE Steam reset has been neutralized.
# Returns 0 (true) if the destructive line is absent, 1 (false) if present
# or if steam-jupiter is missing.
#
# Context handling:
#   - chroot/rebuild: Check steam-jupiter in target rootfs
#   - live: Check steam-jupiter on running system

_verify_neutralize_oobe() {
  local root
  root="$(get_root)"
  local jupiter="${root}/usr/bin/steam-jupiter"

  if [[ ! -f "$jupiter" ]]; then
    return 1
  fi

  if grep -Eq 'rm -rf --one-file-system "\$STEAM_(DIR|LINKS)" "\$STEAM_(DIR|LINKS)"' "$jupiter"; then
    return 1
  fi

  return 0
}
