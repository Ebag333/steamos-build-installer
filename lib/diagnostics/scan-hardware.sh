#!/bin/bash
#
# steamos-build-installer — lib/diagnostics/scan-hardware.sh
# PCI hardware scan: identifies unclaimed devices and suggests kernel modules.
#
# Usage: scan-hardware.sh

echo "=== Hardware scan: unclaimed PCI devices ==="
echo

found=0

while IFS="" read -r line; do
  dev="$(echo "$line" | cut -d' ' -f1)"
  desc="$(echo "$line" | cut -d' ' -f2-)"

  vendor_device="$(
    echo "$line" \
      | grep -oP '\[\K[0-9a-fA-F]{4}:[0-9a-fA-F]{4}' \
      | head -1 \
      || true
  )"

  driver="$(
    lspci -k -s "$dev" 2>/dev/null \
      | grep "Kernel driver in use" \
      | awk '{print $NF}' \
      || true
  )"

  #
  # If a kernel driver already owns the device, it's fine.
  #
  [[ -n "$driver" ]] && continue

  found=1

  echo "Unclaimed: $dev $desc"

  if [[ -n "$vendor_device" ]]; then
    vendor="${vendor_device%:*}"
    device="${vendor_device#*:}"

    vendor="${vendor^^}"
    device="${device^^}"

    modalias="pci:v0000${vendor}d0000${device}sv*sd*bc*sc*i*"

    modules="$(
      modprobe -R "$modalias" 2>/dev/null \
        | head -5 \
        || true
    )"

    if [[ -n "$modules" ]]; then
      echo "  Matching module(s):"
      echo "$modules" | sed 's/^/    /'
    else
      echo "  No matching kernel module found for $vendor_device"
    fi
  fi

  echo

done < <(lspci -nn)

if [[ $found -eq 0 ]]; then
  echo "All PCI devices have drivers loaded."
fi
