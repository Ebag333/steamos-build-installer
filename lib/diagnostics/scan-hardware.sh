#!/bin/bash
set -euo pipefail
#
# steamos-build-installer — lib/diagnostics/scan-hardware.sh
# PCI hardware scan: identifies unclaimed devices and suggests kernel modules.
#
# Usage: scan-hardware.sh

echo "=== Hardware scan: unclaimed PCI devices ==="
echo

found=0
probe_failed=0

if ! command -v lspci &>/dev/null; then
  echo "ERROR: lspci not found. Install pciutils." >&2
  exit 1
fi

# Capture lspci -nn output and validate it succeeded.
lspci_output="$(lspci -nn 2>&1)" || {
  echo "ERROR: lspci -nn failed (exit $?). Cannot scan PCI devices." >&2
  echo "  Output: $lspci_output" >&2
  exit 1
}

if [[ -z "$lspci_output" ]]; then
  echo "ERROR: lspci -nn returned no output. Cannot scan PCI devices." >&2
  exit 1
fi

while IFS="" read -r line; do
  [[ -z "$line" ]] && continue
  dev="$(printf '%s\n' "$line" | cut -d' ' -f1)"
  desc="$(printf '%s\n' "$line" | cut -d' ' -f2-)"

  vendor_device="$(
    printf '%s\n' "$line" \
      | grep -oP '\[\K[0-9a-fA-F]{4}:[0-9a-fA-F]{4}' \
      | head -1 \
      || true
  )"

  # Run lspci -k -s for the specific device; detect probe failures
  # separately from "no driver loaded".
  lspci_k_output="$(lspci -k -s "$dev" 2>&1)" || {
    echo "WARNING: lspci -k -s $dev failed; skipping device." >&2
    probe_failed=1
    continue
  }

  driver="$(
    printf '%s\n' "$lspci_k_output" \
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

    # vendor and device are already lowercase from lspci — no conversion needed

    modalias="pci:v0000${vendor}d0000${device}sv*sd*bc*sc*i*"

    modules="$(
      modprobe -R "$modalias" 2>/dev/null \
        | head -5 \
        || true
    )"

    if [[ -n "$modules" ]]; then
      echo "  Matching module(s):"
      # shellcheck disable=SC2001
      echo "$modules" | sed 's/^/    /'
    else
      echo "  No matching kernel module found for $vendor_device"
    fi
  fi

  echo

done <<<"$lspci_output"

if [[ $found -eq 0 && $probe_failed -eq 0 ]]; then
  echo "All PCI devices have drivers loaded."
  exit 0
elif [[ $probe_failed -ne 0 ]]; then
  echo "WARNING: One or more PCI device probes failed; results may be incomplete."
  if [[ $found -eq 0 ]]; then
    echo "No unclaimed devices found among probed devices."
  else
    echo "Unclaimed devices detected."
  fi
  exit 1
else
  echo "Unclaimed devices detected."
  exit 1
fi
