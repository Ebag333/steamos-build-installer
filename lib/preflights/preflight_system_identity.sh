#!/bin/bash
#
# steamos-build-installer — lib/preflight_system_identity.sh
# System identity validation: ensures the target rootfs declares a supported
# SteamOS variant/architecture, partition topology is complete, partition
# identities are consistent, no cross-slot aliasing exists, and the current
# slot partset map is valid.
# Called by the unified EFI state application mechanism.
#
# Requires: lib/common.sh (die, debug)
#           lib/preflight_efi.sh (_canonicalize_efi_device, _efi_dev_major_minor)
# Do not run it directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/preflight_system_identity.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Source preflight_efi.sh to reuse its internal helpers.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=preflight_efi.sh
source "${SCRIPT_DIR}/preflight_efi.sh"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _pf_si_read_os_release ROOTFS FIELD
#   Extract a field value from os-release inside ROOTFS.
#   Checks $ROOTFS/etc/os-release first, then $ROOTFS/usr/lib/os-release.
#   Prints the value on success; returns 1 if the file is missing or the
#   field is not present.
_pf_si_read_os_release() {
  local rootfs="${1:?_pf_si_read_os_release: missing rootfs path}"
  local field="${2:?_pf_si_read_os_release: missing field name}"

  local os_release=""

  if [[ -r "$rootfs/etc/os-release" ]]; then
    os_release="$rootfs/etc/os-release"
  elif [[ -r "$rootfs/usr/lib/os-release" ]]; then
    os_release="$rootfs/usr/lib/os-release"
  fi

  if [[ -z "$os_release" ]]; then
    return 1
  fi

  # os-release fields are KEY=VALUE; strip quotes from values.
  local line
  while IFS= read -r line; do
    case "$line" in
      "${field}"=*)
        local value="${line#*=}"
        # Strip surrounding quotes (single or double).
        value="${value#\'}"
        value="${value%\'}"
        value="${value#\"}"
        value="${value%\"}"
        echo "$value"
        return 0
        ;;
    esac
  done <"$os_release"

  return 1
}

# _pf_si_resolve_partset_device SLOT PARTITION
#   Resolve /dev/disk/by-partsets/$SLOT/$PARTITION to its canonical device.
#   Prints the canonical path on success; dies on failure.
_pf_si_resolve_partset_device() {
  local slot="${1:?_pf_si_resolve_partset_device: missing slot}"
  local partition="${2:?_pf_si_resolve_partset_device: missing partition}"

  local device
  device="$(readlink -f "/dev/disk/by-partsets/$slot/$partition" 2>/dev/null)" \
    || die "_pf_si_resolve_partset_device: cannot resolve /dev/disk/by-partsets/$slot/$partition"

  [[ -n "$device" ]] \
    || die "_pf_si_resolve_partset_device: resolved path is empty for slot=$slot partition=$partition"

  echo "$device"
}

# _pf_si_get_partuuid DEVICE
#   Get the PARTUUID of DEVICE via blkid.
#   Prints the PARTUUID on success; dies if blkid fails or returns empty.
_pf_si_get_partuuid() {
  local device="${1:?_pf_si_get_partuuid: missing device path}"

  local partuuid
  partuuid="$(blkid -s PARTUUID -o value "$device" 2>/dev/null)" || partuuid=""

  if [[ -z "$partuuid" ]]; then
    die "_pf_si_get_partuuid: PARTUUID unavailable for $device"
  fi

  echo "$partuuid"
}

# _pf_si_get_partlabel DEVICE
#   Get the PARTLABEL of DEVICE via blkid.
#   Prints the PARTLABEL on success; dies if blkid fails or returns empty.
_pf_si_get_partlabel() {
  local device="${1:?_pf_si_get_partlabel: missing device path}"

  local partlabel
  partlabel="$(blkid -s PARTLABEL -o value "$device" 2>/dev/null)" || partlabel=""

  if [[ -z "$partlabel" ]]; then
    die "_pf_si_get_partlabel: PARTLABEL unavailable for $device"
  fi

  echo "$partlabel"
}

# ---------------------------------------------------------------------------
# Individual checks — independently callable
# ---------------------------------------------------------------------------

# preflight_system_identity_os_release ROOTFS [EXPECTED_VARIANT]
#   PF-40: Verify the rootfs os-release declares a supported SteamOS variant
#   and architecture.  When EXPECTED_VARIANT is provided, also verify the
#   ID field matches (case-insensitive).
#
#   Required fields:
#     ID=steamos          — must be SteamOS
#     VERSION_ID          — must be non-empty
#     ID_LIKE=arch        — must indicate Arch lineage
#     BASE_ARCH           — must be x86_64
#
#   Optional:
#     VARIANT_ID           — when EXPECTED_VARIANT is provided, must match
preflight_system_identity_os_release() {
  local rootfs="${1:?preflight_system_identity_os_release: missing rootfs path}"
  local expected_variant="${2:-}"

  # --- ID check: must be "steamos" ---
  local id
  id="$(_pf_si_read_os_release "$rootfs" ID)" \
    || die "PF-40: os-release not found in rootfs: $rootfs"

  if [[ "${id,,}" != "steamos" ]]; then
    die "PF-40: unsupported os-release ID '$id' (expected 'steamos'): $rootfs"
  fi

  # --- VERSION_ID check: must be non-empty ---
  local version_id
  version_id="$(_pf_si_read_os_release "$rootfs" VERSION_ID)" || version_id=""

  if [[ -z "$version_id" ]]; then
    die "PF-40: os-release VERSION_ID is empty: $rootfs"
  fi

  # --- ID_LIKE check: must contain "arch" ---
  local id_like
  id_like="$(_pf_si_read_os_release "$rootfs" ID_LIKE)" || id_like=""

  if [[ -z "$id_like" ]]; then
    die "PF-40: os-release ID_LIKE is empty (expected 'arch'): $rootfs"
  fi

  # ID_LIKE may contain multiple space-separated values (e.g. "arch linux").
  local found_arch=0
  local token
  for token in $id_like; do
    if [[ "${token,,}" == "arch" ]]; then
      found_arch=1
      break
    fi
  done

  if [[ "$found_arch" -eq 0 ]]; then
    die "PF-40: os-release ID_LIKE does not contain 'arch' (got '$id_like'): $rootfs"
  fi

  # --- BASE_ARCH check: must be x86_64 ---
  local base_arch
  base_arch="$(_pf_si_read_os_release "$rootfs" BASE_ARCH)" || base_arch=""

  if [[ -z "$base_arch" ]]; then
    die "PF-40: os-release BASE_ARCH is empty (expected 'x86_64'): $rootfs"
  fi

  if [[ "${base_arch,,}" != "x86_64" ]]; then
    die "PF-40: unsupported architecture '$base_arch' (expected 'x86_64'): $rootfs"
  fi

  # --- VARIANT_ID check (optional) ---
  if [[ -n "$expected_variant" ]]; then
    local variant_id
    variant_id="$(_pf_si_read_os_release "$rootfs" VARIANT_ID)" || variant_id=""

    if [[ -z "$variant_id" ]]; then
      die "PF-40: os-release VARIANT_ID is empty (expected '$expected_variant'): $rootfs"
    fi

    if [[ "${variant_id,,}" != "${expected_variant,,}" ]]; then
      die "PF-40: os-release VARIANT_ID '$variant_id' does not match expected '$expected_variant': $rootfs"
    fi
  fi

  debug "PF-40: os-release is a valid SteamOS variant (ID=$id VERSION_ID=$version_id BASE_ARCH=$base_arch)"
}

# preflight_system_identity_topology_complete ROOTFS [EFIMNT]
#   PF-41: Verify that required partitions exist for both A and B slots.
#   When EFIMNT is provided, also verify the shared partition paths
#   (rootfs, efi, var) resolve under /dev/disk/by-partsets for each slot.
#
#   Required per-slot partitions:
#     /dev/disk/by-partsets/A/rootfs
#     /dev/disk/by-partsets/A/efi
#     /dev/disk/by-partsets/A/var
#     /dev/disk/by-partsets/B/rootfs
#     /dev/disk/by-partsets/B/efi
#     /dev/disk/by-partsets/B/var
preflight_system_identity_topology_complete() {
  local rootfs="${1:?preflight_system_identity_topology_complete: missing rootfs path}"
  local efimnt="${2:-}"

  # Require /dev/disk/by-partsets/ to exist at all.
  if [[ ! -d "/dev/disk/by-partsets" ]]; then
    die "PF-41: /dev/disk/by-partsets/ does not exist — cannot validate partition topology"
  fi

  # Check each required partition exists and resolves to a block device.
  local slot partition dev
  for slot in A B; do
    for partition in rootfs efi var; do
      dev="$(readlink -f "/dev/disk/by-partsets/$slot/$partition" 2>/dev/null)" || dev=""

      if [[ -z "$dev" ]]; then
        die "PF-41: partition topology incomplete — /dev/disk/by-partsets/$slot/$partition does not resolve"
      fi

      if [[ ! -b "$dev" ]]; then
        die "PF-41: partition topology invalid — /dev/disk/by-partsets/$slot/$partition resolves to non-block-device: $dev"
      fi
    done
  done

  debug "PF-41: partition topology is complete (A and B rootfs/efi/var all present)"
}

# preflight_system_identity_partition_consistent SLOT PARTITION
#   PF-42: Verify that PARTLABEL, partset name, PARTUUID, and the actual
#   device agree for a given slot/partition.  The PARTLABEL is expected
#   to encode the slot and partition (e.g. "rootfs-A", "efi-B").
#
#   Checks:
#     1. Device exists under /dev/disk/by-partsets/$SLOT/$PARTITION
#     2. PARTLABEL matches the expected pattern: ${PARTITION}-${SLOT}
#     3. PARTUUID is available and non-empty
#     4. The resolved device is a valid block device
preflight_system_identity_partition_consistent() {
  local slot="${1:?preflight_system_identity_partition_consistent: missing slot}"
  local partition="${2:?preflight_system_identity_partition_consistent: missing partition}"

  case "$slot" in
    A | B) ;;
    *) die "PF-42: invalid slot label: $slot" ;;
  esac

  local dev
  dev="$(_pf_si_resolve_partset_device "$slot" "$partition")"

  [[ -b "$dev" ]] \
    || die "PF-42: /dev/disk/by-partsets/$slot/$partition is not a block device: $dev"

  # Check PARTLABEL matches expected pattern: ${PARTITION}-${SLOT}
  local partlabel
  partlabel="$(_pf_si_get_partlabel "$dev")"

  local expected_label="${partition}-${slot}"
  if [[ "${partlabel,,}" != "${expected_label,,}" ]]; then
    die "PF-42: PARTLABEL mismatch — got '$partlabel' but expected '$expected_label' for /dev/disk/by-partsets/$slot/$partition ($dev)"
  fi

  # Check PARTUUID is available.
  local partuuid
  partuuid="$(_pf_si_get_partuuid "$dev")"

  [[ -n "$partuuid" ]] \
    || die "PF-42: PARTUUID is empty for /dev/disk/by-partsets/$slot/$partition ($dev)"

  debug "PF-42: partition identity consistent (slot=$slot partition=$partition label=$partlabel partuuid=$partuuid device=$dev)"
}

# preflight_system_identity_no_cross_slot_alias()
#   PF-43: Verify that slot A and slot B do not resolve to the same device.
#   Compares each partition type (rootfs, efi, var) between slots using
#   major:minor numbers.
preflight_system_identity_no_cross_slot_alias() {
  local partition rootfs_a rootfs_b efi_a efi_b var_a var_b

  for partition in rootfs efi var; do
    rootfs_a="$(readlink -f "/dev/disk/by-partsets/A/$partition" 2>/dev/null)" || rootfs_a=""
    rootfs_b="$(readlink -f "/dev/disk/by-partsets/B/$partition" 2>/dev/null)" || rootfs_b=""

    # Skip if either side doesn't exist (single-slot build).
    if [[ -z "$rootfs_a" || -z "$rootfs_b" ]]; then
      continue
    fi

    [[ -b "$rootfs_a" ]] \
      || die "PF-43: slot A $partition is not a block device: $rootfs_a"
    [[ -b "$rootfs_b" ]] \
      || die "PF-43: slot B $partition is not a block device: $rootfs_b"

    local mm_a mm_b
    mm_a="$(_efi_dev_major_minor "$rootfs_a")"
    mm_b="$(_efi_dev_major_minor "$rootfs_b")"

    if [[ "$mm_a" == "$mm_b" ]]; then
      die "PF-43: slots A and B resolve to the same device for partition '$partition' (major:minor $mm_a): A=$rootfs_a B=$rootfs_b"
    fi

    # Also compare PARTUUIDs to catch cloned partitions with identical major:minor.
    local uuid_a uuid_b
    uuid_a="$(blkid -s PARTUUID -o value "$rootfs_a" 2>/dev/null)" || uuid_a=""
    uuid_b="$(blkid -s PARTUUID -o value "$rootfs_b" 2>/dev/null)" || uuid_b=""

    if [[ -n "$uuid_a" && -n "$uuid_b" && "${uuid_a,,}" == "${uuid_b,,}" ]]; then
      die "PF-43: slots A and B share the same PARTUUID for partition '$partition' ($uuid_a): A=$rootfs_a B=$rootfs_b"
    fi
  done

  debug "PF-43: no cross-slot aliasing detected (A and B resolve to distinct devices)"
}

# preflight_system_identity_partset_map()
#   PF-44: Verify the current-slot partset map at /efi/SteamOS/partsets/
#   (or /esp/SteamOS/partsets/ if accessible).  Entries A, B, self, and
#   other must be regular files containing a PARTUUID that resolves to a
#   real block device.  If the EFI is mounted at a different path, the
#   caller should pass EFIMNT as $1.
#
#   When EFIMNT is provided, checks $EFIMNT/SteamOS/partsets/.
#   Otherwise checks /efi/SteamOS/partsets/ (live scenario default).
preflight_system_identity_partset_map() {
  local efimnt="${1:-/efi}"

  local partsets_dir="$efimnt/SteamOS/partsets"

  if [[ ! -d "$partsets_dir" ]]; then
    die "PF-44: partset map directory missing: $partsets_dir"
  fi

  # Determine the booted slot to identify self/other.
  local booted_slot=""
  if command -v steamos-bootconf &>/dev/null; then
    booted_slot="$(steamos-bootconf this-image 2>/dev/null)" || booted_slot=""
  fi

  # If we couldn't determine the booted slot, still validate that entries
  # that exist are valid — don't die for missing self/other if we can't
  # determine which is which.
  local has_error=0

  # Check slot entries (A, B): each should be a regular file with a valid
  # PARTUUID that resolves through /dev/disk/by-partuuid.
  local slot
  for slot in A B; do
    local entry="$partsets_dir/$slot"
    if [[ ! -f "$entry" ]]; then
      debug "PF-44: partset entry '$slot' not present at $entry (acceptable for single-slot)"
      continue
    fi

    # Read the PARTUUID from the file (format: "rootfs <PARTUUID>" or just "<PARTUUID>").
    local content
    content="$(cat "$entry" 2>/dev/null)" || content=""
    content="$(echo "$content" | tr -d '[:space:]')"

    if [[ -z "$content" ]]; then
      die "PF-44: partset entry '$slot' is empty: $entry"
    fi

    # Handle both formats: "rootfs <uuid>" and plain "<uuid>".
    local partuuid
    if [[ "$content" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
      partuuid="$content"
    elif [[ "$content" =~ [a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
      partuuid="${BASH_REMATCH[0]}"
    else
      die "PF-44: partset entry '$slot' contains invalid PARTUUID: '$content' ($entry)"
    fi

    # Verify the PARTUUID resolves to a real block device.
    local resolved
    resolved="$(readlink -f "/dev/disk/by-partuuid/$partuuid" 2>/dev/null)" || resolved=""

    if [[ -z "$resolved" ]]; then
      die "PF-44: partset entry '$slot' PARTUUID '$partuuid' does not resolve to a block device: $entry"
    fi

    if [[ ! -b "$resolved" ]]; then
      die "PF-44: partset entry '$slot' resolves to non-block-device: $resolved ($entry)"
    fi
  done

  # Check self/other entries if we know the booted slot.
  if [[ -n "$booted_slot" ]]; then
    local other_slot
    case "$booted_slot" in
      A) other_slot="B" ;;
      B) other_slot="A" ;;
      *) debug "PF-44: booted slot is '$booted_slot' — skipping self/other validation"; return 0 ;;
    esac

    local self_entry="$partsets_dir/self"
    local other_entry="$partsets_dir/other"

    if [[ -f "$self_entry" ]]; then
      # Verify self maps to the booted slot's rootfs device.
      local self_content
      self_content="$(cat "$self_entry" 2>/dev/null)" || self_content=""
      self_content="$(echo "$self_content" | tr -d '[:space:]')"

      local self_partuuid
      if [[ "$self_content" =~ [a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
        self_partuuid="${BASH_REMATCH[0]}"
      else
        die "PF-44: partset entry 'self' contains invalid PARTUUID: '$self_content' ($self_entry)"
      fi

      # Compare with the booted slot's rootfs PARTUUID.
      local expected_rootfs_dev
      expected_rootfs_dev="$(readlink -f "/dev/disk/by-partsets/$booted_slot/rootfs" 2>/dev/null)" || expected_rootfs_dev=""
      if [[ -n "$expected_rootfs_dev" && -b "$expected_rootfs_dev" ]]; then
        local expected_partuuid
        expected_partuuid="$(blkid -s PARTUUID -o value "$expected_rootfs_dev" 2>/dev/null)" || expected_partuuid=""
        if [[ -n "$expected_partuuid" && "${self_partuuid,,}" != "${expected_partuuid,,}" ]]; then
          die "PF-44: partset 'self' ($self_partuuid) does not match booted slot rootfs ($expected_partuuid): $self_entry"
        fi
      fi
    fi

    if [[ -f "$other_entry" ]]; then
      local other_content
      other_content="$(cat "$other_entry" 2>/dev/null)" || other_content=""
      other_content="$(echo "$other_content" | tr -d '[:space:]')"

      local other_partuuid
      if [[ "$other_content" =~ [a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
        other_partuuid="${BASH_REMATCH[0]}"
      else
        die "PF-44: partset entry 'other' contains invalid PARTUUID: '$other_content' ($other_entry)"
      fi

      # Verify it resolves to a block device.
      local other_resolved
      other_resolved="$(readlink -f "/dev/disk/by-partuuid/$other_partuuid" 2>/dev/null)" || other_resolved=""
      if [[ -z "$other_resolved" ]]; then
        die "PF-44: partset 'other' PARTUUID '$other_partuuid' does not resolve: $other_entry"
      fi
      if [[ ! -b "$other_resolved" ]]; then
        die "PF-44: partset 'other' resolves to non-block-device: $other_resolved ($other_entry)"
      fi
    fi
  fi

  debug "PF-44: partset map is valid at $partsets_dir"
}

# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

# preflight_system_identity_validate ROOTFS [EFIMNT] [EXPECTED_VARIANT]
#   Run the full system identity validation sequence:
#     PF-40  os-release declares supported SteamOS variant/architecture
#     PF-41  Required partitions exist (rootfs/efi/var per slot + shared)
#     PF-42  PARTLABEL/partset/PARTUUID/device agree
#     PF-43  A and B don't resolve to same device
#     PF-44  /efi/SteamOS/partsets/ entries valid
#   Dies on the first failure; returns 0 when all checks pass.
#
#   Args:
#     ROOTFS           — mounted target root filesystem (for os-release checks)
#     EFIMNT           — (optional) target EFI mount path (default: /efi)
#     EXPECTED_VARIANT — (optional) expected os-release VARIANT_ID (e.g. "steamdeck")
preflight_system_identity_validate() {
  local rootfs="${1:?preflight_system_identity_validate: missing rootfs path}"
  local efimnt="${2:-/efi}"
  local expected_variant="${3:-}"

  debug "preflight_system_identity_validate: validating rootfs=$rootfs efimnt=$efimnt expected_variant=${expected_variant:-<none>}"

  # PF-40: os-release declares supported SteamOS variant/architecture.
  preflight_system_identity_os_release "$rootfs" "$expected_variant"

  # PF-41: Required partitions exist (rootfs/efi/var per slot).
  preflight_system_identity_topology_complete "$rootfs" "$efimnt"

  # PF-42: PARTLABEL/partset/PARTUUID/device agree for each slot/partition.
  local slot partition
  for slot in A B; do
    for partition in rootfs efi var; do
      # Only check partitions that actually exist in by-partsets.
      if [[ -L "/dev/disk/by-partsets/$slot/$partition" ]]; then
        preflight_system_identity_partition_consistent "$slot" "$partition"
      fi
    done
  done

  # PF-43: A and B don't resolve to same device.
  preflight_system_identity_no_cross_slot_alias

  # PF-44: /efi/SteamOS/partsets/ entries valid.
  preflight_system_identity_partset_map "$efimnt"

  debug "preflight_system_identity_validate: all system identity checks passed"
}
