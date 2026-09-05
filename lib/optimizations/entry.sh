#!/bin/bash
#
# steamos-build-installer — lib/optimizations/entry.sh
# Central router for all optimization modules.
# External callers use this as the single entry point.
#
# Usage: apply_optimization MODULE ITEM [MODE] [ROOT]
#        apply_optimization_for_item ITEM [MODE] [ROOT]
#
# Sourced by the build backend and repatch — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/optimizations/entry.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

OPTIMIZATIONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || {
  echo "Fatal: failed to resolve optimizations directory" >&2
  return 1
}

# Source common utilities
# shellcheck source=lib/optimizations/common.sh
source "$OPTIMIZATIONS_DIR/common.sh"

# Source all optimization modules
for _opt_module in video cpu-performance system pci-hardware build-tools oobe; do
  if [[ -r "$OPTIMIZATIONS_DIR/$_opt_module.sh" ]]; then
    # shellcheck disable=SC1090
    source "$OPTIMIZATIONS_DIR/$_opt_module.sh"
  else
    warn "Missing optimization module: $_opt_module.sh"
  fi
done

# ---------------------------------------------------------------------------
# Customization Registry
# ---------------------------------------------------------------------------
# Load customization definitions from configs/customizations.conf
# Format: module|item|default|description

CUSTOMIZATIONS_CONF="$(dirname "$OPTIMIZATIONS_DIR")/configs/customizations.conf"

# Load customization registry
# Use -gA (global associative) to ensure arrays persist when sourced from functions
declare -gA _OPT_ITEM_TO_MODULE=()
declare -gA _OPT_ITEM_DEFAULT=()

_load_customizations() {
  local module item default _

  if [[ ! -r "$CUSTOMIZATIONS_CONF" ]]; then
    warn "Customizations config not found: $CUSTOMIZATIONS_CONF"
    return 1
  fi

  while IFS='|' read -r module item default _; do
    # Skip comments and empty lines
    [[ "$module" =~ ^[[:space:]]*# || -z "${module// /}" ]] && continue

    _OPT_ITEM_TO_MODULE["$item"]="$module"
    _OPT_ITEM_DEFAULT["$item"]="$default"
  done <"$CUSTOMIZATIONS_CONF"
}

_load_customizations

# ---------------------------------------------------------------------------
# Item → Module Mapping
# ---------------------------------------------------------------------------
# Maps customization item names to their module.
# Loaded from configs/customizations.conf.

_opt_item_to_module() {
  local item="${1:?_opt_item_to_module: missing item name}"

  if [[ -n "${_OPT_ITEM_TO_MODULE["$item"]:-}" ]]; then
    echo "${_OPT_ITEM_TO_MODULE["$item"]}"
  else
    echo ""
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Main Entry Points
# ---------------------------------------------------------------------------

# Route by module name.
#
# Usage: apply_optimization MODULE ITEM [MODE] [ROOT]
#   MODULE - Module name (video, cpu-performance, pci-hardware, build-tools, system)
#   ITEM   - Optimization name within the module
#   MODE   - Optional override: chroot|live (auto-detected if omitted)
#   ROOT   - Optional override: root filesystem path (auto-detected if omitted)
#
# Returns 0 on success, 1 on failure.

apply_optimization() {
  local module="${1:?apply_optimization: missing module name}"
  local item="${2:?apply_optimization: missing item name}"
  local mode="${3:-}"
  local root="${4:-}"

  # Save previous values and override if provided
  local _prev_mode="${OPT_MODE:-}" _prev_root="${OPT_ROOT:-}"
  local _mode_overridden=0 _root_overridden=0

  if [[ -n "$mode" ]]; then
    export OPT_MODE="$mode"
    _mode_overridden=1
  fi
  if [[ -n "$root" ]]; then
    export OPT_ROOT="$root"
    _root_overridden=1
  fi

  # Ensure restoration on any exit path
  # shellcheck disable=SC2064
  trap "
    (( $_mode_overridden )) && export OPT_MODE=\"$_prev_mode\"
    (( $_root_overridden )) && export OPT_ROOT=\"$_prev_root\"
    trap - RETURN
  " RETURN

  # Normalize module name to lowercase
  module="${module,,}"

  case "$module" in
    video)
      apply_video_optimization "$item"
      ;;
    performance | cpu-performance)
      apply_cpu_performance_optimization "$item"
      ;;
    system)
      apply_system_optimization "$item"
      ;;
    pci | pci-hardware)
      apply_pci_hardware_optimization "$item"
      ;;
    build | build-tools)
      apply_build_tools_optimization "$item"
      ;;
    oobe)
      apply_oobe_optimization "$item"
      ;;
    *)
      warn "Unknown optimization module: $module"
      return 1
      ;;
  esac
}

# Route by item name (auto-detects module).
#
# Usage: apply_optimization_for_item ITEM [MODE] [ROOT]
#   ITEM - Customization item name (e.g. unset-libva-driver, gamemode)
#   MODE - Optional override: chroot|live (auto-detected if omitted)
#   ROOT - Optional override: root filesystem path (auto-detected if omitted)
#
# Returns 0 on success, 1 on failure.

apply_optimization_for_item() {
  local item="${1:?apply_optimization_for_item: missing item name}"
  local mode="${2:-}"
  local root="${3:-}"
  local module

  module="$(_opt_item_to_module "$item")"

  if [[ -z "$module" ]]; then
    warn "Unknown customization item: $item"
    return 1
  fi

  apply_optimization "$module" "$item" "$mode" "$root"
}

# ---------------------------------------------------------------------------
# Verify Entry Points
# ---------------------------------------------------------------------------
# Check whether an optimization is currently applied.
# Returns 0 if applied (true), 1 if not applied (false).

# Route verify by module name.
#
# Usage: verify_optimization MODULE ITEM [MODE] [ROOT]
#   MODULE - Module name
#   ITEM   - Optimization name within the module
#   MODE   - Optional override: chroot|live (auto-detected if omitted)
#   ROOT   - Optional override: root filesystem path (auto-detected if omitted)
#
# Returns 0 if applied, 1 if not.

verify_optimization() {
  local module="${1:?verify_optimization: missing module name}"
  local item="${2:?verify_optimization: missing item name}"
  local mode="${3:-}"
  local root="${4:-}"

  # Save previous values and override if provided
  local _prev_mode="${OPT_MODE:-}" _prev_root="${OPT_ROOT:-}"
  local _mode_overridden=0 _root_overridden=0

  if [[ -n "$mode" ]]; then
    export OPT_MODE="$mode"
    _mode_overridden=1
  fi
  if [[ -n "$root" ]]; then
    export OPT_ROOT="$root"
    _root_overridden=1
  fi

  # Ensure restoration on any exit path
  # shellcheck disable=SC2064
  trap "
    (( $_mode_overridden )) && export OPT_MODE=\"$_prev_mode\"
    (( $_root_overridden )) && export OPT_ROOT=\"$_prev_root\"
    trap - RETURN
  " RETURN

  module="${module,,}"

  case "$module" in
    video)
      verify_video_optimization "$item"
      ;;
    performance | cpu-performance)
      verify_cpu_performance_optimization "$item"
      ;;
    system)
      verify_system_optimization "$item"
      ;;
    pci | pci-hardware)
      verify_pci_hardware_optimization "$item"
      ;;
    build | build-tools)
      verify_build_tools_optimization "$item"
      ;;
    oobe)
      verify_oobe_optimization "$item"
      ;;
    *)
      warn "Unknown optimization module: $module"
      return 2
      ;;
  esac
}

# Route verify by item name (auto-detects module).
#
# Usage: verify_optimization_for_item ITEM [MODE] [ROOT]
#   ITEM - Customization item name
#   MODE - Optional override: chroot|live (auto-detected if omitted)
#   ROOT - Optional override: root filesystem path (auto-detected if omitted)
#
# Returns 0 if applied, 1 if not, 2 if module doesn't support verify.

verify_optimization_for_item() {
  local item="${1:?verify_optimization_for_item: missing item name}"
  local mode="${2:-}"
  local root="${3:-}"
  local module

  module="$(_opt_item_to_module "$item")"

  if [[ -z "$module" ]]; then
    warn "Unknown customization item: $item"
    return 1
  fi

  verify_optimization "$module" "$item" "$mode" "$root"
}
