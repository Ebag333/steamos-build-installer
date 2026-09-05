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
#           lib/preflight_efi.sh (_pf_efi_canonicalize_device, _pf_efi_device_major_minor)
# Do not run it directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/preflight_system_identity.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# NOTE: This module requires _pf_efi_canonicalize_device and _pf_efi_device_major_minor
# from preflight_efi.sh, which must be sourced by the wrapper before this module.
# Do NOT source preflight_efi.sh here — it can overwrite SCRIPT_DIR and cause
# redefinition issues when sourced multiple times.

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

  # Verify the resolved path is still within the rootfs (symlink escape check).
  local canonical_os_release
  canonical_os_release="$(realpath "$os_release" 2>/dev/null)" || return 1
  local canonical_rootfs
  canonical_rootfs="$(realpath "$rootfs" 2>/dev/null)" || return 1

  case "$canonical_os_release" in
    "$canonical_rootfs"/*) ;;
    *) return 1 ;;  # Escaped the rootfs boundary
  esac

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

# _pf_si_resolve_partset_device SLOT PARTITION [TOPOLOGY_DIR]
#   Resolve $TOPOLOGY_DIR/$SLOT/$PARTITION to its canonical device.
#   Prints the canonical path on success; dies on failure.
_pf_si_resolve_partset_device() {
  local slot="${1:?_pf_si_resolve_partset_device: missing slot}"
  local partition="${2:?_pf_si_resolve_partset_device: missing partition}"
  local topology_dir="${3:-/dev/disk/by-partsets}"

  local device
  device="$(readlink -f "$topology_dir/$slot/$partition" 2>/dev/null)" \
    || die "_pf_si_resolve_partset_device: cannot resolve $topology_dir/$slot/$partition"

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

# _pf_si_parse_partset_file FILE
#   Parse a SteamOS partset file in "role PARTUUID" format.
#   Each non-comment, non-empty line contains: role PARTUUID
#   Prints "role=PARTUUID" pairs, one per line.
#   Returns 0 on success, 1 on empty/invalid file.
_pf_si_parse_partset_file() {
  local file="${1:?_pf_si_parse_partset_file: missing file path}"

  if [[ ! -f "$file" || ! -s "$file" ]]; then
    return 1
  fi

  local line
  while IFS= read -r line; do
    # Skip empty lines and comments.
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    # Parse "role PARTUUID" format.
    local role partuuid
    if [[ "$line" =~ ^[[:space:]]*([a-zA-Z0-9_-]+)[[:space:]]+([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})[[:space:]]*$ ]]; then
      role="${BASH_REMATCH[1]}"
      partuuid="${BASH_REMATCH[2]}"
      echo "${role}=${partuuid}"
    elif [[ "$line" =~ ^[[:space:]]*([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})[[:space:]]*$ ]]; then
      # Plain UUID without role — treat as legacy format.
      partuuid="${BASH_REMATCH[1]}"
      echo "unknown=${partuuid}"
    else
      debug "_pf_si_parse_partset_file: skipping unparseable line: '$line' in $file"
    fi
  done <"$file"
}

# ---------------------------------------------------------------------------
# Individual checks — independently callable
# ---------------------------------------------------------------------------

# preflight_system_identity_os_release ROOTFS [EXPECTED_VARIANT] [ACCEPTED_VARIANTS]
#   PF-40: Verify the rootfs os-release declares a supported SteamOS variant
#   and architecture.
#
#   EXPECTED_VARIANT: if provided, VARIANT_ID must match (case-insensitive).
#   ACCEPTED_VARIANTS: optional space-separated list of accepted VARIANT_ID values.
#                      If provided, VARIANT_ID must be one of these values.
#                      If both EXPECTED_VARIANT and ACCEPTED_VARIANTS are provided,
#                      EXPECTED_VARIANT takes precedence.
#
#   Required fields:
#     ID=steamos          — must be SteamOS
#     VERSION_ID          — must be non-empty
#     ID_LIKE=arch        — must indicate Arch lineage
#
#   Optional:
#     BASE_ARCH           — must be x86_64 when present
#     VARIANT_ID           — validated against EXPECTED_VARIANT or ACCEPTED_VARIANTS
preflight_system_identity_os_release() {
  local rootfs="${1:?preflight_system_identity_os_release: missing rootfs path}"
  local expected_variant="${2:-}"
  local accepted_variants="${3:-}"

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

  # Parse ID_LIKE into an array (no glob expansion, controlled splitting).
  local id_like_tokens
  read -ra id_like_tokens <<< "$id_like"

  local found_arch=0
  local token
  for token in "${id_like_tokens[@]}"; do
    if [[ "${token,,}" == "arch" ]]; then
      found_arch=1
      break
    fi
  done

  if [[ "$found_arch" -eq 0 ]]; then
    die "PF-40: os-release ID_LIKE does not contain 'arch' (got '$id_like'): $rootfs"
  fi

  # --- BASE_ARCH check (preferred but not mandatory) ---
  # BASE_ARCH is not universally guaranteed in os-release.  When absent we
  # warn and continue; the GRUB x86_64-efi platform check in the build
  # pipeline is the stronger architecture gate.
  local base_arch
  base_arch="$(_pf_si_read_os_release "$rootfs" BASE_ARCH)" || base_arch=""

  if [[ -z "$base_arch" ]]; then
    warn "PF-40: os-release BASE_ARCH is empty — cannot verify architecture (expected 'x86_64'): $rootfs"
  elif [[ "${base_arch,,}" != "x86_64" ]]; then
    die "PF-40: unsupported architecture '$base_arch' (expected 'x86_64'): $rootfs"
  else
    debug "PF-40: architecture is x86_64 (BASE_ARCH=$base_arch)"
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
  elif [[ -n "${accepted_variants:-}" ]]; then
    local variant_id
    variant_id="$(_pf_si_read_os_release "$rootfs" VARIANT_ID)" || variant_id=""

    if [[ -n "$variant_id" ]]; then
      local found=0
      local av
      read -ra av_tokens <<< "$accepted_variants"
      for av in "${av_tokens[@]}"; do
        if [[ "${variant_id,,}" == "${av,,}" ]]; then
          found=1
          break
        fi
      done
      if [[ "$found" -eq 0 ]]; then
        die "PF-40: os-release VARIANT_ID '$variant_id' is not in accepted variants ($accepted_variants): $rootfs"
      fi
    fi
  fi

  debug "PF-40: os-release is a valid SteamOS variant (ID=$id VERSION_ID=$version_id BASE_ARCH=$base_arch)"
}

# preflight_system_identity_topology_complete ROOTFS [EFIMNT] [SCENARIO] [TOPOLOGY_DIR]
#   PF-41: Verify that required partitions exist for the target system.
#   The topology source defaults to /dev/disk/by-partsets but can be
#   overridden via TOPOLOGY_DIR (e.g. a loop device's topology for Build).
#
#   SCENARIO controls required slot depth:
#     build     — only declared partitions (may be A-only); if TOPOLOGY_DIR
#                 is missing this is acceptable (loop devices may not have
#                 by-partsets).
#     flashless / recovery / live (default) — require complete A/B topology.
#
#   Required per-slot partitions (for each slot dictated by SCENARIO):
#     $TOPOLOGY_DIR/{slot}/rootfs
#     $TOPOLOGY_DIR/{slot}/efi
#     $TOPOLOGY_DIR/{slot}/var
preflight_system_identity_topology_complete() {
  local rootfs="${1:?preflight_system_identity_topology_complete: missing rootfs path}"
  local efimnt="${2:-}"
  local scenario="${3:-}"
  local topology_dir="${4:-/dev/disk/by-partsets}"

  if [[ ! -d "$topology_dir" ]]; then
    case "$scenario" in
      build)
        # Build may not have by-partsets if using loop devices.
        debug "PF-41: topology directory missing ($topology_dir) — acceptable for build scenario"
        return 0
        ;;
      *)
        die "PF-41: $topology_dir does not exist — cannot validate partition topology"
        ;;
    esac
  fi

  # Determine required slots based on scenario.
  local slots
  case "$scenario" in
    build) slots="A" ;;  # Build is A-only
    *)     slots="A B" ;;  # All others require both slots
  esac

  # Check each required partition exists and resolves to a block device.
  local slot partition dev
  for slot in $slots; do
    for partition in rootfs efi var; do
      dev="$(readlink -f "$topology_dir/$slot/$partition" 2>/dev/null)" || dev=""

      if [[ -z "$dev" ]]; then
        die "PF-41: partition topology incomplete — $topology_dir/$slot/$partition does not resolve"
      fi

      if [[ ! -b "$dev" ]]; then
        die "PF-41: partition topology invalid — $topology_dir/$slot/$partition resolves to non-block-device: $dev"
      fi
    done
  done

  debug "PF-41: partition topology complete (scenario=${scenario:-live} slots=$slots)"
}

# preflight_system_identity_partition_consistent SLOT PARTITION [TOPOLOGY_DIR]
#   PF-42: Verify that PARTLABEL, partset name, PARTUUID, and the actual
#   device agree for a given slot/partition.  The PARTLABEL is expected
#   to encode the slot and partition (e.g. "rootfs-A", "efi-B").
#
#   TOPOLOGY_DIR defaults to /dev/disk/by-partsets but can be overridden.
#
#   Checks:
#     1. Device exists under $TOPOLOGY_DIR/$SLOT/$PARTITION
#     2. PARTLABEL matches the expected pattern: ${PARTITION}-${SLOT}
#     3. PARTUUID is available and non-empty
#     4. The resolved device is a valid block device
preflight_system_identity_partition_consistent() {
  local slot="${1:?preflight_system_identity_partition_consistent: missing slot}"
  local partition="${2:?preflight_system_identity_partition_consistent: missing partition}"
  local topology_dir="${3:-/dev/disk/by-partsets}"

  case "$slot" in
    A | B) ;;
    *) die "PF-42: invalid slot label: $slot" ;;
  esac

  local dev
  dev="$(_pf_si_resolve_partset_device "$slot" "$partition" "$topology_dir")"

  [[ -b "$dev" ]] \
    || die "PF-42: $topology_dir/$slot/$partition is not a block device: $dev"

  # Check PARTLABEL matches expected pattern: ${PARTITION}-${SLOT}
  local partlabel
  partlabel="$(_pf_si_get_partlabel "$dev")"

  local expected_label="${partition}-${slot}"
  if [[ "${partlabel,,}" != "${expected_label,,}" ]]; then
    die "PF-42: PARTLABEL mismatch — got '$partlabel' but expected '$expected_label' for $topology_dir/$slot/$partition ($dev)"
  fi

  # Check PARTUUID is available.
  local partuuid
  partuuid="$(_pf_si_get_partuuid "$dev")"

  [[ -n "$partuuid" ]] \
    || die "PF-42: PARTUUID is empty for $topology_dir/$slot/$partition ($dev)"

  debug "PF-42: partition identity consistent (slot=$slot partition=$partition label=$partlabel partuuid=$partuuid device=$dev)"
}

# preflight_system_identity_no_cross_slot_alias [TOPOLOGY_DIR]
#   PF-43: Verify that all partition devices across slots A and B are
#   distinct.  Checks both major:minor identity and PARTUUID to catch
#   cross-role aliases (e.g. A/rootfs == B/efi) and cloned partitions.
#   TOPOLOGY_DIR defaults to /dev/disk/by-partsets but can be overridden.
preflight_system_identity_no_cross_slot_alias() {
  local topology_dir="${1:-/dev/disk/by-partsets}"

  if [[ ! -d "$topology_dir" ]]; then
    debug "PF-43: topology directory missing ($topology_dir) — skipping cross-slot alias check"
    return 0
  fi

  # Build lists of all device identity pairs (major:minor + PARTUUID).
  local -a all_mm=()
  local -a all_uuid=()
  local -a all_labels=()
  local slot partition dev mm uuid label

  for slot in A B; do
    for partition in rootfs efi var verity; do
      dev="$(readlink -f "$topology_dir/$slot/$partition" 2>/dev/null)" || continue
      [[ -b "$dev" ]] || continue

      label="${slot}/${partition}"

      # Get major:minor via stat (hex format from device node).
      mm=""
      local dev_t
      dev_t="$(stat -c '%t:%T' "$dev" 2>/dev/null)" || dev_t=""
      if [[ -n "$dev_t" ]]; then
        local major_hex="${dev_t%%:*}" minor_hex="${dev_t##*:}"
        mm="$((16#${major_hex})):$((16#${minor_hex}))"
      fi

      # Get PARTUUID via blkid.
      uuid="$(blkid -s PARTUUID -o value "$dev" 2>/dev/null)" || uuid=""

      # Check for major:minor collision with any previously seen device.
      if [[ -n "$mm" ]]; then
        local i
        for ((i=0; i<${#all_mm[@]}; i++)); do
          if [[ "${all_mm[$i]}" == "$mm" ]]; then
            die "PF-43: duplicate device identity — $label shares major:minor $mm with ${all_labels[$i]}"
          fi
        done
      fi

      # Check for PARTUUID collision with any previously seen device.
      if [[ -n "$uuid" ]]; then
        local i
        for ((i=0; i<${#all_uuid[@]}; i++)); do
          if [[ "${all_uuid[$i],,}" == "${uuid,,}" ]]; then
            die "PF-43: duplicate PARTUUID — $label shares PARTUUID $uuid with ${all_labels[$i]}"
          fi
        done
      fi

      all_mm+=("$mm")
      all_uuid+=("$uuid")
      all_labels+=("$label")
    done
  done

  debug "PF-43: no cross-slot aliasing detected (${#all_labels[@]} devices checked)"
}

# preflight_system_identity_partset_map EFIMNT [SELF_SLOT] [TOPOLOGY_DIR]
#   PF-44: Verify the current-slot partset map at $EFIMNT/SteamOS/partsets/.
#   Entries A, B, self, and other must be regular files parseable by
#   _pf_si_parse_partset_file.  Each role=PARTUUID pair is validated.
#
#   SELF_SLOT, when provided, is the explicit slot label for the self side
#   (e.g. "A" or "B").  When empty, self/other validation is skipped.
#   TOPOLOGY_DIR defaults to /dev/disk/by-partsets.
preflight_system_identity_partset_map() {
  local efimnt="${1:-/efi}"
  local self_slot="${2:-}"
  local topology_dir="${3:-/dev/disk/by-partsets}"

  local partsets_dir="$efimnt/SteamOS/partsets"

  if [[ ! -d "$partsets_dir" ]]; then
    die "PF-44: partset map directory missing: $partsets_dir"
  fi

  # --- Helper: resolve a PARTUUID to a device ---
  _pf_si_resolve_partuuid() {
    local uuid="$1"
    local resolved
    resolved="$(readlink -f "/dev/disk/by-partuuid/$uuid" 2>/dev/null)" || return 1
    [[ -b "$resolved" ]] || return 1
    echo "$resolved"
  }

  # --- Helper: get the device identity (major:minor) for a slot/partition ---
  _pf_si_slot_device_mm() {
    local slot="$1" partition="$2"
    local dev
    dev="$(readlink -f "$topology_dir/$slot/$partition" 2>/dev/null)" || return 1
    [[ -b "$dev" ]] || return 1
    stat -c '%t:%T' "$dev" 2>/dev/null | {
      read -r hex
      local major_hex="${hex%%:*}" minor_hex="${hex##*:}"
      printf '%d:%d' "$((16#${major_hex}))" "$((16#${minor_hex}))"
    }
  }

  # --- Helper: enumerate devices with a given PARTUUID and count them ---
  _pf_si_partuuid_unique() {
    local uuid="$1"
    local count=0
    local dev
    for dev in /dev/sd? /dev/nvme?n?p? /dev/mmcblk?p? /dev/loop?; do
      [[ -b "$dev" ]] || continue
      local dev_uuid
      dev_uuid="$(blkid -s PARTUUID -o value "$dev" 2>/dev/null)" || continue
      if [[ "${dev_uuid,,}" == "${uuid,,}" ]]; then
        count=$((count + 1))
      fi
    done
    echo "$count"
  }

  # --- Parse slot files (A, B) ---
  for slot in A B; do
    local entry="$partsets_dir/$slot"
    if [[ ! -f "$entry" ]]; then
      debug "PF-44: partset entry '$slot' not present (acceptable for single-slot)"
      continue
    fi

    local parsed
    parsed="$(_pf_si_parse_partset_file "$entry")" || die "PF-44: partset entry '$slot' is empty or invalid: $entry"

    # Validate each role-PARTUUID pair.
    local pair role uuid
    while IFS= read -r pair; do
      role="${pair%%=*}"
      uuid="${pair#*=}"

      # Verify the PARTUUID resolves to a block device.
      local resolved
      if ! resolved="$(_pf_si_resolve_partuuid "$uuid")"; then
        die "PF-44: partset '$slot' role '$role' PARTUUID '$uuid' does not resolve to a block device"
      fi

      # Verify PARTUUID uniqueness (detect clones).
      local count
      count="$(_pf_si_partuuid_unique "$uuid")"
      if [[ "$count" -gt 1 ]]; then
        die "PF-44: ambiguous duplicate device -- $count devices share PARTUUID $uuid (slot=$slot role=$role)"
      fi

      debug "PF-44: partset '$slot' role='$role' uuid=$uuid device=$resolved"
    done <<< "$parsed"
  done

  # --- Validate self entry ---
  if [[ -n "$self_slot" ]]; then
    local self_entry="$partsets_dir/self"
    if [[ -f "$self_entry" ]]; then
      local self_parsed
      self_parsed="$(_pf_si_parse_partset_file "$self_entry")" \
        || die "PF-44: partset 'self' is empty or invalid: $self_entry"

      # Parse self's role mappings.
      local -A self_roles=()
      local pair
      while IFS= read -r pair; do
        local role="${pair%%=*}" uuid="${pair#*=}"
        self_roles["$role"]="$uuid"
      done <<< "$self_parsed"

      # Compare against the expected slot's topology.
      for role in rootfs efi var; do
        local self_uuid="${self_roles[$role]:-}"
        if [[ -z "$self_uuid" ]]; then
          debug "PF-44: partset 'self' has no '$role' entry (may be incomplete)"
          continue
        fi

        # Get the expected device's PARTUUID from topology.
        local expected_dev
        expected_dev="$(readlink -f "$topology_dir/$self_slot/$role" 2>/dev/null)" || expected_dev=""
        if [[ -n "$expected_dev" && -b "$expected_dev" ]]; then
          local expected_uuid
          expected_uuid="$(blkid -s PARTUUID -o value "$expected_dev" 2>/dev/null)" || expected_uuid=""
          if [[ -n "$expected_uuid" && "${self_uuid,,}" != "${expected_uuid,,}" ]]; then
            die "PF-44: partset 'self' role '$role' ($self_uuid) does not match expected $self_slot/$role ($expected_uuid)"
          fi
        fi
      done

      debug "PF-44: partset 'self' matches expected slot $self_slot"
    else
      die "PF-44: partset 'self' entry missing: $self_entry"
    fi
  else
    debug "PF-44: no self_slot provided -- skipping self validation"
  fi

  # --- Validate other entry ---
  if [[ -n "$self_slot" ]]; then
    local other_slot
    case "$self_slot" in
      A) other_slot="B" ;;
      B) other_slot="A" ;;
      *) other_slot="" ;;
    esac

    if [[ -n "$other_slot" ]]; then
      local other_entry="$partsets_dir/other"
      if [[ -f "$other_entry" ]]; then
        local other_parsed
        other_parsed="$(_pf_si_parse_partset_file "$other_entry")" \
          || die "PF-44: partset 'other' is empty or invalid: $other_entry"

        local -A other_roles=()
        local pair
        while IFS= read -r pair; do
          local role="${pair%%=*}" uuid="${pair#*=}"
          other_roles["$role"]="$uuid"
        done <<< "$other_parsed"

        for role in rootfs efi var; do
          local other_uuid="${other_roles[$role]:-}"
          if [[ -z "$other_uuid" ]]; then
            debug "PF-44: partset 'other' has no '$role' entry (may be incomplete)"
            continue
          fi

          local expected_dev
          expected_dev="$(readlink -f "$topology_dir/$other_slot/$role" 2>/dev/null)" || expected_dev=""
          if [[ -n "$expected_dev" && -b "$expected_dev" ]]; then
            local expected_uuid
            expected_uuid="$(blkid -s PARTUUID -o value "$expected_dev" 2>/dev/null)" || expected_uuid=""
            if [[ -n "$expected_uuid" && "${other_uuid,,}" != "${expected_uuid,,}" ]]; then
              die "PF-44: partset 'other' role '$role' ($other_uuid) does not match expected $other_slot/$role ($expected_uuid)"
            fi
          fi
        done

        debug "PF-44: partset 'other' matches expected slot $other_slot"
      else
        warn "PF-44: partset 'other' entry missing: $other_entry"
      fi
    fi
  fi

  debug "PF-44: partset map is valid at $partsets_dir"
}

# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

# preflight_system_identity_validate ROOTFS [EFIMNT] [EXPECTED_VARIANT] [SCENARIO] [TOPOLOGY_DIR] [SELF_SLOT] [ACCEPTED_VARIANTS]
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
#     SCENARIO         — (optional) "build", "flashless", "recovery", or "live" (default)
#     TOPOLOGY_DIR     — (optional) partition topology directory (default: /dev/disk/by-partsets)
#     SELF_SLOT        — (optional) explicit slot label ("A" or "B") for self/other validation
#     ACCEPTED_VARIANTS — (optional) space-separated list of accepted VARIANT_ID values
#                         (e.g. "steamdeck steamdeck-oobe"); ignored when EXPECTED_VARIANT is set
preflight_system_identity_validate() {
  local rootfs="${1:?preflight_system_identity_validate: missing rootfs path}"
  local efimnt="${2:-/efi}"
  local expected_variant="${3:-}"
  local scenario="${4:-}"
  local topology_dir="${5:-/dev/disk/by-partsets}"
  local self_slot="${6:-}"
  local accepted_variants="${7:-}"

  debug "preflight_system_identity_validate: validating rootfs=$rootfs efimnt=$efimnt expected_variant=${expected_variant:-<none>} scenario=${scenario:-live} topology_dir=$topology_dir"

  # PF-40: os-release declares supported SteamOS variant/architecture.
  preflight_system_identity_os_release "$rootfs" "$expected_variant" "$accepted_variants"

  # PF-41: Required partitions exist (rootfs/efi/var per slot).
  preflight_system_identity_topology_complete "$rootfs" "$efimnt" "$scenario" "$topology_dir"

  # PF-42: PARTLABEL/partset/PARTUUID/device agree for each slot/partition.
  local slots
  case "$scenario" in
    build) slots="A" ;;
    *)     slots="A B" ;;
  esac

  local slot partition
  for slot in $slots; do
    for partition in rootfs efi var; do
      # Only check partitions that actually exist in the topology.
      if [[ -L "$topology_dir/$slot/$partition" ]]; then
        preflight_system_identity_partition_consistent "$slot" "$partition" "$topology_dir"
      fi
    done
  done

  # PF-43: No cross-slot aliasing.
  preflight_system_identity_no_cross_slot_alias "$topology_dir"

  # PF-44: /efi/SteamOS/partsets/ entries valid.
  preflight_system_identity_partset_map "$efimnt" "$self_slot" "$topology_dir"

  debug "preflight_system_identity_validate: all system identity checks passed"
}
