#!/bin/bash
#
# steamos-build-installer — lib/library-loader.sh
# Unified library loading for all workflows.
# Provides a single function to source libraries by workflow type.
#
# Sourced by pipeline.sh and workflow entry points — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/library-loader.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Library Loader
# ---------------------------------------------------------------------------

# Load libraries for a specific workflow.
# Args: $1 = workflow type, $2 = base directory
# Workflow types: build, repatch, live, flash, flashless
load_workflow_libs() {
  local workflow="${1:?load_workflow_libs: missing workflow type}"
  local base_dir="${2:?load_workflow_libs: missing base directory}"

  # Idempotency guard: skip if this workflow+base_dir combination was already loaded.
  # Use a sanitized sentinel variable name derived from the arguments.
  local _sentinel_key
  _sentinel_key="_LOADED_${workflow}_$(printf '%s' "$base_dir" | tr '/-' '__')"
  if [[ -n "${!_sentinel_key:-}" ]]; then
    return 0
  fi

  # Common libraries (shared by all workflows).
  # Order matters: later libs may depend on functions/variables defined by
  # earlier ones (e.g. overlay needs common helpers, common_drivers needs
  # common_modules and overlay globals).
  local -a common_libs=(
    pipeline
    workflow-common
    common
    overlay
    common_system
    common_modules
    system-config
    common_drivers
    install-hw-libs
    grub
    pacman-helpers
    system-upgrade
    diagnostics/boot
    preflights/preflight
  )

  # Workflow-specific libraries
  local -a workflow_libs=()

  case "$workflow" in
    build)
      workflow_libs=(
        rootfs-etc
        setup
        initramfs
        update-strategy
        installer
        finalize
        flashless
      )
      ;;
    repatch)
      workflow_libs=(
        initramfs
      )
      ;;
    live)
      workflow_libs=(
        rootfs-etc
        setup
        initramfs
        update-strategy
        installer
        finalize
        flashless
      )
      ;;
    flash)
      workflow_libs=(
        flash
      )
      ;;
    flashless)
      workflow_libs=(
        initramfs
        flashless
      )
      ;;
    validate)
      workflow_libs=(
        initramfs
      )
      ;;
    *)
      printf '[loader] WARNING: Unknown workflow type: %s\n' "$workflow" >&2
      return 1
      ;;
  esac

  # Source common libraries
  local lib
  for lib in "${common_libs[@]}"; do
    _load_lib "$base_dir" "$lib" || return 1
  done

  # Source workflow-specific libraries
  for lib in "${workflow_libs[@]}"; do
    _load_lib "$base_dir" "$lib" || return 1
  done

  # Source customization entry point
  _load_lib "$base_dir" "customization" || return 1

  # Mark this workflow+base_dir combination as loaded.
  printf -v "$_sentinel_key" '%s' '1'
}

# Load a single library.
# Args: $1 = base directory, $2 = library name (relative path without .sh)
_load_lib() {
  local base_dir="$1"
  local lib_name="$2"
  local lib_path="$base_dir/$lib_name.sh"

  if [[ ! -f "$lib_path" || ! -r "$lib_path" ]]; then
    printf '[loader] WARNING: Cannot source library: %s (base_dir=%s) — path is not a readable regular file\n' "$lib_path" "$base_dir" >&2
    return 1
  fi

  # shellcheck source=lib/common.sh
  source "$lib_path"
}
