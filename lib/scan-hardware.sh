#!/bin/bash
#
# scan-hardware.sh — scan PCI devices and show driver status with criticality.
#
# Usage: ./scan-hardware.sh
#
# Reports:
#   - All PCI devices with their driver status
#   - Whether each driver is critical, important, or normal
#   - Unclaimed devices with available modules
#
# No root required (read-only operations).

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
# shellcheck disable=SC2034
BOLD='\033[1m'
NC='\033[0m'

# ---- driver classification ----
# Critical: required for boot, storage, display, or essential hardware
CRITICAL="nvme ahci sd_mod btrfs i915 xe nvidia nvidia_modeset nvidia_drm nvidia_uvm thunderbolt typec xhci_hcd usbhid hid_generic"

# Important: network, audio, sensors, USB controllers
IMPORTANT="iwlwifi igc snd_hda_intel snd_sof_pci_intel_mtl mei_me i2c_i801 spi_intel_pci processor_thermal_device_pci"

classify_driver() {
  local driver="$1"
  for d in $CRITICAL; do
    [[ "$driver" == "$d" ]] && echo "CRITICAL" && return
  done
  for d in $IMPORTANT; do
    [[ "$driver" == "$d" ]] && echo "IMPORTANT" && return
  done
  echo "normal"
}

# ---- header ----
echo -e "${CYAN}=== Hardware Driver Scan ===${NC}"
echo ""
printf "%-12s %-8s %-11s %-45s %-18s %s\n" "DEVICE" "CLASS" "PCI ID" "DESCRIPTION" "DRIVER" "STATUS"
printf "%-12s %-8s %-11s %-45s %-18s %s\n" "------" "-----" "------" "-----------" "------" "------"

# ---- scan all PCI devices ----
unclaimed=0
critical_missing=0

while IFS= read -r line; do
  # Parse lspci -nn output:
  # "00:1f.0 ISA bridge [0601]: Intel Corporation Device [8086:7e02] (rev 20)"
  dev=$(echo "$line" | cut -d' ' -f1)

  # Extract vendor:device ID (last [...] pair)
  vendor_device=$(echo "$line" | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}' | head -1)

  # Extract description: everything between the class code and vendor_device
  # Strip: class code [xxxx], (rev ...), trailing whitespace
  desc=$(echo "$line" | sed 's/^[^ ]* //; s/\[[0-9a-f]\{4\}:[0-9a-f]\{4\}\]//g; s/(rev [^)]*)//; s/  */ /g; s/ *$//')

  # Get device class
  class_code=$(cat "/sys/bus/pci/devices/0000:${dev}/class" 2>/dev/null || echo "0x000000")
  case "${class_code:0:6}" in
    0x0108) class="NVMe" ;;
    0x0106) class="SATA" ;;
    0x0100) class="SCSI" ;;
    0x0300) class="VGA" ;;
    0x0302) class="3D" ;;
    0x0200) class="NET" ;;
    0x0403) class="AUDIO" ;;
    0x0c03) class="USB" ;;
    0x0880) class="SYS" ;;
    0x0604) class="PCI" ;;
    *)      class="OTHER" ;;
  esac

  # Get driver
  driver=$(lspci -k -s "$dev" 2>/dev/null | grep "Kernel driver in use" | awk '{print $NF}' || true)

  # Classify
  if [[ -n "$driver" ]]; then
    priority=$(classify_driver "$driver")
    case "$priority" in
      CRITICAL) status="${GREEN}✓ critical${NC}" ;;
      IMPORTANT) status="${GREEN}✓ important${NC}" ;;
      *)        status="${GREEN}✓${NC}" ;;
    esac
    printf "%-12s %-8s %-11s %-45s %-18s %b\n" "$dev" "$class" "${vendor_device:--}" "${desc:0:45}" "$driver" "$status"
  else
    ((unclaimed++))
    status="${RED}✗ unclaimed${NC}"

    # Check if a module exists
    modules=""
    if [[ -n "$vendor_device" ]]; then
      vendor="${vendor_device%:*}"
      device="${vendor_device#*:}"
      modalias="pci:v0000${vendor}d0000${device}sv*sd*bc*sc*i*"
      modules=$(modprobe -R "$modalias" 2>/dev/null | head -3 || true)
    fi

    if [[ -n "$modules" ]]; then
      status="${YELLOW}✗ unclaimed (module: ${modules%% *})${NC}"
    fi

    printf "%-12s %-8s %-11s %-45s %-18s %b\n" "$dev" "$class" "${vendor_device:--}" "${desc:0:45}" "-" "$status"

    # Check if any missing critical module
    if [[ -n "$modules" ]]; then
      for mod in $modules; do
        if [[ "$(classify_driver "$mod")" == "CRITICAL" ]]; then
          ((critical_missing++))
        fi
      done
    fi
  fi

done < <(lspci -nn)

# ---- summary ----
echo ""
echo -e "${CYAN}=== Summary ===${NC}"
echo "  Total PCI devices: $(lspci -nn | wc -l)"
echo "  Unclaimed: $unclaimed"
if [[ $critical_missing -gt 0 ]]; then
  echo -e "  ${RED}Critical drivers missing: $critical_missing${NC}"
fi

# ---- show loaded critical drivers ----
echo ""
echo -e "${CYAN}=== Loaded critical drivers ===${NC}"
for mod in $CRITICAL; do
  if lsmod 2>/dev/null | grep -q "^${mod} "; then
    echo -e "  ${GREEN}✓${NC} $mod"
  elif modinfo -F filename "$mod" 2>/dev/null | grep -q '(builtin)'; then
    echo -e "  ${GREEN}✓${NC} $mod (built-in)"
  else
    echo -e "  ${YELLOW}○${NC} $mod (not loaded)"
  fi
done

# ---- claimed critical devices ----
echo ""
echo -e "${CYAN}=== Claimed critical devices ===${NC}"
while IFS= read -r line; do
  dev=$(echo "$line" | cut -d' ' -f1)
  vendor_device=$(echo "$line" | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}' | head -1)
  desc=$(echo "$line" | sed 's/^[^ ]* //; s/\[[0-9a-f]\{4\}:[0-9a-f]\{4\}\]//g; s/(rev [^)]*)//; s/  */ /g; s/ *$//')
  driver=$(lspci -k -s "$dev" 2>/dev/null | grep "Kernel driver in use" | awk '{print $NF}' || true)
  [[ -z "$driver" ]] && continue
  priority=$(classify_driver "$driver")
  [[ "$priority" == "CRITICAL" ]] || continue
  echo -e "  ${GREEN}✓${NC} $dev [${vendor_device:-?}]: $desc → $driver"
done < <(lspci -nn)

# ---- unclaimed devices with modules ----
if [[ $unclaimed -gt 0 ]]; then
  echo ""
  echo -e "${CYAN}=== Unclaimed devices with available modules ===${NC}"
  while IFS= read -r line; do
    dev=$(echo "$line" | cut -d' ' -f1)
    vendor_device=$(echo "$line" | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}' | head -1)
    desc=$(echo "$line" | sed 's/^[^ ]* //; s/\[[0-9a-f]\{4\}:[0-9a-f]\{4\}\]//g; s/(rev [^)]*)//; s/  */ /g; s/ *$//')
    driver=$(lspci -k -s "$dev" 2>/dev/null | grep "Kernel driver in use" | awk '{print $NF}' || true)
    [[ -n "$driver" ]] && continue

    if [[ -n "$vendor_device" ]]; then
      vendor="${vendor_device%:*}"
      device="${vendor_device#*:}"
      modalias="pci:v0000${vendor}d0000${device}sv*sd*bc*sc*i*"
      modules=$(modprobe -R "$modalias" 2>/dev/null | head -5 || true)
      if [[ -n "$modules" ]]; then
        echo "  $dev [$vendor_device]: $desc"
        echo "    Modules: $modules"
      fi
    fi
  done < <(lspci -nn)

  echo ""
  echo -e "${CYAN}=== Unclaimed device details ===${NC}"
  while IFS= read -r line; do
    dev=$(echo "$line" | cut -d' ' -f1)
    driver=$(lspci -k -s "$dev" 2>/dev/null | grep "Kernel driver in use" | awk '{print $NF}' || true)
    [[ -n "$driver" ]] && continue
    echo ""
    lspci -nnk -s "$dev" 2>/dev/null | sed 's/^/  /'
  done < <(lspci -nn)
fi
