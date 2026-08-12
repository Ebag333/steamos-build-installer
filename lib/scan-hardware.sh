#!/bin/bash
#
# scan-hardware.sh — scan for unclaimed PCI devices and check if modules exist.
#
# Usage: ./scan-hardware.sh
#
# Reports:
#   - PCI devices with no kernel driver loaded
#   - Whether a module exists that could handle each device
#
# No root required (read-only operations).

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== Hardware scan: unclaimed PCI devices ===${NC}"
echo ""

found=0

while IFS= read -r line; do
  # Parse: "00:1f.0 ISA bridge [0601]: Intel Corporation Device [8086:7e02] (rev 20)"
  dev=$(echo "$line" | cut -d' ' -f1)
  desc=$(echo "$line" | cut -d' ' -f2-)
  vendor_device=$(echo "$line" | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}' | head -1)

  # Check if a driver is loaded
  driver=$(lspci -k -s "$dev" 2>/dev/null | grep "Kernel driver in use" | awk '{print $NF}' || true)
  [[ -n "$driver" ]] && continue

  found=1
  echo -e "${YELLOW}Unclaimed:${NC} $dev $desc"

  # Try to find a module for this device
  if [[ -n "$vendor_device" ]]; then
    vendor="${vendor_device%:*}"
    device="${vendor_device#*:}"

    # Search for matching modalias
    modalias="pci:v0000${vendor}d0000${device}sv*sd*bc*sc*i*"
    modules=$(modprobe -R "$modalias" 2>/dev/null | head -5 || true)

    if [[ -n "$modules" ]]; then
      echo -e "  ${GREEN}Module exists:${NC} $modules"
      # Check if it's currently loadable
      for mod in $modules; do
        if modinfo "$mod" >/dev/null 2>&1; then
          echo -e "  ${GREEN}Available:${NC} $mod ($(modinfo -F description "$mod" 2>/dev/null || echo 'no description'))"
        fi
      done
    else
      echo -e "  ${RED}No module found${NC} for vendor:device $vendor_device"
    fi
  fi

  # Also check via /sys
  syspath="/sys/bus/pci/devices/0000:${dev}/modalias"
  if [[ -f "$syspath" ]]; then
    sys_modules=$(modprobe -R "$(cat "$syspath")" 2>/dev/null | head -5 || true)
    if [[ -n "$sys_modules" && "$sys_modules" != "$modules" ]]; then
      echo -e "  ${GREEN}Also available:${NC} $sys_modules"
    fi
  fi

  echo ""
done < <(lspci -nn)

if [[ $found -eq 0 ]]; then
  echo -e "${GREEN}All PCI devices have drivers loaded.${NC}"
fi
