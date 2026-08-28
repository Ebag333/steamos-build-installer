#!/bin/bash
#
# steamos-build-installer — lib/system-config.sh
# System configuration stamping.
# Handles: variant, update-branch, default-session
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
    variant) _apply_variant "$root" "$value" ;;
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
    variant) _verify_variant "$root" "$expected" ;;
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
# Write the update branch to manifest.json in both lib paths.
#
# Args: $1 = root path, $2 = branch name (stable, beta, preview, etc.)

_apply_update_branch() {
  local root="${1:?_apply_update_branch: missing root}"
  local branch="${2:?_apply_update_branch: missing branch}"

  # ── 1) manifest.json (both lib paths) ────────────────────────────────────
  local manifest_path
  for manifest_path in /usr/lib/steamos-atomupd/manifest.json /usr/lib64/steamos-atomupd/manifest.json; do
    local manifest="$root$manifest_path"
    if [[ -f "$manifest" ]]; then
      sed -i "s/\"default_update_branch\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"default_update_branch\": \"$branch\"/" "$manifest"
      log "  Set default_update_branch=$branch in $manifest_path"
    else
      warn "  $manifest_path not found — skipping"
    fi
  done

  # ── 2) os-release STEAMOS_DEFAULT_UPDATE_BRANCH ─────────────────────────
  local os_release="$root/etc/os-release"
  if [[ -f "$os_release" ]]; then
    if grep -q "^STEAMOS_DEFAULT_UPDATE_BRANCH=" "$os_release"; then
      sed -i "s/^STEAMOS_DEFAULT_UPDATE_BRANCH=.*/STEAMOS_DEFAULT_UPDATE_BRANCH=$branch/" "$os_release"
    else
      echo "STEAMOS_DEFAULT_UPDATE_BRANCH=$branch" >>"$os_release"
    fi
    log "  Set STEAMOS_DEFAULT_UPDATE_BRANCH=$branch in /etc/os-release"
  else
    warn "  /etc/os-release not found — skipping"
  fi
}

# ---------------------------------------------------------------------------
# variant
# ---------------------------------------------------------------------------
# Write the OS variant to all relevant config files in the target rootfs
# and optionally neutralize the destructive OOBE first-boot flow.
#
# Args: $1 = root path, $2 = variant (steamdeck, steamdeck-oobe)

_apply_variant() {
  local root="${1:?_apply_variant: missing root}"
  local variant="${2:?_apply_variant: missing variant}"

  # ── 1) manifest.json ─────────────────────────────────────────────────────
  # Both /usr/lib/ and /usr/lib64/ copies exist as regular files;
  # /etc/steamos-atomupd/manifest.json symlinks into /usr/lib/.
  local manifest_path
  for manifest_path in /usr/lib/steamos-atomupd/manifest.json /usr/lib64/steamos-atomupd/manifest.json; do
    local manifest="$root$manifest_path"
    if [[ -f "$manifest" ]]; then
      sed -i "s/\"variant\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"variant\": \"$variant\"/" "$manifest"
      log "  Set variant=$variant in $manifest_path"
    else
      warn "  $manifest_path not found — skipping"
    fi
  done

  # ── 3) os-release VARIANT_ID ─────────────────────────────────────────────
  local os_release="$root/etc/os-release"
  if [[ -f "$os_release" ]]; then
    if grep -q "^VARIANT_ID=" "$os_release"; then
      sed -i "s/^VARIANT_ID=.*/VARIANT_ID=$variant/" "$os_release"
    else
      echo "VARIANT_ID=$variant" >>"$os_release"
    fi
    log "  Set VARIANT_ID=$variant in /etc/os-release"
  else
    warn "  /etc/os-release not found — skipping"
  fi

  # ── 5) OOBE neutralization ───────────────────────────────────────────────
  if [[ "$variant" == "steamdeck" ]]; then
    apply_optimization_for_item "neutralize-oobe" "chroot" "$root" \
      || die "failed to neutralize destructive OOBE Steam reset in steam-jupiter"
  fi
}

_verify_variant() {
  local root="${1:?_verify_variant: missing root}"
  local variant="${2:?_verify_variant: missing variant}"
  local verify_failed=0

  # manifest.json — both /usr/lib/ and /usr/lib64/
  local manifest_path
  for manifest_path in /usr/lib/steamos-atomupd/manifest.json /usr/lib64/steamos-atomupd/manifest.json; do
    local manifest="$root$manifest_path"
    if [[ ! -f "$manifest" ]] || ! grep -q "\"variant\"[[:space:]]*:[[:space:]]*\"$variant\"" "$manifest"; then
      warn "  VERIFY FAILED: $manifest_path variant != $variant"
      verify_failed=1
    else
      log "  OK $manifest_path variant=$variant"
    fi
  done

  # os-release
  local os_release="$root/etc/os-release"
  if [[ ! -f "$os_release" ]] || ! grep -q "^VARIANT_ID=$variant$" "$os_release"; then
    warn "  VERIFY FAILED: os-release VARIANT_ID != $variant"
    verify_failed=1
  else
    log "  OK os-release VARIANT_ID=$variant"
  fi

  # OOBE neutralization
  if [[ "$variant" == "steamdeck" ]]; then
    if ! verify_optimization "oobe" "neutralize-oobe" "chroot" "$root"; then
      warn "  VERIFY FAILED: OOBE neutralization not applied"
      verify_failed=1
    else
      log "  OK OOBE neutralization applied"
    fi
  fi

  return $verify_failed
}

_verify_update_branch() {
  local root="${1:?_verify_update_branch: missing root}"
  local expected="${2:?_verify_update_branch: missing expected value}"

  # manifest.json (both lib paths)
  local manifest_path
  for manifest_path in /usr/lib/steamos-atomupd/manifest.json /usr/lib64/steamos-atomupd/manifest.json; do
    local manifest="$root$manifest_path"
    if [[ ! -f "$manifest" ]] || ! grep -q "\"default_update_branch\"[[:space:]]*:[[:space:]]*\"$expected\"" "$manifest"; then
      return 1
    fi
  done

  # os-release
  local os_release="$root/etc/os-release"
  if [[ ! -f "$os_release" ]] || ! grep -q "^STEAMOS_DEFAULT_UPDATE_BRANCH=$expected$" "$os_release"; then
    return 1
  fi

  return 0
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

  # Determine sddm session name from DEFAULT_SESSION
  local sddm_session
  case "$session" in
    game)    sddm_session="gamescope-wayland.desktop" ;;
    desktop) sddm_session="plasma.desktop" ;;
    *)       sddm_session="plasma.desktop" ;;
  esac

  # Determine Relogin value from disable-autologin setting
  local relogin="true"
  if [[ " ${GAMING_ITEMS:-} " == *" disable-autologin "* ]]; then
    relogin="false"
  fi

  # Set desktop session defaults via steamosctl (safe, no session switch)
  if _run_in_root_cfg "$root" 'command -v steamosctl >/dev/null 2>&1'; then
    _run_in_root_cfg "$root" "steamosctl set-default-login-mode desktop" 2>/dev/null \
      || warn "steamosctl set-default-login-mode failed (non-fatal)"
    _run_in_root_cfg "$root" "steamosctl set-default-desktop-session $sddm_session" 2>/dev/null \
      || warn "steamosctl set-default-desktop-session failed (non-fatal)"
  fi

  # Fallback: write state.toml directly
  local state_toml="$root/home/deck/.config/steamos-manager/state.toml"
  mkdir -p "$(dirname "$state_toml")"
  cat >"$state_toml" <<TOML
[general]
default_login_mode = "desktop"
default_desktop_session = "$sddm_session"
TOML
  chown -R 1000:1000 "$(dirname "$state_toml")" 2>/dev/null || true

  # sddm.conf — set Session= and Relogin= based on config
  local sddm_conf="$root/etc/sddm.conf.d/steamos.conf"
  if [[ -f "$sddm_conf" ]]; then
    # Update Session= line
    if grep -q '^Session=' "$sddm_conf"; then
      log "  Setting sddm session to $sddm_session"
      sed -i "s/^Session=.*/Session=$sddm_session/" "$sddm_conf"
    fi
    # Update Relogin= line
    if grep -q '^Relogin=' "$sddm_conf"; then
      log "  Setting sddm Relogin=$relogin"
      sed -i "s/^Relogin=.*/Relogin=$relogin/" "$sddm_conf"
    fi
  fi

  log "  Default session configured: $session ($sddm_session, Relogin=$relogin)"
}

_verify_default_session() {
  local root="${1:?_verify_default_session: missing root}"
  local expected="${2:?_verify_default_session: missing expected value}"

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
