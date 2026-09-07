#!/bin/bash
#
# tools/tests/efi-state/fixture-factory.sh
# Mock boot fixture factory for the EFI state application test suite.
#
# Produces the directory-fixture tree described in Section 8.1 of the
# EFI State Application Mechanism test plan.
#
# Usage (source, then call):
#   source tools/tests/efi-state/fixture-factory.sh
#   create_mock_boot_fixture /tmp/test-XXXXXX flashless B
#   ...
#   destroy_mock_fixture /tmp/test-XXXXxx

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "fixture-factory.sh is a library - source it, do not run directly." >&2
  exit 1
fi

set -euo pipefail

# ============================================================================
# Deterministic UUID generation (Section 8.3)
#
# Every identifier is namespaced by a short test ID so parallel fixtures
# and leaked previous fixtures cannot collide.
#
# Uses SHA-1 of "namespace::role" to produce deterministic UUIDs.
# ============================================================================

# derive_uuid NAMESPACE ROLE
#   NAMESPACE - test ID, e.g. "B-01" or "flashless-worker3"
#   ROLE      - partition role, e.g. "rootfs-A", "efi-A", "esp"
#
# Returns a UUID-v5-ish string (SHA-1 based, version nibble = 5).
derive_uuid() {
  local namespace="${1:?derive_uuid: missing namespace}"
  local role="${2:?derive_uuid: missing role}"

  local digest
  digest="$(printf '%s::%s' "$namespace" "$role" | sha1sum | awk '{print $1}')"

  local raw="${digest:0:32}"
  # Force version nibble to 5 (position 12 in 32-char hex string)
  raw="${raw:0:12}5${raw:13}"

  # Set variant bits (10xx) at nibble 16
  local variant_nibble
  variant_nibble="$(printf '%x' $(((0x${raw:16:1} & 0x3) | 0x8)))"
  raw="${raw:0:16}${variant_nibble}${raw:17}"

  echo "${raw:0:8}-${raw:8:4}-${raw:12:4}-${raw:16:4}-${raw:20:12}"
}

# derive_partuuid NAMESPACE ROLE
#   Same namespace/role scheme, but uses a distinct prefix so PARTUUIDs
#   never collide with filesystem UUIDs.
#
# Returns a UUID-format PARTUUID (version 4-ish).
derive_partuuid() {
  local namespace="${1:?derive_partuuid: missing namespace}"
  local role="${2:?derive_partuuid: missing role}"

  local digest
  digest="$(printf '%s::partuuid::%s' "$namespace" "$role" | sha1sum | awk '{print $1}')"

  local raw="${digest:0:32}"
  # Version 4
  raw="${raw:0:12}4${raw:13}"

  local variant_nibble
  variant_nibble="$(printf '%x' $(((0x${raw:16:1} & 0x3) | 0x8)))"
  raw="${raw:0:16}${variant_nibble}${raw:17}"

  echo "${raw:0:8}-${raw:8:4}-${raw:12:4}-${raw:16:4}-${raw:20:12}"
}

# ============================================================================
# populate_mock_grub_cfg
#
# Generate a valid grub.cfg with search --fs-uuid entries.
#
# populate_mock_grub_cfg GRUB_CFG_PATH ROOTFS_UUID KERNEL_VERSION
# ============================================================================
populate_mock_grub_cfg() {
  local grub_cfg="${1:?populate_mock_grub_cfg: missing grub_cfg_path}"
  local rootfs_uuid="${2:?populate_mock_grub_cfg: missing rootfs_uuid}"
  local kernel_version="${3:-6.1.52-neptune-61}"

  cat >"$grub_cfg" <<GRUB_CFG_EOF
# Auto-generated mock grub.cfg for testing
set default=0
set timeout=3

search --fs-uuid --set=root ${rootfs_uuid}

menuentry "SteamOS (${kernel_version})" {
    linux /boot/vmlinuz-${kernel_version} root=UUID=${rootfs_uuid} ro
    initrd /boot/amd-ucode.img /boot/initramfs-${kernel_version}.img
}

menuentry "SteamOS (${kernel_version}) (fallback)" {
    linux /boot/vmlinuz-${kernel_version} root=UUID=${rootfs_uuid} ro
    initrd /boot/initramfs-${kernel_version}.img
}
GRUB_CFG_EOF
}

# ============================================================================
# populate_mock_grubx64_efi
#
# Generate a minimal valid PE stub with the target rootfs UUID embedded.
#
# The stub contains:
#   - MZ DOS header (first 2 bytes)
#   - PE signature offset at 0x3C
#   - PE\0\0 signature
#   - COFF header (machine=AMD64, subsystem=EFI_APPLICATION)
#   - The rootfs UUID embedded as ASCII in the data section
#
# This is a *syntactically valid* PE fixture, NOT a real GRUB binary.
# For tests that need a real GRUB binary, use an actual grub-mkimage output.
#
# populate_mock_grubx64_efi EFI_PATH ROOTFS_UUID
# ============================================================================
populate_mock_grubx64_efi() {
  local efi_path="${1:?populate_mock_grubx64_efi: missing efi_path}"
  local rootfs_uuid="${2:?populate_mock_grubx64_efi: missing rootfs_uuid}"

  # Build a minimal PE32+ EFI application stub (512 bytes total).
  # Layout:
  #   0x000-0x001  MZ magic
  #   0x03C-0x03F  PE header offset (little-endian 0x80)
  #   0x080-0x083  "PE\0\0" signature
  #   0x084-0x097  COFF header: machine=0x8664 (AMD64), sections=1, etc.
  #   0x098-0x0B7  Optional header: magic=0x20B (PE32+), subsystem=0x0A (EFI)
  #   0x0B8-0x0FF  Section table / padding
  #   0x100-0x1FF  Data section (contains embedded UUID)

  local efi_dir
  efi_dir="$(dirname "$efi_path")"
  mkdir -p "$efi_dir"

  # Create a 512-byte zero-filled file, then poke in the headers.
  dd if=/dev/zero bs=512 count=1 2>/dev/null >"$efi_path"

  # Write individual bytes via printf + dd
  # MZ header
  printf 'MZ' | dd of="$efi_path" bs=1 count=2 conv=notrunc 2>/dev/null

  # PE header offset at 0x3C (little-endian 32-bit = 0x80)
  printf '\x80\x00\x00\x00' | dd of="$efi_path" bs=1 seek=$((0x3C)) count=4 conv=notrunc 2>/dev/null

  # PE signature at offset 0x80
  printf 'PE\x00\x00' | dd of="$efi_path" bs=1 seek=$((0x80)) count=4 conv=notrunc 2>/dev/null

  # COFF header at offset 0x84
  #   Machine: 0x8664 (AMD64) - little-endian
  printf '\x64\x86' | dd of="$efi_path" bs=1 seek=$((0x84)) count=2 conv=notrunc 2>/dev/null
  #   NumberOfSections: 1
  printf '\x01\x00' | dd of="$efi_path" bs=1 seek=$((0x86)) count=2 conv=notrunc 2>/dev/null
  #   TimeDateStamp: 0 (4 bytes)
  printf '\x00\x00\x00\x00' | dd of="$efi_path" bs=1 seek=$((0x88)) count=4 conv=notrunc 2>/dev/null
  #   PointerToSymbolTable: 0 (4 bytes)
  printf '\x00\x00\x00\x00' | dd of="$efi_path" bs=1 seek=$((0x8C)) count=4 conv=notrunc 2>/dev/null
  #   NumberOfSymbols: 0 (4 bytes)
  printf '\x00\x00\x00\x00' | dd of="$efi_path" bs=1 seek=$((0x90)) count=4 conv=notrunc 2>/dev/null
  #   SizeOfOptionalHeader: 0xF0 (240 bytes for PE32+) - little-endian
  printf '\xF0\x00' | dd of="$efi_path" bs=1 seek=$((0x94)) count=2 conv=notrunc 2>/dev/null
  #   Characteristics: 0x22 (EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE)
  printf '\x22\x00' | dd of="$efi_path" bs=1 seek=$((0x96)) count=2 conv=notrunc 2>/dev/null

  # Optional header at offset 0x98
  #   Magic: 0x20B (PE32+)
  printf '\x0B\x02' | dd of="$efi_path" bs=1 seek=$((0x98)) count=2 conv=notrunc 2>/dev/null
  #   Subsystem: 0x0A (EFI_APPLICATION) at offset 0x98+68 = 0xDC
  printf '\x0A\x00' | dd of="$efi_path" bs=1 seek=$((0xDC)) count=2 conv=notrunc 2>/dev/null

  # Embed the rootfs UUID as ASCII in the data section (offset 0x100)
  printf '%s' "$rootfs_uuid" | dd of="$efi_path" bs=1 seek=$((0x100)) conv=notrunc 2>/dev/null

  # Embed a marker string so tests can verify SteamOS GRUB indicators
  printf 'steamenv_boot' | dd of="$efi_path" bs=1 seek=$((0x140)) conv=notrunc 2>/dev/null
}

# ============================================================================
# _create_mock_efi
#
# Create mock EFI partition content: grub.cfg, grubx64.efi stub, partsets.
#
# _create_mock_efi EFI_DIR ROOTFS_UUID PARTNAMESPACE [SLOT_COUNT]
#
# SLOT_COUNT defaults to 2 (A+B). Pass 1 for single-slot Build fixtures.
# ============================================================================
_create_mock_efi() {
  local efi_dir="${1:?_create_mock_efi: missing efi_dir}"
  local rootfs_uuid="${2:?_create_mock_efi: missing rootfs_uuid}"
  local ns="${3:?_create_mock_efi: missing namespace}"
  local slot_count="${4:-2}"

  # Steamos EFI directory
  mkdir -p "$efi_dir/EFI/steamos"
  mkdir -p "$efi_dir/SteamOS/partsets"

  # Generate grub.cfg
  populate_mock_grub_cfg "$efi_dir/EFI/steamos/grub.cfg" "$rootfs_uuid"

  # Generate grubx64.efi stub with embedded UUID
  populate_mock_grubx64_efi "$efi_dir/EFI/steamos/grubx64.efi" "$rootfs_uuid"

  # Generate partset files
  local partuuid_a partuuid_b
  partuuid_a="$(derive_partuuid "$ns" "efi-A")"

  # Slot A partset
  echo "rootfs $(derive_partuuid "$ns" "rootfs-A")" >"$efi_dir/SteamOS/partsets/A"
  echo "efi ${partuuid_a}" >>"$efi_dir/SteamOS/partsets/A"
  echo "var $(derive_partuuid "$ns" "var-A")" >>"$efi_dir/SteamOS/partsets/A"

  # Slot B partset (only if multi-slot)
  if [[ "$slot_count" -ge 2 ]]; then
    partuuid_b="$(derive_partuuid "$ns" "efi-B")"
    echo "rootfs $(derive_partuuid "$ns" "rootfs-B")" >"$efi_dir/SteamOS/partsets/B"
    echo "efi ${partuuid_b}" >>"$efi_dir/SteamOS/partsets/B"
    echo "var $(derive_partuuid "$ns" "var-B")" >>"$efi_dir/SteamOS/partsets/B"
  fi
}

# ============================================================================
# _create_mock_esp
#
# Create mock shared ESP content: bootconf files.
#
# _create_mock_esp ESP_DIR NAMESPACE SLOT_COUNT
# ============================================================================
_create_mock_esp() {
  local esp_dir="${1:?_create_mock_esp: missing esp_dir}"
  local ns="${2:?_create_mock_esp: missing namespace}"
  local slot_count="${3:-2}"

  mkdir -p "$esp_dir/SteamOS/conf"

  # Generate A.conf (always present)
  cat >"$esp_dir/SteamOS/conf/A.conf" <<BOOTCONF_A_EOF
# Bootconf for slot A (mock)
title=SteamOS (slot A)
image-invalid=0
boot-attempts=0
BOOTCONF_A_EOF

  # Generate B.conf (only for multi-slot)
  if [[ "$slot_count" -ge 2 ]]; then
    cat >"$esp_dir/SteamOS/conf/B.conf" <<BOOTCONF_B_EOF
# Bootconf for slot B (mock)
title=SteamOS (slot B)
image-invalid=1
boot-attempts=0
BOOTCONF_B_EOF
  fi
}

# ============================================================================
# _create_mock_topology
#
# Generate topology.json with deterministic UUIDs/PARTUUIDs.
# This is the test oracle - production code must discover identity from
# fixture devices, not read this file.
#
# _create_mock_topology METADATA_DIR NAMESPACE SCENARIO CURRENT_SLOT TARGET_SLOT
# ============================================================================
_create_mock_topology() {
  local metadata_dir="${1:?_create_mock_topology: missing metadata_dir}"
  local ns="${2:?_create_mock_topology: missing namespace}"
  local scenario="${3:?_create_mock_topology: missing scenario}"
  local current_slot="${4:?_create_mock_topology: missing current_slot}"
  local target_slot="${5:?_create_mock_topology: missing target_slot}"

  mkdir -p "$metadata_dir"

  # Derive all UUIDs from namespace
  local rootfs_a_uuid rootfs_a_partuuid
  local rootfs_b_uuid rootfs_b_partuuid
  local efi_a_partuuid efi_b_partuuid
  local esp_partuuid var_a_partuuid var_b_partuuid

  rootfs_a_uuid="$(derive_uuid "$ns" "rootfs-A")"
  rootfs_a_partuuid="$(derive_partuuid "$ns" "rootfs-A")"
  rootfs_b_uuid="$(derive_uuid "$ns" "rootfs-B")"
  rootfs_b_partuuid="$(derive_partuuid "$ns" "rootfs-B")"
  efi_a_partuuid="$(derive_partuuid "$ns" "efi-A")"
  efi_b_partuuid="$(derive_partuuid "$ns" "efi-B")"
  esp_partuuid="$(derive_partuuid "$ns" "esp")"
  var_a_partuuid="$(derive_partuuid "$ns" "var-A")"
  var_b_partuuid="$(derive_partuuid "$ns" "var-B")"

  cat >"$metadata_dir/topology.json" <<TOPOLOGY_EOF
{
  "scenario": "${scenario}",
  "current_slot": "${current_slot}",
  "target_slot": "${target_slot}",
  "namespace": "${ns}",
  "partitions": {
    "rootfs-A": {
      "type": "btrfs",
      "uuid": "${rootfs_a_uuid}",
      "partuuid": "${rootfs_a_partuuid}",
      "partlabel": "rootfs-A"
    },
    "efi-A": {
      "type": "vfat",
      "partuuid": "${efi_a_partuuid}",
      "partlabel": "efi-A"
    },
    "rootfs-B": {
      "type": "btrfs",
      "uuid": "${rootfs_b_uuid}",
      "partuuid": "${rootfs_b_partuuid}",
      "partlabel": "rootfs-B"
    },
    "efi-B": {
      "type": "vfat",
      "partuuid": "${efi_b_partuuid}",
      "partlabel": "efi-B"
    },
    "esp": {
      "type": "vfat",
      "partuuid": "${esp_partuuid}",
      "partlabel": "esp"
    },
    "var-A": {
      "type": "btrfs",
      "partuuid": "${var_a_partuuid}",
      "partlabel": "var-A"
    },
    "var-B": {
      "type": "btrfs",
      "partuuid": "${var_b_partuuid}",
      "partlabel": "var-B"
    }
  },
  "partset_semantics": {
    "self": "${target_slot}",
    "other": "$([ "$target_slot" = "A" ] && echo "B" || echo "A")",
    "all": ["A", "B", "esp"],
    "shared": ["esp"]
  }
}
TOPOLOGY_EOF

  # Generate artifact manifest (lists real target paths inside EFI)
  cat >"$metadata_dir/artifact-manifest.json" <<MANIFEST_EOF
{
  "efi_artifacts": [
    "EFI/steamos/grub.cfg",
    "EFI/steamos/grubx64.efi"
  ],
  "partset_files": [
    "SteamOS/partsets/A",
    "SteamOS/partsets/B",
    "SteamOS/partsets/self",
    "SteamOS/partsets/other",
    "SteamOS/partsets/shared",
    "SteamOS/partsets/all"
  ],
  "bootconf_files": [
    "SteamOS/conf/A.conf",
    "SteamOS/conf/B.conf"
  ]
}
MANIFEST_EOF
}

# ============================================================================
# create_mock_rootfs
#
# Create mock rootfs with kernel, initramfs, GRUB configs, and os-release.
#
# create_mock_rootfs ROOTFS_DIR ROOTFS_UUID [KERNEL_VERSION]
# ============================================================================
create_mock_rootfs() {
  local rootfs_dir="${1:?create_mock_rootfs: missing rootfs_dir}"
  local rootfs_uuid="${2:?create_mock_rootfs: missing rootfs_uuid}"
  local kernel_version="${3:-6.1.52-neptune-61}"

  # Boot payload
  mkdir -p "$rootfs_dir/boot"

  # Kernel - nonempty regular file
  dd if=/dev/urandom bs=1024 count=32 \
    of="$rootfs_dir/boot/vmlinuz-${kernel_version}" 2>/dev/null

  # Initramfs - nonempty regular file
  dd if=/dev/urandom bs=1024 count=64 \
    of="$rootfs_dir/boot/initramfs-${kernel_version}.img" 2>/dev/null

  # AMD microcode initrd
  dd if=/dev/urandom bs=1024 count=16 \
    of="$rootfs_dir/boot/amd-ucode.img" 2>/dev/null

  # GRUB persistent defaults
  mkdir -p "$rootfs_dir/etc/default"
  cat >"$rootfs_dir/etc/default/grub" <<GRUB_DEFAULT_EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_UUID=true
GRUB_DEFAULT_EOF

  # SteamOS GRUB defaults (persistent parameter storage)
  cat >"$rootfs_dir/etc/default/grub-steamos" <<STEAMOS_GRUB_EOF
# SteamOS-specific GRUB configuration
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX=""
STEAMOS_GRUB_EOF

  # Atomic-update keep-list directory
  mkdir -p "$rootfs_dir/etc/atomic-update.conf.d"
  cat >"$rootfs_dir/etc/atomic-update.conf.d/keep-list.conf" <<KEEPLIST_EOF
# Files to preserve across atomic updates
/boot/vmlinuz-*
/boot/initramfs-*
/boot/amd-ucode.img
/etc/default/grub
/etc/default/grub-steamos
KEEPLIST_EOF

  # os-release
  mkdir -p "$rootfs_dir/etc"
  mkdir -p "$rootfs_dir/usr/lib"
  cat >"$rootfs_dir/usr/lib/os-release" <<OSRELEASE_EOF
NAME="SteamOS"
VERSION="3.6.22"
ID=steamos
ID_LIKE=arch
PRETTY_NAME="SteamOS 3.6.22"
VERSION_ID="3.6.22"
BUILD_ID="20260801.1"
VARIANT_ID=steampal
OSRELEASE_EOF
  ln -sf usr/lib/os-release "$rootfs_dir/etc/os-release"
}

# ============================================================================
# create_mock_partset_semantics
#
# Write self/other/all/shared partset view files into an EFI directory.
# These are the "resolved" views that the partset generator would produce.
#
# create_mock_partset_semantics EFI_DIR NAMESPACE TARGET_SLOT [SLOT_COUNT]
# ============================================================================
create_mock_partset_semantics() {
  local efi_dir="${1:?create_mock_partset_semantics: missing efi_dir}"
  local ns="${2:?create_mock_partset_semantics: missing namespace}"
  local target_slot="${3:?create_mock_partset_semantics: missing target_slot}"
  local slot_count="${4:-2}"

  local other_slot
  other_slot="$([ "$target_slot" = "A" ] && echo "B" || echo "A")"

  local target_partuuid other_partuuid esp_partuuid
  local target_rootfs_uuid other_rootfs_uuid
  local target_var_uuid other_var_uuid

  target_partuuid="$(derive_partuuid "$ns" "efi-${target_slot}")"
  other_partuuid="$(derive_partuuid "$ns" "efi-${other_slot}")"
  esp_partuuid="$(derive_partuuid "$ns" "esp")"
  target_rootfs_uuid="$(derive_partuuid "$ns" "rootfs-${target_slot}")"
  other_rootfs_uuid="$(derive_partuuid "$ns" "rootfs-${other_slot}")"
  target_var_uuid="$(derive_partuuid "$ns" "var-${target_slot}")"
  other_var_uuid="$(derive_partuuid "$ns" "var-${other_slot}")"

  # self = target slot's rootfs + efi + var
  cat >"$efi_dir/SteamOS/partsets/self" <<SELF_EOF
rootfs ${target_rootfs_uuid}
efi ${target_partuuid}
var ${target_var_uuid}
SELF_EOF

  # For single-slot Build fixtures, other may be absent or empty
  if [[ "$slot_count" -ge 2 ]]; then
    # other = opposing slot's rootfs + efi + var
    cat >"$efi_dir/SteamOS/partsets/other" <<OTHER_EOF
rootfs ${other_rootfs_uuid}
efi ${other_partuuid}
var ${other_var_uuid}
OTHER_EOF
  fi

  # all = A + B + shared (esp)
  if [[ "$slot_count" -ge 2 ]]; then
    local rootfs_a_uuid rootfs_b_uuid efi_a_uuid efi_b_uuid
    local var_a_uuid var_b_uuid
    rootfs_a_uuid="$(derive_partuuid "$ns" "rootfs-A")"
    rootfs_b_uuid="$(derive_partuuid "$ns" "rootfs-B")"
    efi_a_uuid="$(derive_partuuid "$ns" "efi-A")"
    efi_b_uuid="$(derive_partuuid "$ns" "efi-B")"
    var_a_uuid="$(derive_partuuid "$ns" "var-A")"
    var_b_uuid="$(derive_partuuid "$ns" "var-B")"

    cat >"$efi_dir/SteamOS/partsets/all" <<ALL_EOF
rootfs ${rootfs_a_uuid}
efi ${efi_a_uuid}
var ${var_a_uuid}
rootfs ${rootfs_b_uuid}
efi ${efi_b_uuid}
var ${var_b_uuid}
rootfs ${esp_partuuid}
ALL_EOF
  else
    # Single-slot: all only has A + esp
    local rootfs_a_uuid efi_a_uuid var_a_uuid
    rootfs_a_uuid="$(derive_partuuid "$ns" "rootfs-A")"
    efi_a_uuid="$(derive_partuuid "$ns" "efi-A")"
    var_a_uuid="$(derive_partuuid "$ns" "var-A")"

    cat >"$efi_dir/SteamOS/partsets/all" <<ALL_SINGLE_EOF
rootfs ${rootfs_a_uuid}
efi ${efi_a_uuid}
var ${var_a_uuid}
rootfs ${esp_partuuid}
ALL_SINGLE_EOF
  fi

  # shared = esp only
  cat >"$efi_dir/SteamOS/partsets/shared" <<SHARED_EOF
rootfs ${esp_partuuid}
SHARED_EOF
}

# ============================================================================
# create_mock_boot_fixture
#
# Create a complete mock boot fixture directory structure.
#
# create_mock_boot_fixture BASE_DIR SCENARIO TARGET_SLOT [NAMESPACE]
#
# SCENARIO    - "build", "recovery", "flashless", or "live"
# TARGET_SLOT - "A" or "B"
# NAMESPACE   - optional test ID for UUID derivation (defaults to SCENARIO-TARGET_SLOT)
#
# Produces the tree from Section 8.1:
#   base/
#   +-- rootfs/
#   +-- efi/
#   +-- esp/
#   +-- metadata/
# ============================================================================
create_mock_boot_fixture() {
  local base_dir="${1:?create_mock_boot_fixture: missing base_dir}"
  local scenario="${2:?create_mock_boot_fixture: missing scenario}"
  local target_slot="${3:?create_mock_boot_fixture: missing target_slot}"
  local ns="${4:-${scenario}-${target_slot}}"

  # Determine slot topology
  local current_slot
  current_slot="$([ "$target_slot" = "A" ] && echo "B" || echo "A")"
  local slot_count=2

  if [[ "$scenario" == "build" ]]; then
    # Build is single-slot (only A)
    current_slot="A"
    slot_count=1
    target_slot="A"
  fi

  # Derive UUIDs for target rootfs (what will be written to)
  local target_rootfs_uuid
  if [[ "$scenario" == "build" ]]; then
    target_rootfs_uuid="$(derive_uuid "$ns" "rootfs-A")"
  else
    target_rootfs_uuid="$(derive_uuid "$ns" "rootfs-${target_slot}")"
  fi

  # Create root directory structure
  mkdir -p "$base_dir"

  # 1. Create mock rootfs
  create_mock_rootfs "$base_dir/rootfs" "$target_rootfs_uuid"

  # 2. Create mock EFI partition
  _create_mock_efi "$base_dir/efi" "$target_rootfs_uuid" "$ns" "$slot_count"

  # Add partset semantics (self/other/all/shared)
  create_mock_partset_semantics "$base_dir/efi" "$ns" "$target_slot" "$slot_count"

  # 3. Create mock shared ESP
  _create_mock_esp "$base_dir/esp" "$ns" "$slot_count"

  # 4. Create metadata directory with topology and manifests
  _create_mock_topology "$base_dir/metadata" "$ns" "$scenario" "$current_slot" "$target_slot"

  # Emit fixture context for test harness consumption
  cat >"$base_dir/metadata/fixture-context.json" <<CONTEXT_EOF
{
  "scenario": "${scenario}",
  "current_slot": "${current_slot}",
  "target_slot": "${target_slot}",
  "namespace": "${ns}",
  "rootfs_dir": "${base_dir}/rootfs",
  "efi_dir": "${base_dir}/efi",
  "esp_dir": "${base_dir}/esp",
  "metadata_dir": "${base_dir}/metadata",
  "slot_count": ${slot_count},
  "target_rootfs_uuid": "${target_rootfs_uuid}"
}
CONTEXT_EOF
}

# ============================================================================
# destroy_mock_fixture
#
# Clean up a mock fixture directory.
#
# destroy_mock_fixture BASE_DIR
#
# Safety: refuses to operate on critical system paths.
# ============================================================================
destroy_mock_fixture() {
  local base_dir="${1:?destroy_mock_fixture: missing base_dir}"

  [[ -d "$base_dir" ]] || return 0

  # Safety: refuse to destroy critical paths
  local resolved
  resolved="$(realpath "$base_dir" 2>/dev/null || true)"
  case "$resolved" in
    / | /dev | /tmp | /home | /root | /var | /usr | /etc | /boot | /mnt | /media)
      echo "ERROR: destroy_mock_fixture refuses to operate on critical path: $resolved" >&2
      return 1
      ;;
  esac

  rm -rf "$base_dir"
}
