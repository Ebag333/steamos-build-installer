#!/bin/bash
#
# steamos-build-installer — lib/optimizations/system.sh
# System configuration optimizations.
# Handles: gamemode, disable-autologin, disable-automount
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
#   ITEM - Optimization name (gamemode, disable-autologin, disable-automount)
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
    disable-automount)
      _apply_disable_automount
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
  local ok=1

  log "Adding deck user to gamemode group"

  # Check if gamemode group exists
  if run_in_root getent group gamemode >/dev/null 2>&1; then
    if ! run_in_root usermod -aG gamemode deck; then
      warn "Failed to add deck to gamemode group (non-fatal, continuing)"
    fi
  else
    warn "gamemode group not found in image — skipping (non-fatal)"
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
# Usage: _sddm_disable_autologin ROOT
#   ROOT - Root filesystem path (e.g. "/" or "/tmp/image/rootfs")

_sddm_disable_autologin() {
  local root="${1:?_sddm_disable_autologin: missing root}"

  local sddm_confs
  sddm_confs="$(find "$root/etc" -path "*/sddm.conf.d/steamos.conf" \( -type f -o -type l \) 2>/dev/null)"

  if [[ -z "$sddm_confs" ]]; then
    # No steamos.conf found — check if sddm is installed
    local sddm_conf_dirs
    sddm_conf_dirs="$(find "$root/etc" -type d -name "sddm.conf.d" 2>/dev/null)"
    if [[ -n "$sddm_conf_dirs" ]]; then
      local new_conf="$root/etc/sddm.conf.d/steamos.conf"
      log "No steamos.conf found but sddm is installed — creating $new_conf with autologin disabled"
      if ! mkdir -p "$(dirname "$new_conf")"; then
        warn "Failed to create directory for $new_conf"
        return 1
      fi
      cat >"$new_conf" <<EOF
[Autologin]
User=
Relogin=false
Session=
EOF
      return 0
    else
      warn "No steamos.conf found and no sddm.conf.d directories — sddm not installed?"
      return 1
    fi
  fi

  local count
  count="$(echo "$sddm_confs" | wc -l)"
  log "Found $count steamos.conf file(s)"

  local changed=0

  while IFS= read -r sddm_conf; do
    # Clear User= to disable initial autologin
    if grep -q '^User=' "$sddm_conf"; then
      log "Disabling initial autologin (clearing User=) in $sddm_conf"
      if ! sed -i 's/^User=.*/User=/' "$sddm_conf"; then
        warn "Failed to clear User= in $sddm_conf"
      else
        changed=1
      fi
    fi

    # Set Relogin=false to prevent auto re-login after session exit
    if grep -q '^Relogin=true' "$sddm_conf"; then
      log "Disabling re-login (Relogin=false) in $sddm_conf"
      if ! sed -i 's/^Relogin=true/Relogin=false/' "$sddm_conf"; then
        warn "Failed to set Relogin=false in $sddm_conf"
      else
        changed=1
      fi
    fi

    # Clear Session= to prevent auto-starting a specific session
    if grep -q '^Session=' "$sddm_conf"; then
      log "Clearing Session= in $sddm_conf"
      if ! sed -i 's/^Session=.*/Session=/' "$sddm_conf"; then
        warn "Failed to clear Session= in $sddm_conf"
      else
        changed=1
      fi
    fi
  done <<<"$sddm_confs"

  if [[ $changed -eq 0 ]]; then
    log "Auto login already disabled"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# disable-automount
# ---------------------------------------------------------------------------
# Disable KDE automounting of unknown devices to prevent loop devices
# from being auto-mounted during builds.
#
# Usage: _apply_disable_automount

_apply_disable_automount() {
  local root
  root="$(get_root)"

  local automount_conf="$root/home/deck/.config/kded_device_automounterrc"

  if [[ ! -f "$automount_conf" ]]; then
    # File doesn't exist — create it with proper configuration
    log "Creating $automount_conf with automount disabled"
    if ! mkdir -p "$(dirname "$automount_conf")"; then
      warn "Failed to create directory for $automount_conf"
      return 1
    fi
    cat >"$automount_conf" <<EOF
[General]
AutomountUnknownDevices=false
EOF
    if [[ $? -ne 0 ]]; then
      warn "Failed to create $automount_conf"
      return 1
    fi
    if ! chown 1000:1000 "$automount_conf" 2>/dev/null; then
      warn "Failed to set ownership on $automount_conf"
      return 1
    fi
    return 0
  fi

  # File exists — modify it
  if grep -q '^\[General\]' "$automount_conf"; then
    # [General] section exists — check if setting is within [General] section
    local general_section
    general_section="$(sed -n '/^\[General\]/,/^\[/{ /^\[General\]/d; /^\[/d; p; }' "$automount_conf")"
    if echo "$general_section" | grep -q '^AutomountUnknownDevices='; then
      # Setting exists in [General] section — update it
      log "Setting AutomountUnknownDevices=false in $automount_conf"
      sed -i '/^\[General\]/,/^\[/{s/^AutomountUnknownDevices=.*/AutomountUnknownDevices=false/;}' "$automount_conf" || {
        warn "Failed to set AutomountUnknownDevices in $automount_conf"
        return 1
      }
    else
      # Setting doesn't exist in [General] section — add it after [General]
      log "Adding AutomountUnknownDevices=false to $automount_conf"
      sed -i '/^\[General\]/a AutomountUnknownDevices=false' "$automount_conf" || {
        warn "Failed to add AutomountUnknownDevices to $automount_conf"
        return 1
      }
    fi
  else
    # [General] section doesn't exist — append it
    log "Adding [General] section with AutomountUnknownDevices=false to $automount_conf"
    # Ensure trailing newline before appending
    if [[ -s "$automount_conf" ]] && [[ "$(tail -c 1 "$automount_conf" | wc -l)" -eq 0 ]]; then
      if ! printf '\n' >>"$automount_conf"; then
        warn "Failed to write trailing newline to $automount_conf"
        return 1
      fi
    fi
    cat >>"$automount_conf" <<EOF
[General]
AutomountUnknownDevices=false
EOF
    if [[ $? -ne 0 ]]; then
      warn "Failed to append [General] section to $automount_conf"
      return 1
    fi
  fi

  if ! chown 1000:1000 "$automount_conf" 2>/dev/null; then
    warn "Failed to set ownership on $automount_conf"
    return 1
  fi

  return 0
}

_apply_disable_autologin() {
  local root
  root="$(get_root)"
  _sddm_disable_autologin "$root"
}

# ---------------------------------------------------------------------------
# Module Verify Entry Point
# ---------------------------------------------------------------------------

verify_system_optimization() {
  local item="${1:?verify_system_optimization: missing item name}"

  case "$item" in
    gamemode) _verify_gamemode ;;
    disable-autologin) _verify_disable_autologin ;;
    disable-automount) _verify_disable_automount ;;
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

  local sddm_confs
  sddm_confs="$(find "$root/etc" -path "*/sddm.conf.d/steamos.conf" \( -type f -o -type l \) 2>/dev/null)"

  # No steamos.conf — check if sddm is installed
  if [[ -z "$sddm_confs" ]]; then
    local sddm_conf_dirs
    sddm_conf_dirs="$(find "$root/etc" -type d -name "sddm.conf.d" 2>/dev/null)"
    if [[ -n "$sddm_conf_dirs" ]]; then
      warn "  sddm installed but no steamos.conf found — autologin not explicitly disabled"
      return 1
    fi
    return 1
  fi

  local all_ok=1

  # All steamos.conf files must have autologin disabled
  while IFS= read -r sddm_conf; do
    local user_line relogin_line
    user_line="$(grep '^User=' "$sddm_conf" 2>/dev/null | head -1)"
    relogin_line="$(grep '^Relogin=' "$sddm_conf" 2>/dev/null | head -1)"

    local file_ok=1
    if [[ -n "$user_line" && "$user_line" != "User=" ]]; then
      file_ok=0
    fi
    if [[ "$relogin_line" == "Relogin=true" ]]; then
      file_ok=0
    fi

    if [[ "$file_ok" -eq 0 ]]; then
      warn "  Autologin not disabled in $sddm_conf:"
      [[ -n "$user_line" && "$user_line" != "User=" ]] && warn "    $user_line"
      [[ "$relogin_line" == "Relogin=true" ]] && warn "    $relogin_line"
      all_ok=0
    fi
  done <<<"$sddm_confs"

  return $((1 - all_ok))
}

_verify_disable_automount() {
  local root
  root="$(get_root)"

  local automount_conf="$root/home/deck/.config/kded_device_automounterrc"

  if [[ ! -f "$automount_conf" ]]; then
    warn "  $automount_conf not found"
    return 1
  fi

  if ! sed -n '/^\[General\]/,/^\[/p' "$automount_conf" | grep -q '^AutomountUnknownDevices=false'; then
    warn "  AutomountUnknownDevices=false not found in [General] section of $automount_conf"
    return 1
  fi

  return 0
}
