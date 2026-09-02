#!/bin/bash
#
# steamos-build-installer — lib/args.sh
# Shared CLI argument parsing helpers.
# Sourced by steamos-build.sh and backend.sh — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/args.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# parse_common_arg "$1" ["$2"]
#
# Parse one CLI argument shared between the frontend and backend.
# Sets the corresponding global variable directly.
#
# On success (return 0), sets _ARG_SHIFT to the number of positional
# parameters the caller should shift (1 or 2).
#
# Returns:
#   0  — common arg matched and consumed
#   1  — arg not recognized; caller should handle it
#
# Globals written: ACTION, IMG, TARGET_DEV, CONFIG_FILE, OUTPUT_DIR,
#                  ALLOW_SYSTEM_DISK, _ARG_SHIFT
parse_common_arg() {
  case "$1" in
    --action)
      # shellcheck disable=SC2034 # consumed by steamos-build.sh, lib/backend.sh
      ACTION="${2:?--action requires a value}"
      _ARG_SHIFT=2
      return 0
      ;;
    --image)
      # shellcheck disable=SC2034 # consumed by steamos-build.sh, lib/backend.sh, lib/setup.sh, lib/pipelines/
      IMG="${2:?--image requires a value}"
      _ARG_SHIFT=2
      return 0
      ;;
    --device)
      # shellcheck disable=SC2034 # consumed by steamos-build.sh, lib/backend.sh
      TARGET_DEV="${2:?--device requires a value}"
      _ARG_SHIFT=2
      return 0
      ;;
    --config)
      # shellcheck disable=SC2034 # consumed by steamos-build.sh, lib/backend.sh, lib/pipelines/
      CONFIG_FILE="${2:?--config requires a value}"
      _ARG_SHIFT=2
      return 0
      ;;
    --output-dir)
      # shellcheck disable=SC2034 # consumed by steamos-build.sh, lib/backend.sh
      OUTPUT_DIR="${2:?--output-dir requires a value}"
      _ARG_SHIFT=2
      return 0
      ;;
    --allow-system-disk)
      # shellcheck disable=SC2034 # consumed by steamos-build.sh, lib/backend.sh
      ALLOW_SYSTEM_DISK=1
      _ARG_SHIFT=1
      return 0
      ;;
    --output)
      # shellcheck disable=SC2034 # consumed by steamos-build.sh, lib/backend.sh
      VALIDATE_OUTPUT_FILE="${2:?--output requires a value}"
      _ARG_SHIFT=2
      return 0
      ;;
    --debug)
      # shellcheck disable=SC2034 # consumed by steamos-build.sh, lib/backend.sh, lib/common.sh
      DEBUG=1
      _ARG_SHIFT=1
      return 0
      ;;
    --verbose)
      # shellcheck disable=SC2034 # consumed by steamos-build.sh, lib/backend.sh, lib/common.sh
      VERBOSE=1
      _ARG_SHIFT=1
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}
