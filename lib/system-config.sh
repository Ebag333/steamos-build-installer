#!/bin/bash
#
# steamos-build-installer — lib/system-config.sh
# System configuration stamping.
# Handles: variant, update-branch, default-session
#
# These are simple "stamp a preference into a config file" operations.
# Sourced by the build backend and repatch — do not run directly.
#
# Note: disable-autologin is handled by lib/optimizations/system.sh,
# not here.  This file only handles Session= in sddm.conf.

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
  local expected="${3:?verify_system_config: missing expected value}"

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

read_system_config() {
  local item="${1:?read_system_config: missing item name}"
  local root="${2:?read_system_config: missing root}"

  case "$item" in
    variant) _read_variant "$root" ;;
    update-branch) _read_update_branch "$root" ;;
    default-session) _read_default_session "$root" ;;
    *)
      warn "Unknown system config: $item"
      echo ""
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

  if [[ ! "$branch" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    warn "_apply_update_branch: invalid branch name '$branch'"
    return 1
  fi

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
      printf '\nSTEAMOS_DEFAULT_UPDATE_BRANCH=%s\n' "$branch" >>"$os_release"
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

  if [[ ! "$variant" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    warn "_apply_variant: invalid variant name '$variant'"
    return 1
  fi

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
      printf '\nVARIANT_ID=%s\n' "$variant" >>"$os_release"
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
  local verify_failed=0

  # manifest.json (both lib paths)
  local manifest_path
  for manifest_path in /usr/lib/steamos-atomupd/manifest.json /usr/lib64/steamos-atomupd/manifest.json; do
    local manifest="$root$manifest_path"
    if [[ -f "$manifest" ]]; then
      if ! grep -q "\"default_update_branch\"[[:space:]]*:[[:space:]]*\"$expected\"" "$manifest"; then
        warn "  VERIFY FAILED: $manifest_path default_update_branch != $expected"
        verify_failed=1
      else
        log "  OK $manifest_path default_update_branch=$expected"
      fi
    fi
  done

  # os-release
  local os_release="$root/etc/os-release"
  if [[ ! -f "$os_release" ]] || ! grep -q "^STEAMOS_DEFAULT_UPDATE_BRANCH=$expected$" "$os_release"; then
    warn "  VERIFY FAILED: os-release STEAMOS_DEFAULT_UPDATE_BRANCH != $expected"
    verify_failed=1
  else
    log "  OK os-release STEAMOS_DEFAULT_UPDATE_BRANCH=$expected"
  fi

  return $verify_failed
}

_read_variant() {
  local root="${1:?_read_variant: missing root}"
  local os_release="$root/etc/os-release"
  if [[ -f "$os_release" ]]; then
    local variant
    variant="$(sed -n 's/^VARIANT_ID=//p' "$os_release" | head -1)"
    if [[ -n "$variant" ]]; then
      echo "$variant"
      return
    fi
  fi
  echo ""
}

_read_update_branch() {
  local root="${1:?_read_update_branch: missing root}"
  local os_release="$root/etc/os-release"
  if [[ -f "$os_release" ]]; then
    local branch
    branch="$(sed -n 's/^STEAMOS_DEFAULT_UPDATE_BRANCH=//p' "$os_release" | head -1)"
    if [[ -n "$branch" ]]; then
      echo "$branch"
      return
    fi
  fi
  echo ""
}

# ---------------------------------------------------------------------------
# default-session
# ---------------------------------------------------------------------------
# Configure the default desktop session.
# Patches Session= in sddm.conf.
#
# Args: $1 = root path, $2 = session (desktop, game)

_apply_default_session() {
  local root="${1:?_apply_default_session: missing root}"
  local session="${2:?_apply_default_session: missing session}"

  # Determine sddm session name from DEFAULT_SESSION
  local sddm_session
  case "$session" in
    game) sddm_session="gamescope-wayland.desktop" ;;
    desktop) sddm_session="plasma.desktop" ;;
    *) sddm_session="plasma.desktop" ;;
  esac

  local configured=0

  # Live mode: configure steamosctl and always write state.toml
  if is_live; then
    if command -v steamosctl >/dev/null 2>&1; then
      steamosctl set-default-login-mode desktop 2>/dev/null \
        || warn "steamosctl set-default-login-mode failed (non-fatal)"
      steamosctl set-default-desktop-session "$sddm_session" 2>/dev/null \
        || warn "steamosctl set-default-desktop-session failed (non-fatal)"
    fi

    # Always write state.toml directly (even if steamosctl ran)
    log "  Writing state.toml"
    local config_dir="/home/deck/.config/steamos-manager"
    install -d -m755 "$config_dir" || return 1
    cat >"$config_dir/state.toml" <<EOF
version = 1

[services]

[session_manager]
default_login_mode = "Desktop"
desktop_session = "$sddm_session"
default_desktop_session = "$sddm_session"
EOF
    chown 1000:1000 "$config_dir/state.toml"
    configured=1
  fi

  # sddm.conf — find steamos.conf in sddm.conf.d directories and patch Session=
  local sddm_confs
  sddm_confs="$(find "$root" -path "*/sddm.conf.d/steamos.conf" \( -type f -o -type l \) 2>/dev/null)"

  if [[ -n "$sddm_confs" ]]; then
    local count
    count="$(echo "$sddm_confs" | wc -l)"
    log "  Found $count steamos.conf file(s)"
    while IFS= read -r sddm_conf; do
      if grep -q '^Session=' "$sddm_conf"; then
        log "  Setting sddm session to $sddm_session in $sddm_conf"
        sed -i "s/^Session=.*/Session=$sddm_session/" "$sddm_conf"
        configured=1
      else
        warn "  $sddm_conf exists but has no Session= line, skipping"
      fi
    done <<<"$sddm_confs"
  fi

  # If no steamos.conf with Session= was found, check if sddm is installed
  # and create one in /etc/sddm.conf.d/ (local override location)
  if [[ "$configured" -eq 0 ]]; then
    local sddm_conf_dirs
    sddm_conf_dirs="$(find "$root" -type d -name "sddm.conf.d" 2>/dev/null)"
    if [[ -n "$sddm_conf_dirs" ]]; then
      local new_conf="$root/etc/sddm.conf.d/steamos.conf"
      log "  Creating $new_conf with Session=$sddm_session"
      mkdir -p "$(dirname "$new_conf")"
      cat >"$new_conf" <<EOF
[Autologin]
User=
Relogin=false
Session=$sddm_session
EOF
      configured=1
    else
      warn "  No steamos.conf found and no sddm.conf.d directories — sddm not installed?"
    fi
  fi

  if [[ "$configured" -eq 1 ]]; then
    log "  Default session configured: $session ($sddm_session)"
  else
    warn "  Default session NOT configured"
  fi
}

_verify_default_session() {
  local root="${1:?_verify_default_session: missing root}"
  local expected="${2:?_verify_default_session: missing expected value}"

  local found_values=()
  local found_paths=()
  local verify_ok=0

  # Check all steamos.conf files in sddm.conf.d
  local sddm_confs
  sddm_confs="$(find "$root" -path "*/sddm.conf.d/steamos.conf" \( -type f -o -type l \) 2>/dev/null)"
  if [[ -n "$sddm_confs" ]]; then
    while IFS= read -r sddm_conf; do
      local session_line
      session_line="$(sed -n 's/^Session=//p' "$sddm_conf" | head -1)"
      if [[ -n "$session_line" ]]; then
        found_values+=("$session_line")
        found_paths+=("$sddm_conf")
        case "$expected" in
          game) [[ "$session_line" == gamescope* ]] && verify_ok=1 ;;
          desktop) [[ "$session_line" == plasma* ]] && verify_ok=1 ;;
        esac
      fi
    done <<<"$sddm_confs"
  fi

  # Check state.toml
  local state_toml="$root/home/deck/.config/steamos-manager/state.toml"
  if [[ -f "$state_toml" ]]; then
    local toml_session
    toml_session="$(sed -n 's/^desktop_session.*=.*"\(.*\)"/\1/p' "$state_toml" | head -1)"
    if [[ -z "$toml_session" ]]; then
      toml_session="$(sed -n 's/^default_desktop_session.*=.*"\(.*\)"/\1/p' "$state_toml" | head -1)"
    fi
    if [[ -n "$toml_session" ]]; then
      found_values+=("$toml_session")
      found_paths+=("$state_toml")
      case "$expected" in
        game) [[ "$toml_session" == gamescope* ]] && verify_ok=1 ;;
        desktop) [[ "$toml_session" == plasma* ]] && verify_ok=1 ;;
      esac
    fi
  fi

  # Warn if multiple sources disagree
  if [[ ${#found_values[@]} -gt 1 ]]; then
    local unique
    unique="$(printf '%s\n' "${found_values[@]}" | sort -u | wc -l)"
    if [[ "$unique" -gt 1 ]]; then
      warn "  Session values differ across sources (expected: $expected):"
      local i
      for i in "${!found_paths[@]}"; do
        warn "    ${found_paths[$i]} -> ${found_values[$i]}"
      done
    fi
  fi

  [[ "$verify_ok" -eq 1 ]] && return 0
  return 1
}

_read_default_session() {
  local root="${1:?_read_default_session: missing root}"

  local found_values=()
  local found_paths=()
  local first_value=""

  # Try all steamos.conf files in sddm.conf.d
  local sddm_confs
  sddm_confs="$(find "$root" -path "*/sddm.conf.d/steamos.conf" \( -type f -o -type l \) 2>/dev/null)"
  if [[ -n "$sddm_confs" ]]; then
    while IFS= read -r sddm_conf; do
      local session_line
      session_line="$(sed -n 's/^Session=//p' "$sddm_conf" | head -1)"
      if [[ -n "$session_line" ]]; then
        local mapped=""
        case "$session_line" in
          gamescope*) mapped="game" ;;
          plasma*) mapped="desktop" ;;
        esac
        if [[ -n "$mapped" ]]; then
          found_values+=("$mapped")
          found_paths+=("$sddm_conf")
          [[ -z "$first_value" ]] && first_value="$mapped"
        fi
      fi
    done <<<"$sddm_confs"
  fi

  # Fallback: check state.toml
  local state_toml="$root/home/deck/.config/steamos-manager/state.toml"
  if [[ -f "$state_toml" ]]; then
    local toml_session
    toml_session="$(sed -n 's/^desktop_session.*=.*"\(.*\)"/\1/p' "$state_toml" | head -1)"
    if [[ -z "$toml_session" ]]; then
      toml_session="$(sed -n 's/^default_desktop_session.*=.*"\(.*\)"/\1/p' "$state_toml" | head -1)"
    fi
    if [[ -n "$toml_session" ]]; then
      local mapped=""
      case "$toml_session" in
        gamescope*) mapped="game" ;;
        plasma*) mapped="desktop" ;;
      esac
      if [[ -n "$mapped" ]]; then
        found_values+=("$mapped")
        found_paths+=("$state_toml")
        [[ -z "$first_value" ]] && first_value="$mapped"
      fi
    fi
  fi

  # Warn if multiple sources disagree
  if [[ ${#found_values[@]} -gt 1 ]]; then
    local unique
    unique="$(printf '%s\n' "${found_values[@]}" | sort -u | wc -l)"
    if [[ "$unique" -gt 1 ]]; then
      warn "  Session values differ across sources:"
      local i
      for i in "${!found_paths[@]}"; do
        warn "    ${found_paths[$i]} -> ${found_values[$i]}"
      done
    fi
  fi

  echo "$first_value"
}
