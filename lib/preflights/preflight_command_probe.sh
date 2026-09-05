#!/bin/bash
#
# steamos-build-installer — lib/preflights/preflight_command_probe.sh
# Shared command-availability probe for preflight modules.
# Provides _pf_command_available() used by preflight_command_availability.sh
# and preflight_generation.sh to avoid duplication.
#
# Self-contained — does NOT source any other library.
# Do not run it directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/preflights/preflight_command_probe.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# Shared command-availability probe for preflight modules.
# Returns 0 if the command is available, 1 otherwise.
# Does NOT die on failure — callers handle error reporting.
_pf_command_available() {
  local rootfs="${1:?_pf_command_available: missing rootfs path}"
  local cmd="${2:?_pf_command_available: missing command name}"

  # Direct executable probe
  local -a search_paths=(
    "/usr/bin/$cmd"
    "/bin/$cmd"
    "/usr/sbin/$cmd"
    "/sbin/$cmd"
  )

  local candidate
  for candidate in "${search_paths[@]}"; do
    [[ -x "$rootfs$candidate" ]] && return 0
  done

  # Chroot fallback
  chroot "$rootfs" /bin/sh -c 'command -v "$1" >/dev/null 2>&1' sh "$cmd"
}
