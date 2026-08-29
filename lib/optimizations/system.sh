#!/bin/bash
#
# steamos-build-installer — lib/optimizations/system.sh
# System configuration optimizations.
# Handles: gamemode, disable-autologin
#
# Sourced by entry.sh — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/optimizations/system.sh is a library — source it from entry.sh, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Module Entry Point
# ---------------------------------------------------------------------------
# Called by entry.sh to apply a system optimization.
#
# Usage: apply_system_optimization ITEM
#   ITEM - Optimization name (gamemode, disable-autologin)
#
# Returns 0 on success, 1 on failure.

apply_system_optimization() {
  local item="${1:?apply_system_optimization: missing item name}"

  case "$item" in
    gamemode)
      _apply_gamemode
      ;;
    disable-autologin)
      _apply_disable_autologin
      ;;
    *)
      warn "Unknown system optimization: $item"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# gamemode
# ---------------------------------------------------------------------------
# Add deck user to gamemode group and enable the gamemoded user service.
# This allows games to request CPU performance switching via D-Bus.
#
# Context handling:
#   - chroot/rebuild: Modify target rootfs
#   - live: Modify running system

_apply_gamemode() {
  local root
  root="$(get_root)"
  local ok=1

  log "Adding deck user to gamemode group"

  # Check if gamemode group exists
  if run_in_root getent group gamemode >/dev/null 2>&1; then
    if ! run_in_root usermod -aG gamemode deck; then
      warn "Failed to add deck to gamemode group (non-fatal)"
      ok=0
    fi
  else
    warn "gamemode group not found in image — skipping"
    ok=0
  fi

  log "Enabling gamemoded user service"

  # Enable gamemoded user service
  create_symlink "/usr/lib/systemd/user/gamemoded.service" \
    "/etc/systemd/user/graphical-session.target.wants/gamemoded.service" || ok=0

  return $((1 - ok))
}

# ---------------------------------------------------------------------------
# disable-autologin
# ---------------------------------------------------------------------------
# Disable automatic login by clearing User= from [Autologin] in sddm.conf.
# Without a User= value, SDDM shows the login screen instead of auto-logging in.
# Also sets Relogin=false to prevent auto re-login after session exit.
#
# Usage: sddm_disable_autologin ROOT
#   ROOT - Root filesystem path (e.g. "/" or "/tmp/image/rootfs")

sddm_disable_autologin() {
  local root="${1:?sddm_disable_autologin: missing root}"
  local sddm_conf="${root}/etc/sddm.conf.d/steamos.conf"

  if [[ ! -f "$sddm_conf" ]]; then
    warn "sddm.conf not found — cannot disable auto login"
    return 1
  fi

  local changed=0

  # Clear User= to disable initial autologin
  if grep -q '^User=' "$sddm_conf"; then
    log "Disabling initial autologin (clearing User=)"
    sed -i 's/^User=.*/User=/' "$sddm_conf"
    changed=1
  fi

  # Set Relogin=false to prevent auto re-login after session exit
  if grep -q '^Relogin=true' "$sddm_conf"; then
    log "Disabling re-login (Relogin=false)"
    sed -i 's/^Relogin=true/Relogin=false/' "$sddm_conf"
    changed=1
  fi

  if [[ $changed -eq 0 ]]; then
    log "Auto login already disabled"
  fi

  return 0
}

_apply_disable_autologin() {
  local root
  root="$(get_root)"
  sddm_disable_autologin "$root"
}

# ---------------------------------------------------------------------------
# Module Verify Entry Point
# ---------------------------------------------------------------------------

verify_system_optimization() {
  local item="${1:?verify_system_optimization: missing item name}"

  case "$item" in
    gamemode) _verify_gamemode ;;
    disable-autologin) _verify_disable_autologin ;;
    *)
      warn "Unknown system optimization: $item"
      return 1
      ;;
  esac
}

_verify_gamemode() {
  local root
  root="$(get_root)"
  run_in_root id deck 2>/dev/null | grep -q gamemode || return 1
  [[ -L "${root}/etc/systemd/user/graphical-session.target.wants/gamemoded.service" ]]
}

_verify_disable_autologin() {
  local root
  root="$(get_root)"
  local sddm_conf="${root}/etc/sddm.conf.d/steamos.conf"
  [[ -f "$sddm_conf" ]] || return 1
  # User= must be empty (no initial autologin) and Relogin must not be true
  grep -q '^User=$' "$sddm_conf" && ! grep -q '^Relogin=true' "$sddm_conf"
}
