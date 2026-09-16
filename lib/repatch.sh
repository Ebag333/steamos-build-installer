#!/bin/bash
#
# steamos-build-installer — lib/repatch.sh
# Repatch workflow support — sourced by the wrapper, do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/repatch.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi
