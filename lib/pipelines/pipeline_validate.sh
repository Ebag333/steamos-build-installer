#!/bin/bash
#
# steamos-nvidia-installer — lib/pipelines/pipeline_validate.sh
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
  elif [[ -f "/home/.steamos-nvidia/build.conf" ]]; then
    log "Loading persisted config: /home/.steamos-nvidia/build.conf"
    source "/home/.steamos-nvidia/build.conf"
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

  if verify_optimization_for_item "$item" "$OPT_MODE" "$root" 2>/dev/null; then
    _validate_pass "$item"
  else
    local rc=$?
    if [[ $rc -eq 2 ]]; then
      _validate_skip "$item" "verify not supported"
    else
      _validate_fail "$item"
    fi
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
