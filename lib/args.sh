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
      ACTION="${2:?--action requires a value}"
      _ARG_SHIFT=2
      return 0
      ;;
    --image)
      IMG="${2:?--image requires a value}"
      _ARG_SHIFT=2
      return 0
      ;;
    --device)
      TARGET_DEV="${2:?--device requires a value}"
      _ARG_SHIFT=2
      return 0
      ;;
    --config)
      CONFIG_FILE="${2:?--config requires a value}"
      _ARG_SHIFT=2
      return 0
      ;;
    --output-dir)
      OUTPUT_DIR="${2:?--output-dir requires a value}"
      _ARG_SHIFT=2
      return 0
      ;;
    --allow-system-disk)
      ALLOW_SYSTEM_DISK=1
      _ARG_SHIFT=1
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}
