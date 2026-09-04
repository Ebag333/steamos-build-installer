#!/bin/bash
#
# detect-hw-packages.sh — Auto-detect required firmware and hardware packages.
#
# Two-layer approach:
#   Layer 1: CPU/PCI/USB vendor detection → maps to firmware packages
#   Layer 2: Kernel driver + modinfo → firmware files → pacman -F → packages
#
# Usage: detect_hw_packages
# Prints space-separated list of recommended package names to stdout.
# No root required (read-only operations).

# ---------------------------------------------------------------------------
# Vendor → Package Mapping (Layer 1)
# ---------------------------------------------------------------------------

# Map PCI vendor IDs to firmware package names.
# These match the vendor-oriented split in Arch's linux-firmware.
declare -A _PCI_VENDOR_FW=(
  [8086]="linux-firmware-intel"    # Intel
  [1002]="linux-firmware-amdgpu"   # AMD/ATI
  [1022]="linux-firmware-amdgpu"   # AMD (also uses amdgpu)
  [10de]="linux-firmware-nvidia"   # NVIDIA
  [10ec]="linux-firmware-realtek"  # Realtek
  [168c]="linux-firmware-atheros"  # Qualcomm Atheros
  [17cb]="linux-firmware-qcom"     # Qualcomm (Atheros parent + SoC)
  [14e4]="linux-firmware-broadcom" # Broadcom
  [14a4]="linux-firmware-broadcom" # Broadcom (Cypress)
  [14c3]="linux-firmware-mediatek" # MediaTek
  [1814]="linux-firmware-mediatek" # Ralink (now MediaTek)
  [1013]="linux-firmware-cirrus"   # Cirrus Logic
  [11ab]="linux-firmware-marvell"  # Marvell
  [15b3]="linux-firmware-mellanox" # Mellanox
  [19ee]="linux-firmware-nfp"      # Netronome
  [1077]="linux-firmware-qlogic"   # QLogic
  # [17cb] already mapped above (Qualcomm)
)

# Map USB vendor IDs to firmware package names.
declare -A _USB_VENDOR_FW=(
  [0bda]="linux-firmware-realtek"  # Realtek
  [0cf3]="linux-firmware-atheros"  # Qualcomm Atheros
  [168c]="linux-firmware-atheros"  # Qualcomm Atheros
  [0a5c]="linux-firmware-broadcom" # Broadcom
  [0489]="linux-firmware-mediatek" # MediaTek/Ralink
  [0e8d]="linux-firmware-mediatek" # MediaTek
  [12d1]="linux-firmware-qcom"     # Huawei/Qualcomm
)

# GPU vendor ID → driver packages (Nouveau intentionally excluded).
declare -A _GPU_VENDOR_PKGS=(
  [10de]="nvidia-open-dkms nvidia-utils lib32-nvidia-utils libva-nvidia-driver" # NVIDIA
  [8086]="intel-gmmlib intel-media-driver vulkan-intel lib32-vulkan-intel"      # Intel
  [1002]="mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon"                    # AMD
)

# ---------------------------------------------------------------------------
# Layer 1: CPU Detection
# ---------------------------------------------------------------------------

_detect_cpu_packages() {
  local vendor
  vendor=$(awk -F: '/vendor_id/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' /proc/cpuinfo 2>/dev/null)

  case "$vendor" in
    GenuineIntel) echo "intel-ucode" ;;
    AuthenticAMD) echo "amd-ucode" ;;
  esac
}

# ---------------------------------------------------------------------------
# Layer 1: PCI Vendor Detection
# ---------------------------------------------------------------------------

_detect_pci_vendor_packages() {
  local -A seen=()

  while IFS= read -r line; do
    local dev vendor_id
    dev=$(echo "$line" | cut -d' ' -f1)
    vendor_id=$(echo "$line" | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}' | head -1 | cut -d: -f1)

    [[ -z "$vendor_id" ]] && continue
    [[ -n "${seen[$vendor_id]:-}" ]] && continue
    seen[$vendor_id]=1

    local pkg="${_PCI_VENDOR_FW[$vendor_id]:-}"
    [[ -n "$pkg" ]] && echo "$pkg"
  done < <(lspci -nn 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Layer 1: USB Vendor Detection
# ---------------------------------------------------------------------------

_detect_usb_vendor_packages() {
  local -A seen=()

  while IFS= read -r line; do
    local vendor_id
    # lsusb output: Bus 001 Device 002: ID 0bda:8153 Realtek ...
    vendor_id=$(echo "$line" | grep -oP 'ID \K[0-9a-f]{4}' | head -1)

    [[ -z "$vendor_id" ]] && continue
    [[ -n "${seen[$vendor_id]:-}" ]] && continue
    seen[$vendor_id]=1

    local pkg="${_USB_VENDOR_FW[$vendor_id]:-}"
    [[ -n "$pkg" ]] && echo "$pkg"
  done < <(lsusb 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Layer 1: GPU Driver Detection
# ---------------------------------------------------------------------------

_detect_gpu_packages() {
  local -A seen=()

  while IFS= read -r line; do
    local dev class_code vendor_id
    dev=$(echo "$line" | cut -d' ' -f1)

    # Only VGA/3D controllers (class 0300/0302).
    class_code=$(cat "/sys/bus/pci/devices/0000:${dev}/class" 2>/dev/null || echo "0x000000")
    case "${class_code:0:8}" in
      0x030000 | 0x030200) ;;
      *) continue ;;
    esac

    vendor_id=$(echo "$line" | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}' | head -1 | cut -d: -f1)
    [[ -z "$vendor_id" ]] && continue
    [[ -n "${seen[$vendor_id]:-}" ]] && continue
    seen[$vendor_id]=1

    local pkgs="${_GPU_VENDOR_PKGS[$vendor_id]:-}"
    [[ -n "$pkgs" ]] && echo "$pkgs"
  done < <(lspci -nn 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Layer 2: Kernel Driver → Firmware → Package
# ---------------------------------------------------------------------------

# Map kernel modules to firmware packages for common drivers.
# This avoids expensive pacman -F queries for known mappings.
declare -A _MODULE_FW_PKG=(
  [i915]="linux-firmware-intel"
  [xe]="linux-firmware-intel"
  [iwlwifi]="linux-firmware-intel"
  [e1000e]="linux-firmware-intel"
  [igc]="linux-firmware-intel"
  [amdgpu]="linux-firmware-amdgpu"
  [radeon]="linux-firmware-radeon"
  # nvidia/nvidia_drm/nvidia_modeset: proprietary driver bundles its own firmware
  [r8169]="linux-firmware-realtek"
  [r8152]="linux-firmware-realtek"
  [rtw88]="linux-firmware-realtek"
  [rtw89]="linux-firmware-realtek"
  [ath11k_pci]="linux-firmware-atheros"
  [ath10k_pci]="linux-firmware-atheros"
  [ath9k]="linux-firmware-atheros"
  [wl]="linux-firmware-broadcom"
  [brcmfmac]="linux-firmware-broadcom"
  [brcmsmac]="linux-firmware-broadcom"
  [mt7921e]="linux-firmware-mediatek"
  [mt76]="linux-firmware-mediatek"
  [mlx5_core]="linux-firmware-mellanox"
  [mlx4_core]="linux-firmware-mellanox"
  [nfp]="linux-firmware-nfp"
  [qla2xxx]="linux-firmware-qlogic"
  [bnxt_en]="linux-firmware-broadcom"
)

_detect_driver_packages() {
  local -A seen=()
  local -A driver_pkgs=()

  # Get all loaded kernel modules and their firmware requirements.
  while IFS= read -r mod; do
    [[ -z "$mod" ]] && continue
    [[ -n "${seen[$mod]:-}" ]] && continue
    seen[$mod]=1

    # Check known module → package mapping first.
    local pkg="${_MODULE_FW_PKG[$mod]:-}"
    if [[ -n "$pkg" ]]; then
      driver_pkgs["$pkg"]=1
      continue
    fi

    # For unknown modules, check if they need firmware.
    local firmware_list
    firmware_list=$(modinfo -F firmware "$mod" 2>/dev/null | head -20)
    [[ -z "$firmware_list" ]] && continue

    # Try to find the package for the first firmware file.
    # This is expensive, so only do it for modules we haven't mapped.
    while IFS= read -r fw; do
      [[ -z "$fw" ]] && continue
      local fw_path="usr/lib/firmware/$fw"
      local fw_pkg
      fw_pkg=$(pacman -F "$fw_path" 2>/dev/null | awk '{print $1}' | head -1 | sed 's|.*/||')
      if [[ -n "$fw_pkg" && "$fw_pkg" != "No" ]]; then
        driver_pkgs["$fw_pkg"]=1
        break
      fi
    done <<<"$firmware_list"
  done < <(lsmod 2>/dev/null | awk 'NR>1 {print $1}')

  # Also check PCI devices for drivers not yet loaded.
  while IFS= read -r line; do
    local dev driver
    dev=$(echo "$line" | cut -d' ' -f1)
    driver=$(lspci -k -s "$dev" 2>/dev/null | grep "Kernel driver in use" | awk '{print $NF}' || true)

    [[ -z "$driver" ]] && continue
    [[ -n "${seen[$driver]:-}" ]] && continue
    seen[$driver]=1

    local pkg="${_MODULE_FW_PKG[$driver]:-}"
    if [[ -n "$pkg" ]]; then
      driver_pkgs["$pkg"]=1
    fi
  done < <(lspci -nn 2>/dev/null)

  # Print all found packages.
  for pkg in "${!driver_pkgs[@]}"; do
    echo "$pkg"
  done
}

# ---------------------------------------------------------------------------
# Main Entry Point
# ---------------------------------------------------------------------------

detect_hw_packages() {
  local -A all_pkgs=()

  # Layer 1: CPU detection.
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && all_pkgs["$pkg"]=1
  done < <(_detect_cpu_packages)

  # Layer 1: PCI vendor detection.
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && all_pkgs["$pkg"]=1
  done < <(_detect_pci_vendor_packages)

  # Layer 1: USB vendor detection.
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && all_pkgs["$pkg"]=1
  done < <(_detect_usb_vendor_packages)

  # Layer 1: GPU driver detection.
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && all_pkgs["$pkg"]=1
  done < <(_detect_gpu_packages)

  # Layer 2: Kernel driver inspection.
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && all_pkgs["$pkg"]=1
  done < <(_detect_driver_packages)

  # Always include base linux-firmware.
  all_pkgs["linux-firmware"]=1

  # Print all detected packages (sorted).
  for pkg in $(printf '%s\n' "${!all_pkgs[@]}" | sort); do
    echo "$pkg"
  done
}
