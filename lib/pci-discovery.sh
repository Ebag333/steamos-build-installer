#!/bin/bash
#
# steamos-build-installer — lib/pci-discovery.sh
# PCI hardware enumeration for initramfs module selection.
# Sourced by steamos-build.sh — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/pci-discovery.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Translate a PCI class code to a human-readable category.
# Args: $1 = class code (e.g. "0x030000")
class_name() {
  local code="${1,,}"
  local major="${code:2:2}"
  case "$major" in
    01) echo "storage" ;;
    02) echo "network" ;;
    03) echo "display" ;;
    04) echo "multimedia" ;;
    05) echo "memory" ;;
    06) echo "bridge" ;;
    07) echo "communication" ;;
    08) echo "system" ;;
    09) echo "input" ;;
    0c) echo "serial" ;;
    *) echo "other" ;;
  esac
}

# Get a short PCI device description from lspci.
# Args: $1 = PCI address (e.g. "0000:2e:00.0")
get_device_description() {
  local pci="$1"
  local desc
  desc="$(lspci -s "$pci" 2>/dev/null | sed 's/^[^ ]* //')" || true
  echo "${desc:-unknown}"
}

# Get the kernel driver currently bound to a PCI device.
# Args: $1 = sysfs device directory
get_bound_driver() {
  local devdir="$1"
  local driver_link="$devdir/driver"
  if [[ -L "$driver_link" ]]; then
    basename "$(readlink "$driver_link")" 2>/dev/null || echo "-"
  else
    echo "-"
  fi
}

# Get a module description from modinfo.
# Args: $1 = module name
get_module_description() {
  local mod="$1"
  local desc
  desc="$(modinfo -F description "$mod" 2>/dev/null | head -1)" || true
  echo "${desc:--}"
}

# Get the kernel module currently bound to a PCI device (from sysfs driver/module symlink).
# Args: $1 = sysfs device directory
get_bound_module() {
  local devdir="$1"
  local mod_link="$devdir/driver/module"
  if [[ -L "$mod_link" ]]; then
    basename "$(readlink -f "$mod_link")" 2>/dev/null || echo ""
  fi
}

# Enumerate PCI devices and their matching kernel modules.
# Args: $1 = kernel version (KVER)
# Output: tab-separated lines with header:
#   PCI  CLASS  CLASS_TYPE  DEVICE  BOUND_DRIVER  MODULE  MODULE_DESCRIPTION
pci_discover_modules() {
  local kver="${1:?pci_discover_modules: missing kernel version}"

  printf 'PCI\tCLASS\tCATEGORY\tDEVICE\tBOUND_DRIVER\tMODULE\tMODULE_DESCRIPTION\n'

  for modalias_file in /sys/bus/pci/devices/*/modalias; do
    [[ -r "$modalias_file" ]] || continue

    local devdir="${modalias_file%/modalias}"
    local pci
    pci="$(basename "$devdir")"

    local class class_type alias device_desc bound_driver bound_module
    class="$(cat "$devdir/class" 2>/dev/null || echo unknown)"
    class_type="$(class_name "$class")"
    alias="$(cat "$modalias_file" 2>/dev/null || true)"
    device_desc="$(get_device_description "$pci")"
    bound_driver="$(get_bound_driver "$devdir")"
    bound_module="$(get_bound_module "$devdir")"

    # Union: bound module + modprobe -R results, deduplicated.
    local -a mods
    mapfile -t mods < <(
      {
        [[ -n "$bound_module" ]] && echo "$bound_module"
        modprobe -S "$kver" -R "$alias" 2>/dev/null
      } \
        | sed '/^[[:space:]]*$/d' \
        | sort -u
    )

    if ((${#mods[@]} == 0)); then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$pci" "$class" "$class_type" "$device_desc" "$bound_driver" "-" "-"
      continue
    fi

    for mod in "${mods[@]}"; do
      local mod_desc
      mod_desc="$(get_module_description "$mod")"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$pci" "$class" "$class_type" "$device_desc" "$bound_driver" "$mod" "$mod_desc"
    done
  done
}
