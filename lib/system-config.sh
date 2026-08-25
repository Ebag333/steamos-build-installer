#!/bin/bash
#
# steamos-nvidia-installer — lib/system-config.sh
# System configuration stamping.
# Handles: update-branch, default-session
#
# These are simple "stamp a preference into a config file" operations.
# Sourced by the build backend and repatch — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/system-config.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Module Entry Point
# ---------------------------------------------------------------------------

apply_system_config() {
  local item="${1:?apply_system_config: missing item name}"
  local root="${2:?apply_system_config: missing root}"
  local value="${3:?apply_system_config: missing value}"

  case "$item" in
    update-branch) _apply_update_branch "$root" "$value" ;;
    default-session) _apply_default_session "$root" "$value" ;;
    *)
      warn "Unknown system config: $item"
      return 1
      ;;
  esac
}

verify_system_config() {
  local item="${1:?verify_system_config: missing item name}"
  local root="${2:?verify_system_config: missing root}"
  local expected="${3:-}"

  case "$item" in
    update-branch) _verify_update_branch "$root" "$expected" ;;
    default-session) _verify_default_session "$root" "$expected" ;;
    *)
      warn "Unknown system config: $item"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# update-branch
# ---------------------------------------------------------------------------
# Write the update branch to /etc/steamos-atomupd/preferences.conf.
#
# Args: $1 = root path, $2 = branch name (stable, beta, preview, etc.)

_apply_update_branch() {
  local root="${1:?_apply_update_branch: missing root}"
  local branch="${2:?_apply_update_branch: missing branch}"

  local prefs_dir="$root/etc/steamos-atomupd"
  local prefs="$prefs_dir/preferences.conf"

  # Read existing prefs to preserve other keys
  local variant=""
  if [[ -f "$prefs" ]]; then
    variant="$(sed -n 's/^Variant=//p' "$prefs" 2>/dev/null)"
  fi

  mkdir -p "$prefs_dir"
  cat >"$prefs" <<EOF
[Choices]
Variant=${variant:-steamdeck}
Branch=$branch
EOF
  chmod 644 "$prefs"
  log "  Wrote Branch=$branch to preferences.conf"
}

_verify_update_branch() {
  local root="${1:?_verify_update_branch: missing root}"
  local expected="${2:-stable}"
  local prefs="$root/etc/steamos-atomupd/preferences.conf"

  if [[ ! -f "$prefs" ]]; then
    return 1
  fi

  grep -q "^Branch=$expected$" "$prefs"
}

# ---------------------------------------------------------------------------
# default-session
# ---------------------------------------------------------------------------
# Configure the default desktop session.
# Writes state.toml and patches sddm.conf.
#
# Args: $1 = root path, $2 = session (desktop, game)

_apply_default_session() {
  local root="${1:?_apply_default_session: missing root}"
  local session="${2:?_apply_default_session: missing session}"

  # Set desktop session defaults via steamosctl (safe, no session switch)
  if _run_in_root_cfg "$root" 'command -v steamosctl >/dev/null 2>&1'; then
    _run_in_root_cfg "$root" "steamosctl set-default-login-mode desktop" 2>/dev/null \
      || warn "steamosctl set-default-login-mode failed (non-fatal)"
    _run_in_root_cfg "$root" "steamosctl set-default-desktop-session plasma.desktop" 2>/dev/null \
      || warn "steamosctl set-default-desktop-session failed (non-fatal)"
  fi

  # Fallback: write state.toml directly
  local state_toml="$root/home/deck/.config/steamos-manager/state.toml"
  mkdir -p "$(dirname "$state_toml")"
  cat >"$state_toml" <<'TOML'
[general]
default_login_mode = "desktop"
default_desktop_session = "plasma.desktop"
TOML
  chown -R 1000:1000 "$(dirname "$state_toml")" 2>/dev/null || true

  # sddm.conf — ensure Session= points to Plasma, not gamescope
  local sddm_conf="$root/etc/sddm.conf.d/steamos.conf"
  if [[ -f "$sddm_conf" ]]; then
    if grep -q '^Session=gamescope' "$sddm_conf"; then
      log "  Setting sddm session to plasma.desktop"
      sed -i 's/^Session=gamescope.*/Session=plasma.desktop/' "$sddm_conf"
    fi
  fi

  log "  Default session configured: $session"
}

_verify_default_session() {
  local root="${1:?_verify_default_session: missing root}"
  local expected="${2:-game}"

  local state_toml="$root/home/deck/.config/steamos-manager/state.toml"
  if [[ ! -f "$state_toml" ]]; then
    return 1
  fi

  grep -q "default_login_mode.*=.*\"$expected\"" "$state_toml"
}

# ---------------------------------------------------------------------------
# Context Helper
# ---------------------------------------------------------------------------
# Run a command in the target root (chroot or live).

_run_in_root_cfg() {
  local root="$1"
  shift
  if [[ "$root" == "/" ]]; then
    /bin/bash -c "$*"
  else
    chroot "$root" /bin/bash -c "$*"
  fi
}
