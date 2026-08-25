#!/bin/bash
#
# steamos-nvidia-installer — lib/library-loader.sh
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

  # Common libraries (shared by all workflows)
  local -a common_libs=(
    common
    overlay
    common_system
    common_modules
    system-config
    common_drivers
    install-hw-libs
    grub
    diagnostics/boot
  )

  # Workflow-specific libraries
  local -a workflow_libs=()
  local -a driver_libs=()

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
      driver_libs=(
        builds/common
        builds/logitech-hid
        builds/aotofu-vaapi
        builds/dlss_updater
      )
      ;;
    repatch)
      workflow_libs=(
        initramfs
      )
      driver_libs=(
        builds/common
        builds/logitech-hid
        builds/aotofu-vaapi
        builds/dlss_updater
      )
      ;;
    live)
      workflow_libs=(
        initramfs
      )
      driver_libs=()
      ;;
    flash)
      workflow_libs=(
        flash
      )
      driver_libs=()
      ;;
    flashless)
      workflow_libs=(
        initramfs
        flashless
      )
      driver_libs=()
      ;;
    *)
      warn "Unknown workflow type: $workflow"
      return 1
      ;;
  esac

  # Source common libraries
  local lib
  for lib in "${common_libs[@]}"; do
    _load_lib "$base_dir" "$lib"
  done

  # Source workflow-specific libraries
  for lib in "${workflow_libs[@]}"; do
    _load_lib "$base_dir" "$lib"
  done

  # Source customization entry point
  _load_lib "$base_dir" "customization"

  # Source driver libraries
  for lib in "${driver_libs[@]}"; do
    _load_lib "$base_dir" "$lib"
  done
}

# Load a single library.
# Args: $1 = base directory, $2 = library name (relative path without .sh)
_load_lib() {
  local base_dir="$1"
  local lib_name="$2"
  local lib_path="$base_dir/$lib_name.sh"

  if [[ ! -r "$lib_path" ]]; then
    warn "Missing library: $lib_path"
    return 1
  fi

  # shellcheck source=lib/common.sh
  source "$lib_path"
}

# ---------------------------------------------------------------------------
# Library List Helpers
# ---------------------------------------------------------------------------

# Get list of libraries for a workflow (for debugging/display).
# Args: $1 = workflow type
# Output: one library name per line
list_workflow_libs() {
  local workflow="${1:?list_workflow_libs: missing workflow type}"

  echo "common"
  echo "overlay"
  echo "common_system"
  echo "common_modules"
  echo "common_drivers"
  echo "install-hw-libs"
  echo "grub"

  case "$workflow" in
    build)
      echo "rootfs-etc"
      echo "setup"
      echo "initramfs"
      echo "update-strategy"
      echo "installer"
      echo "finalize"
      echo "flashless"
      ;;
    repatch)
      echo "initramfs"
      ;;
    live)
      echo "initramfs"
      ;;
    flash)
      echo "flash"
      ;;
    flashless)
      echo "initramfs"
      echo "flashless"
      ;;
  esac

  echo "customization"

  case "$workflow" in
    build | repatch)
      echo "builds/common"
      echo "builds/logitech-hid"
      echo "builds/aotofu-vaapi"
      echo "builds/dlss_updater"
      ;;
  esac
}
