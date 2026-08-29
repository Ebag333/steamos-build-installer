#!/bin/bash
#
# steamos-build-installer — lib/pipelines/pipeline_validate.sh
# Validation pipeline definition.
# Validates configuration and system state.
#
# Sourced by backend.sh — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/pipelines/pipeline_validate.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Pipeline Definition
# ---------------------------------------------------------------------------

register_validate_pipeline() {
  define_pipeline \
    "discover" \
    "validate" \
    "report"

  register_phase "discover" "phase_validate_discover" "Discover context and load config"
  register_phase "validate" "phase_validate_run" "Run validation checks"
  register_phase "report" "phase_validate_report" "Summarize results"
}

# ---------------------------------------------------------------------------
# Validation State
# ---------------------------------------------------------------------------

declare -a _VALIDATE_RESULTS=()
declare _VALIDATE_PASSED=0
declare _VALIDATE_FAILED=0
declare _VALIDATE_SKIPPED=0

_validate_pass() {
  local item="$1"
  _VALIDATE_RESULTS+=("PASS|$item")
  ((_VALIDATE_PASSED++))
  log "  ✓ $item"
}

_validate_fail() {
  local item="$1"
  local detail="${2:-}"
  _VALIDATE_RESULTS+=("FAIL|$item|$detail")
  ((_VALIDATE_FAILED++))
  warn "  ✗ $item${detail:+ — $detail}"
}

_validate_skip() {
  local item="$1"
  local reason="${2:-}"
  _VALIDATE_RESULTS+=("SKIP|$item|$reason")
  ((_VALIDATE_SKIPPED++))
  log "  ○ $item${reason:+ — $reason}"
}

# ---------------------------------------------------------------------------
# Phase: Discover
# ---------------------------------------------------------------------------

phase_validate_discover() {
  local root="${VALIDATE_ROOT:-/}"

  log "Validation target: $root"

  # Detect if target is a mounted rootfs or live system
  if [[ "$root" == "/" ]]; then
    log "Mode: live system"
    export OPT_MODE="live"
  else
    log "Mode: chroot ($root)"
    export OPT_MODE="chroot"
    export OPT_ROOT="$root"
  fi

  # Load config if provided
  if [[ -n "${VALIDATE_CONFIG:-}" && -f "${VALIDATE_CONFIG:-}" ]]; then
    log "Loading config: $VALIDATE_CONFIG"
    # shellcheck disable=SC1090
    source "$VALIDATE_CONFIG"
  elif [[ -f "/home/.steamos-build/build.conf" ]]; then
    log "Loading persisted config: /home/.steamos-build/build.conf"
    # shellcheck disable=SC1091
    source "/home/.steamos-build/build.conf"
  else
    log "No config found — will validate system state only"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Phase: Validate
# ---------------------------------------------------------------------------

phase_validate_run() {
  local root="${OPT_ROOT:-/}"
  local items="${VALIDATE_ITEMS:-}"

  log "Running validation checks"

  # If specific items requested, only validate those.
  # Otherwise, validate everything we can.
  if [[ -n "$items" ]]; then
    for item in $items; do
      _validate_item "$item" "$root"
    done
  else
    _validate_all "$root"
  fi

  return 0
}

_validate_item() {
  local item="$1"
  local root="$2"

  case "$item" in
    # System config
    update-branch)
      _validate_update_branch "$root"
      ;;
    default-session)
      _validate_default_session "$root"
      ;;
    # Optimizations
    neutralize-oobe | unset-libva-driver | gpu-power-limit | resize-bar | \
      cpu-performance | scx-lavd | vm-tunables | gamemode | disable-autologin | \
      pci-realloc | tb-host-reset | thunderbolt | \
      trim-cuda | fix-keyring | skip-sigcheck | debug-boot)
      _validate_optimization "$item" "$root"
      ;;
    # Initramfs
    initramfs)
      _validate_initramfs "$root"
      ;;
    # Hardware packages
    hw-packages)
      _validate_hw_packages "$root"
      ;;
    # Flatpak packages
    flatpak)
      _validate_flatpaks "$root"
      ;;
    *)
      _validate_fail "$item" "unknown validation item"
      ;;
  esac
}

_validate_all() {
  local root="$1"

  # System config
  _validate_update_branch "$root"
  _validate_default_session "$root"

  # Optimizations (check all items from customizations.conf)
  local conf="$SCRIPT_DIR/lib/configs/customizations.conf"
  if [[ -r "$conf" ]]; then
    local module item default
    while IFS='|' read -r module item default _; do
      [[ "$module" =~ ^#.*$ || -z "$module" ]] && continue
      [[ "$default" == "always" ]] && continue
      _validate_optimization "$item" "$root"
    done <"$conf"
  fi

  # Initramfs
  _validate_initramfs "$root"

  # Hardware packages
  _validate_hw_packages "$root"

  # Flatpak packages
  _validate_flatpaks "$root"
}

# ---------------------------------------------------------------------------
# Validation Helpers
# ---------------------------------------------------------------------------

_validate_update_branch() {
  local root="$1"
  local expected="${UPDATE_BRANCH:-stable}"

  if verify_system_config "update-branch" "$root" "$expected"; then
    _validate_pass "update-branch ($expected)"
  else
    _validate_fail "update-branch" "expected $expected"
  fi
}

_validate_default_session() {
  local root="$1"
  local expected="${DEFAULT_SESSION:-game}"

  if verify_system_config "default-session" "$root" "$expected"; then
    _validate_pass "default-session ($expected)"
  else
    _validate_fail "default-session" "expected $expected"
  fi
}

_validate_optimization() {
  local item="$1"
  local root="$2"
  local rc

  verify_optimization_for_item "$item" "$OPT_MODE" "$root" 2>/dev/null
  rc=$?
  if [[ $rc -eq 0 ]]; then
    _validate_pass "$item"
  elif [[ $rc -eq 2 ]]; then
    _validate_skip "$item" "verify not supported"
  else
    _validate_fail "$item"
  fi
}

_validate_initramfs() {
  local root="$1"
  local expected="${INITRAMFS_MODULES:-}"

  if [[ -z "$expected" ]]; then
    _validate_skip "initramfs" "no modules configured"
    return
  fi

  if verify_initramfs "$root" "$expected"; then
    _validate_pass "initramfs"
  else
    _validate_fail "initramfs"
  fi
}

_validate_hw_packages() {
  local root="$1"
  local items="${HW_SUPPORT_ITEMS:-}"

  if [[ -z "$items" ]]; then
    _validate_skip "hw-packages" "no packages configured"
    return
  fi

  if verify_hw_libs "$items"; then
    _validate_pass "hw-packages"
  else
    _validate_fail "hw-packages"
  fi
}

_validate_flatpaks() {
  local root="$1"
  local flatpaks
  flatpaks="$(get_build_items "flatpak")"

  if [[ -z "$flatpaks" ]]; then
    _validate_skip "flatpak" "no flatpaks configured"
    return
  fi

  local pkg recipe_name recipe_dir app_id
  for pkg in $flatpaks; do
    recipe_name="$(get_build_recipe "$pkg")" || recipe_name=""
    if [[ -z "$recipe_name" ]]; then
      _validate_fail "flatpak/$pkg" "no recipe found"
      continue
    fi

    recipe_dir="$SCRIPT_DIR/lib/configs/build_recipes/$recipe_name"
    if [[ ! -d "$recipe_dir" ]]; then
      _validate_fail "flatpak/$pkg" "recipe directory missing"
      continue
    fi

    app_id="$(sed -n 's/^FLATPAK_APP_ID=//p' "$recipe_dir/recipe.conf" 2>/dev/null | tr -d '"')"
    if [[ -z "$app_id" ]]; then
      _validate_fail "flatpak/$pkg" "no FLATPAK_APP_ID in recipe"
      continue
    fi

    if [[ "$OPT_MODE" == "live" ]]; then
      if flatpak info "$app_id" &>/dev/null; then
        _validate_pass "flatpak/$pkg ($app_id)"
      else
        _validate_fail "flatpak/$pkg" "$app_id not installed"
      fi
    else
      local staged="$root/usr/share/steamos-build/flatpaks"
      if [[ -d "$staged" && -n "$(ls "$staged"/*.flatpak 2>/dev/null)" ]]; then
        _validate_pass "flatpak/$pkg (staged)"
      else
        _validate_fail "flatpak/$pkg" "no staged flatpak bundles in $staged"
      fi
    fi
  done
}

# ---------------------------------------------------------------------------
# Phase: Report
# ---------------------------------------------------------------------------

phase_validate_report() {
  local total=$((_VALIDATE_PASSED + _VALIDATE_FAILED + _VALIDATE_SKIPPED))

  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "  VALIDATION REPORT"
  echo "═══════════════════════════════════════════════════════════"
  echo ""

  local entry status item detail
  for entry in "${_VALIDATE_RESULTS[@]}"; do
    IFS='|' read -r status item detail <<<"$entry"
    case "$status" in
      PASS) echo "  ✓ $item" ;;
      FAIL) echo "  ✗ $item${detail:+ — $detail}" ;;
      SKIP) echo "  ○ $item${detail:+ — $detail}" ;;
    esac
  done

  echo ""
  echo "───────────────────────────────────────────────────────────"
  printf "  Total: %d  Passed: %d  Failed: %d  Skipped: %d\n" \
    "$total" "$_VALIDATE_PASSED" "$_VALIDATE_FAILED" "$_VALIDATE_SKIPPED"
  echo "═══════════════════════════════════════════════════════════"
  echo ""

  if ((_VALIDATE_FAILED > 0)); then
    return 1
  fi
  return 0
}
