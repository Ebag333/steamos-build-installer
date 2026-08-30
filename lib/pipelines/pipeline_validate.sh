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
declare _VALIDATE_INFO=0
declare _VALIDATE_FOUND=0
declare _VALIDATE_HAS_CONFIG=0

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

_validate_info() {
  local item="$1"
  local detail="${2:-}"
  _VALIDATE_RESULTS+=("INFO|$item|$detail")
  ((_VALIDATE_INFO++))
  log "  · $item${detail:+ — $detail}"
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

  # Load config if explicitly provided.
  # Persisted config is sourced for variable context but does NOT trigger
  # config-aware filtering — only an explicit --config does.
  # Persisted config is only used for live validation (not offline images).
  if [[ -n "${VALIDATE_CONFIG:-}" && -f "${VALIDATE_CONFIG:-}" ]]; then
    log "Loading config: $VALIDATE_CONFIG"
    _VALIDATE_HAS_CONFIG=1
    # shellcheck disable=SC1090
    source "$VALIDATE_CONFIG"
    # Infer CUSTOM_DRIVERS_SET if config has CUSTOM_DRIVERS but didn't set the flag
    if [[ -n "${CUSTOM_DRIVERS:-}" && "${CUSTOM_DRIVERS_SET:-0}" != "1" ]]; then
      CUSTOM_DRIVERS_SET=1
    fi
  elif [[ "$OPT_MODE" != "chroot" && -f "/home/.steamos-build/build.conf" ]]; then
    log "Loading persisted config: /home/.steamos-build/build.conf (not filtering — no explicit config)"
    # shellcheck disable=SC1091
    source "/home/.steamos-build/build.conf"
  else
    log "No config found — validating all items"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Phase: Validate
# ---------------------------------------------------------------------------

phase_validate_run() {
  local root="${OPT_ROOT:-/}"

  log "Running validation checks"
  _validate_all "$root"

  return 0
}

# ---------------------------------------------------------------------------
# Validate All — Single Path
# ---------------------------------------------------------------------------
# Always validates everything from all confs.  Config-awareness is handled
# entirely in the report phase.

_validate_all() {
  local root="$1"

  # System config
  _validate_update_branch "$root"
  _validate_default_session "$root"

  # Optimizations (all items from customizations.conf)
  _validate_all_optimizations "$root"

  # Initramfs (all groups from initramfs.conf)
  _validate_all_initramfs "$root"

  # Hardware packages (all entries from hw-packages-arch.conf + hw-packages-valve.conf)
  _validate_all_hw_packages "$root"

  # Build items (all entries from hw-packages-build.conf)
  _validate_all_build_items "$root"
}

# ---------------------------------------------------------------------------
# Validation Helpers — System Config
# ---------------------------------------------------------------------------

_validate_update_branch() {
  local root="$1"
  local expected="${UPDATE_BRANCH:-stable}"

  if verify_system_config "update-branch" "$root" "$expected"; then
    _validate_pass "update-branch ($expected)"
  elif [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
    _validate_fail "update-branch" "expected $expected"
  else
    _validate_info "update-branch" "expected $expected"
  fi
}

_validate_default_session() {
  local root="$1"
  local expected="${DEFAULT_SESSION:-game}"

  if verify_system_config "default-session" "$root" "$expected"; then
    _validate_pass "default-session ($expected)"
  elif [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
    _validate_fail "default-session" "expected $expected"
  else
    _validate_info "default-session" "expected $expected"
  fi
}

# ---------------------------------------------------------------------------
# Validation Helpers — Optimizations
# ---------------------------------------------------------------------------

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
  elif [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
    _validate_fail "$item"
  else
    _validate_info "$item"
  fi
}

_validate_all_optimizations() {
  local root="$1"
  local conf="$SCRIPT_DIR/lib/configs/customizations.conf"

  if [[ ! -r "$conf" ]]; then
    _validate_skip "optimizations" "customizations.conf not found"
    return
  fi

  local module item default
  while IFS='|' read -r module item default _; do
    [[ "$module" =~ ^#.*$ || -z "$module" ]] && continue
    _validate_optimization "$item" "$root"
  done <"$conf"
}

# ---------------------------------------------------------------------------
# Validation Helpers — Initramfs
# ---------------------------------------------------------------------------

_validate_all_initramfs() {
  local root="$1"
  local conf="$SCRIPT_DIR/lib/configs/initramfs.conf"

  if [[ ! -r "$conf" ]]; then
    _validate_skip "initramfs" "initramfs.conf not found"
    return
  fi

  local group modules default
  while IFS='|' read -r group modules default _; do
    [[ "$group" =~ ^#.*$ || -z "$group" ]] && continue
    _validate_initramfs_group "$group" "$modules" "$root"
  done <"$conf"
}

_validate_initramfs_group() {
  local group="$1"
  local modules="$2"
  local root="$3"

  if verify_initramfs "$root" "$modules"; then
    _validate_pass "initramfs/$group"
  elif [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
    _validate_fail "initramfs/$group" "modules missing: $modules"
  else
    _validate_info "initramfs/$group" "modules missing: $modules"
  fi
}

# ---------------------------------------------------------------------------
# Validation Helpers — Hardware Packages
# ---------------------------------------------------------------------------

_validate_all_hw_packages() {
  local root="$1"
  local conf

  for conf in \
    "$SCRIPT_DIR/lib/configs/hw-packages-arch.conf" \
    "$SCRIPT_DIR/lib/configs/hw-packages-valve.conf"; do
    if [[ ! -r "$conf" ]]; then
      continue
    fi

    local group pkg version default
    while IFS='|' read -r group pkg version default _; do
      [[ "$group" =~ ^#.*$ || -z "$group" ]] && continue
      _validate_hw_package "$pkg" "$root"
    done <"$conf"
  done
}

_validate_hw_package() {
  local pkg="$1"
  local root="$2"

  if verify_hw_libs "$pkg"; then
    _validate_pass "hw/$pkg"
  elif [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
    _validate_fail "hw/$pkg" "not installed"
  else
    _validate_info "hw/$pkg" "not installed"
  fi
}

# ---------------------------------------------------------------------------
# Validation Helpers — Build Items (kernel-modules + flatpaks)
# ---------------------------------------------------------------------------

_validate_all_build_items() {
  local root="$1"
  local conf="$SCRIPT_DIR/lib/configs/hw-packages-build.conf"

  if [[ ! -r "$conf" ]]; then
    _validate_skip "build-items" "hw-packages-build.conf not found"
    return
  fi

  local type name version default desc recipe
  # shellcheck disable=SC2034
  while IFS='|' read -r type name version default desc recipe; do
    [[ "$type" =~ ^#.*$ || -z "$type" ]] && continue
    _validate_build_item "$type" "$name" "$recipe" "$root"
  done <"$conf"
}

_validate_build_item() {
  local type="$1"
  local name="$2"
  local recipe="$3"
  local root="$4"

  case "$type" in
    kernel-module)
      _validate_kernel_module "$name" "$recipe" "$root"
      ;;
    flatpak)
      _validate_flatpak_item "$name" "$recipe" "$root"
      ;;
    *)
      _validate_skip "build/$name" "unknown type: $type"
      ;;
  esac
}

_validate_kernel_module() {
  local name="$1"
  local recipe="$2"
  local root="$3"

  if verify_hw_libs "$name"; then
    _validate_pass "build/$name"
  elif [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
    _validate_fail "build/$name" "not installed"
  else
    _validate_info "build/$name" "not installed"
  fi
}

_validate_flatpak_item() {
  local name="$1"
  local recipe_name="$2"
  local root="$3"

  if [[ -z "$recipe_name" ]]; then
    _validate_fail "flatpak/$name" "no recipe"
    return
  fi

  local recipe_dir="$SCRIPT_DIR/lib/configs/build_recipes/$recipe_name"
  if [[ ! -d "$recipe_dir" ]]; then
    _validate_fail "flatpak/$name" "recipe directory missing"
    return
  fi

  local app_id
  app_id="$(sed -n 's/^FLATPAK_APP_ID=//p' "$recipe_dir/recipe.conf" 2>/dev/null | tr -d '"')"
  if [[ -z "$app_id" ]]; then
    _validate_fail "flatpak/$name" "no FLATPAK_APP_ID in recipe"
    return
  fi

  if [[ "$OPT_MODE" == "live" ]]; then
    if flatpak info "$app_id" &>/dev/null; then
      _validate_pass "flatpak/$name ($app_id)"
    elif [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
      _validate_fail "flatpak/$name" "$app_id not installed"
    else
      _validate_info "flatpak/$name" "$app_id not installed"
    fi
  else
    local staged="$root/usr/share/steamos-build/flatpaks"
    if [[ -d "$staged" && -n "$(ls "$staged"/*.flatpak 2>/dev/null)" ]]; then
      _validate_pass "flatpak/$name (staged)"
    elif [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
      _validate_fail "flatpak/$name" "no staged flatpak bundles in $staged"
    else
      _validate_info "flatpak/$name" "no staged flatpak bundles in $staged"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Config Selection Check
# ---------------------------------------------------------------------------
# Returns 0 if the item is "selected" in the loaded config, 1 if not.
# Used by the report phase to filter results when a config was provided.

_validate_is_selected() {
  local item="$1"

  # System config items are always selected
  case "$item" in
    update-branch* | default-session*) return 0 ;;
  esac

  # Optimization items
  if [[ -n "${_OPT_ITEM_TO_MODULE["$item"]:-}" ]]; then
    # "always" items are unconditionally selected
    if [[ "${_OPT_ITEM_DEFAULT["$item"]:-}" == "always" ]]; then
      return 0
    fi
    # Check GAMING_ITEMS
    if [[ -n "${GAMING_ITEMS:-}" && " $GAMING_ITEMS " == *" $item "* ]]; then
      return 0
    fi
    return 1
  fi

  # Initramfs groups — check if the group's modules are in INITRAMFS_MODULES
  if [[ "$item" == initramfs/* ]]; then
    local group="${item#initramfs/}"
    if [[ -z "${INITRAMFS_MODULES:-}" ]]; then
      return 1
    fi
    # Look up modules for this group from initramfs.conf
    local conf="$SCRIPT_DIR/lib/configs/initramfs.conf"
    if [[ -r "$conf" ]]; then
      local g m d
      while IFS='|' read -r g m d _; do
        [[ "$g" =~ ^#.*$ || -z "$g" ]] && continue
        if [[ "$g" == "$group" ]]; then
          # Check if all modules in this group are in INITRAMFS_MODULES
          local mod
          for mod in $m; do
            if [[ " $INITRAMFS_MODULES " != *" $mod "* ]]; then
              return 1
            fi
          done
          return 0
        fi
      done <"$conf"
    fi
    return 1
  fi

  # Hardware packages — check HW_SUPPORT_ITEMS
  if [[ "$item" == hw/* ]]; then
    local pkg="${item#hw/}"
    if [[ -n "${HW_SUPPORT_ITEMS:-}" && " $HW_SUPPORT_ITEMS " == *" $pkg "* ]]; then
      return 0
    fi
    return 1
  fi

  # Build items — check CUSTOM_DRIVERS or fall back to default
  if [[ "$item" == build/* || "$item" == flatpak/* ]]; then
    local name="${item#*/}"
    name="${name% (*}"
    if [[ "${CUSTOM_DRIVERS_SET:-0}" == "1" ]]; then
      if [[ -n "${CUSTOM_DRIVERS:-}" && " ${CUSTOM_DRIVERS} " == *" $name "* ]]; then
        return 0
      fi
      return 1
    fi
    # No explicit config — check default from hw-packages-build.conf
    local conf="$SCRIPT_DIR/lib/configs/hw-packages-build.conf"
    if [[ -r "$conf" ]]; then
      local t n v d
      while IFS='|' read -r t n v d _; do
        [[ "$t" =~ ^#.*$ || -z "$t" ]] && continue
        if [[ "$n" == "$name" && "$d" == "TRUE" ]]; then
          return 0
        fi
      done <"$conf"
    fi
    return 1
  fi

  # Unknown items — treat as not selected
  return 1
}

# ---------------------------------------------------------------------------
# Phase: Report
# ---------------------------------------------------------------------------

phase_validate_report() {
  # If a config was loaded, cross-reference results against config selections.
  # Items not selected in the config are overridden to SKIP.
  if [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
    local filtered=()
    local entry status item detail
    local repassed=0 refailed=0 reskipped=0 refound=0

    for entry in "${_VALIDATE_RESULTS[@]}"; do
      IFS='|' read -r status item detail <<<"$entry"

      if _validate_is_selected "$item"; then
        # Selected — keep the real result
        filtered+=("$entry")
        case "$status" in
          PASS) ((repassed++)) ;;
          FAIL) ((refailed++)) ;;
          SKIP) ((reskipped++)) ;;
        esac
      elif [[ "$status" == "PASS" ]]; then
        # Not selected but present — mark as found
        filtered+=("FOUND|$item|present (not selected in config)")
        ((refound++))
      else
        # Not selected and absent — skip
        filtered+=("SKIP|$item|not selected in config")
        ((reskipped++))
      fi
    done

    # Replace results with filtered set
    _VALIDATE_RESULTS=("${filtered[@]}")
    _VALIDATE_PASSED=$repassed
    _VALIDATE_FAILED=$refailed
    _VALIDATE_SKIPPED=$reskipped
    _VALIDATE_FOUND=$refound
  fi

  local total=$((_VALIDATE_PASSED + _VALIDATE_FAILED + _VALIDATE_SKIPPED + _VALIDATE_INFO + _VALIDATE_FOUND))

  echo ""
  echo "═══════════════════════════════════════════════════════════"
  if [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
    echo "  VALIDATION REPORT"
  else
    echo "  SYSTEM STATE REPORT"
  fi
  echo "═══════════════════════════════════════════════════════════"

  local section=""
  local entry status item detail display
  for entry in "${_VALIDATE_RESULTS[@]}"; do
    IFS='|' read -r status item detail <<<"$entry"

    # Determine section from item prefix
    local new_section=""
    case "$item" in
      update-branch* | default-session*) new_section="System Config" ;;
      initramfs/*) new_section="Initramfs" ;;
      hw/*) new_section="Hardware Packages" ;;
      build/* | flatpak/*) new_section="Build Items" ;;
      *) new_section="Customizations" ;;
    esac

    # Print section header on transition
    if [[ "$new_section" != "$section" ]]; then
      section="$new_section"
      echo ""
      echo "  $section"
      echo "  ────────────────────────────────────────────────"
    fi

    # Strip prefix for cleaner display
    display="$item"
    case "$item" in
      initramfs/*) display="${item#initramfs/}" ;;
      hw/*) display="${item#hw/}" ;;
      build/*) display="${item#build/}" ;;
      flatpak/*) display="${item#flatpak/}" ;;
    esac

    case "$status" in
      PASS) echo "    ✓ $display" ;;
      FAIL) echo "    ✗ $display${detail:+ — $detail}" ;;
      INFO) echo "    · $display${detail:+ — $detail}" ;;
      SKIP) echo "    ○ $display${detail:+ — $detail}" ;;
      FOUND) echo "    ◆ $display${detail:+ — $detail}" ;;
    esac
  done

  echo ""
  echo "═══════════════════════════════════════════════════════════"
  if [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
    printf "  Total: %d  Passed: %d  Failed: %d  Skipped: %d  Found: %d\n" \
      "$total" "$_VALIDATE_PASSED" "$_VALIDATE_FAILED" "$_VALIDATE_SKIPPED" "$_VALIDATE_FOUND"
  else
    printf "  Total: %d  Present: %d  Absent: %d  Skipped: %d\n" \
      "$total" "$_VALIDATE_PASSED" "$_VALIDATE_INFO" "$_VALIDATE_SKIPPED"
  fi
  echo "═══════════════════════════════════════════════════════════"
  echo ""

  return 0
}
