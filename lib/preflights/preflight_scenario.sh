#!/bin/bash
#
# steamos-build-installer — lib/preflight_scenario.sh
# Scenario-specific preflight validation: validates slot identity, device
# co-location, and boot configuration consistency for each deployment
# scenario (build, flashless, recovery, live).
#
# Ensures the system state is safe before any destructive operation begins.
# Dies on the first fatal check failure — no partial state.
#
# Requires: lib/common.sh (die, debug, warn)
# Do not run it directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/preflight_scenario.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _pf_get_major_minor DEVICE
#   Return the decimal major:minor number pair for a block device.
#   Uses stat to extract device numbers. Dies on failure.
_pf_get_major_minor() {
  local device="${1:?_pf_get_major_minor: missing device path}"

  [[ -b "$device" ]] \
    || die "_pf_get_major_minor: not a block device: $device"

  local dev_t
  dev_t="$(stat -c '%t:%T' "$device" 2>/dev/null)" \
    || die "_pf_get_major_minor: stat failed for '$device'"

  # stat prints hex; convert to decimal for reliable comparison.
  local major_hex minor_hex major_dec minor_dec
  major_hex="${dev_t%%:*}"
  minor_hex="${dev_t##*:}"
  major_dec="$((16#${major_hex}))"
  minor_dec="$((16#${minor_hex}))"

  echo "${major_dec}:${minor_dec}"
}

# _pf_resolve_parent_disk DEVICE
#   Determine the parent disk of a partition using lsblk PKNAME.
#   Walks up the PKNAME ancestry until a whole disk (no parent) is found.
#   Handles all device types correctly:
#     NVMe:        nvme0n1p2 → nvme0n1
#     SATA/USB:    sda2 → sda
#     Loop:        loop0p1 → loop0
#     MMC:         mmcblk0p1 → mmcblk0
#     Device-mapper: dm-0 → resolves to actual backing disk
#   Prints the parent disk basename (e.g. "nvme0n1", "sda").
#   Dies if the parent cannot be determined.
# lint-ignore: private-funcs
_pf_resolve_parent_disk() {
  local device="${1:?_pf_resolve_parent_disk: missing device path}"

  [[ -b "$device" ]] \
    || die "_pf_resolve_parent_disk: not a block device: $device"

  local dev
  dev="$device"

  # Walk up the PKNAME ancestry until we reach a whole disk.
  while [[ -n "$dev" ]]; do
    local pkname
    pkname="$(lsblk -no PKNAME "$dev" 2>/dev/null | head -1)" || pkname=""

    if [[ -z "$pkname" ]]; then
      # dev is itself a whole disk (no parent).
      basename "$dev"
      return 0
    fi

    if [[ "/dev/$pkname" == "$dev" ]]; then
      # Safety: parent resolves back to self — avoid infinite loop.
      basename "$dev"
      return 0
    fi

    dev="/dev/$pkname"
  done

  die "_pf_resolve_parent_disk: could not determine parent of '$device'"
}

# _pf_resolve_parent_device_major_minor DEVICE
#   Resolve the parent disk of DEVICE and return its major:minor number.
#   Uses lsblk PKNAME to walk to the parent disk, then stat to get the
#   device identity.  Returns "major:minor" string.
#   This is the canonical identity check — two partitions are co-located
#   if and only if their parent disks have the same major:minor.
_pf_resolve_parent_device_major_minor() {
  local device="${1:?_pf_resolve_parent_device_major_minor: missing device path}"

  [[ -b "$device" ]] \
    || die "_pf_resolve_parent_device_major_minor: not a block device: $device"

  local parent_disk
  parent_disk="$(_pf_resolve_parent_disk "$device")"

  local parent_path="/dev/${parent_disk}"

  [[ -b "$parent_path" ]] \
    || die "_pf_resolve_parent_device_major_minor: parent disk is not a block device: $parent_path"

  _pf_get_major_minor "$parent_path"
}

# _pf_check_same_parent_disk DEVICE_A DEVICE_B
#   Compare two block devices by their parent disk major:minor numbers.
#   Returns 0 if both devices are on the same parent disk, 1 otherwise.
#   Prints nothing on success; dies on fatal errors.
#
#   IMPORTANT: This function only checks that two partitions share the
#   same parent disk.  It does NOT verify that they are distinct
#   partitions, have different roles, or are not the same device.
#   Callers must additionally check:
#     - Device paths are not identical (A != B)
#     - Major:minor numbers are not identical (distinct device nodes)
#     - Partition labels are distinct (different GPT roles)
#     - PARTUUIDs are distinct (different partition identities)
#   For a comprehensive co-location + distinctness check, use
#   _pf_verify_partitions_distinct().
_pf_check_same_parent_disk() {
  local device_a="${1:?_pf_check_same_parent_disk: missing device A}"
  local device_b="${2:?_pf_check_same_parent_disk: missing device B}"

  local mm_a mm_b
  mm_a="$(_pf_resolve_parent_device_major_minor "$device_a")" \
    || die "_pf_check_same_parent_disk: could not resolve parent major:minor for $device_a"
  mm_b="$(_pf_resolve_parent_device_major_minor "$device_b")" \
    || die "_pf_check_same_parent_disk: could not resolve parent major:minor for $device_b"

  if [[ "$mm_a" == "$mm_b" ]]; then
    return 0
  fi

  return 1
}

# _pf_verify_partitions_distinct DEVICE_A DEVICE_B LABEL_A LABEL_B
#   Verify that two partitions on the same parent disk are genuinely
#   distinct devices with different roles and identities.
#
#   Checks:
#     1. Device paths are not identical
#     2. Major:minor numbers are not identical (distinct device nodes)
#     3. Partition labels are distinct (different GPT roles)
#     4. PARTUUIDs are distinct (different partition identities)
#
#   This is the comprehensive co-location + distinctness check that
#   supplements _pf_check_same_parent_disk().  Callers should use this
#   after confirming both devices are on the same parent disk.
#
#   Args: DEVICE_A — first partition device path
#         DEVICE_B — second partition device path
#         LABEL_A  — expected GPT label for DEVICE_A (used in error messages)
#         LABEL_B  — expected GPT label for DEVICE_B (used in error messages)
#   Dies on failure (partitions are not distinct); returns 0 on success.
_pf_verify_partitions_distinct() {
  local device_a="${1:?_pf_verify_partitions_distinct: missing DEVICE_A}"
  local device_b="${2:?_pf_verify_partitions_distinct: missing DEVICE_B}"
  local label_a="${3:-}"
  local label_b="${4:-}"

  # --- Check 1: Device paths are not identical ---
  if [[ "$device_a" == "$device_b" ]]; then
    die "_pf_verify_partitions_distinct: $label_a ($device_a) and $label_b ($device_b) are the same device path — expected distinct partitions"
  fi

  # --- Check 2: Major:minor numbers are not identical ---
  local mm_a mm_b
  mm_a="$(_pf_get_major_minor "$device_a" 2>/dev/null)" \
    || die "_pf_verify_partitions_distinct: cannot determine major:minor for $device_a"
  mm_b="$(_pf_get_major_minor "$device_b" 2>/dev/null)" \
    || die "_pf_verify_partitions_distinct: cannot determine major:minor for $device_b"

  if [[ "$mm_a" == "$mm_b" ]]; then
    die "_pf_verify_partitions_distinct: $label_a ($device_a) and $label_b ($device_b) have identical major:minor ($mm_a) — expected distinct partitions"
  fi

  # --- Check 3: Partition labels are distinct (if both available) ---
  local resolved_label_a resolved_label_b
  resolved_label_a="$(blkid -s LABEL -o value "$device_a" 2>/dev/null)" || resolved_label_a=""
  resolved_label_b="$(blkid -s LABEL -o value "$device_b" 2>/dev/null)" || resolved_label_b=""

  if [[ -n "$resolved_label_a" && -n "$resolved_label_b" ]]; then
    if [[ "$resolved_label_a" == "$resolved_label_b" ]]; then
      die "_pf_verify_partitions_distinct: $label_a ($device_a) and $label_b ($device_b) have the same GPT label '$resolved_label_a' — expected distinct roles"
    fi
  fi

  # --- Check 4: PARTUUIDs are distinct (if both available) ---
  local partuuid_a partuuid_b
  partuuid_a="$(blkid -s PARTUUID -o value "$device_a" 2>/dev/null)" || partuuid_a=""
  partuuid_b="$(blkid -s PARTUUID -o value "$device_b" 2>/dev/null)" || partuuid_b=""

  if [[ -n "$partuuid_a" && -n "$partuuid_b" ]]; then
    if [[ "$partuuid_a" == "$partuuid_b" ]]; then
      die "_pf_verify_partitions_distinct: $label_a ($device_a) and $label_b ($device_b) have the same PARTUUID '$partuuid_a' — expected distinct partitions"
    fi
  fi

  debug "_pf_verify_partitions_distinct: $label_a ($device_a) and $label_b ($device_b) are distinct (mm=$mm_a/$mm_b, label=$resolved_label_a/$resolved_label_b, partuuid=$partuuid_a/$partuuid_b)"
}

# _pf_is_device_mounted DEVICE MOUNTED_INFO
#   Check if a device (by major:minor) is mounted.
#   MOUNTED_INFO is the pre-fetched output of findmnt -rn -o SOURCE,TARGET.
#   Returns:
#     0 — device is mounted (prints mount point on stdout)
#     1 — device is not mounted
#     2 — cannot determine (device is not a block device or major:minor failed)
_pf_is_device_mounted() {
  local device="$1"
  local mounted_info="$2"

  [[ -b "$device" ]] || return 2 # cannot determine

  local device_mm
  device_mm="$(_pf_get_major_minor "$device" 2>/dev/null)" || return 2

  local line src tgt
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    src="$(printf '%s' "$line" | awk '{print $1}')"
    tgt="$(printf '%s' "$line" | awk '{print $2}')"

    [[ -b "$src" ]] || continue

    local src_mm
    src_mm="$(_pf_get_major_minor "$src" 2>/dev/null)" || continue

    if [[ "$device_mm" == "$src_mm" ]]; then
      echo "$tgt"
      return 0
    fi
  done <<<"$mounted_info"

  return 1 # not mounted
}

# ---------------------------------------------------------------------------
# Build-scenario helpers — inspect supplied devices rather than host-global
# /dev/disk/by-partsets.
# ---------------------------------------------------------------------------

# _pf_verify_device_child_of_loop DEVICE LOOP_DEV
#   Verify that DEVICE is a child partition of LOOP_DEV by comparing their
#   major:minor numbers.  DEVICE's parent must have the same major:minor as
#   LOOP_DEV.
#   Returns 0 on success, dies on failure.
_pf_verify_device_child_of_loop() {
  local device="${1:?_pf_verify_device_child_of_loop: missing DEVICE}"
  local loop_dev="${2:?_pf_verify_device_child_of_loop: missing LOOP_DEV}"

  [[ -b "$device" ]] \
    || die "_pf_verify_device_child_of_loop: not a block device: $device"
  [[ -b "$loop_dev" ]] \
    || die "_pf_verify_device_child_of_loop: not a block device: $loop_dev"

  local device_mm loop_mm
  device_mm="$(_pf_resolve_parent_device_major_minor "$device")" \
    || die "_pf_verify_device_child_of_loop: could not resolve parent for $device"
  loop_mm="$(_pf_get_major_minor "$loop_dev")" \
    || die "_pf_verify_device_child_of_loop: could not get major:minor for $loop_dev"

  if [[ "$device_mm" != "$loop_mm" ]]; then
    die "_pf_verify_device_child_of_loop: $device is not a child of $loop_dev (device parent=$device_mm, loop=$loop_mm)"
  fi

  debug "_pf_verify_device_child_of_loop: $device is a child of $loop_dev"
}

# _pf_get_partition_label DEVICE
#   Return the GPT partition label for DEVICE using blkid.
#   Dies on failure or if no label is found.
_pf_get_partition_label() {
  local device="${1:?_pf_get_partition_label: missing DEVICE}"

  [[ -b "$device" ]] \
    || die "_pf_get_partition_label: not a block device: $device"

  local label
  label="$(blkid -s LABEL -o value "$device" 2>/dev/null)" || label=""

  if [[ -z "$label" ]]; then
    die "_pf_get_partition_label: no GPT label found for $device"
  fi

  echo "$label"
}

# _pf_get_partition_uuid DEVICE
#   Return the PARTUUID for DEVICE using blkid.
#   Dies on failure or if no PARTUUID is found.
_pf_get_partition_uuid() {
  local device="${1:?_pf_get_partition_uuid: missing DEVICE}"

  [[ -b "$device" ]] \
    || die "_pf_get_partition_uuid: not a block device: $device"

  local partuuid
  partuuid="$(blkid -s PARTUUID -o value "$device" 2>/dev/null)" || partuuid=""

  if [[ -z "$partuuid" ]]; then
    die "_pf_get_partition_uuid: no PARTUUID found for $device"
  fi

  echo "$partuuid"
}

# _pf_map_rauc_booted_to_slot RAUC_BOOTED
#   Map the RAUC "booted" field to a canonical A/B slot label.
#   Accepts: A, B, rootfs.0, rootfs.1, dev.
#   "dev" is a special case indicating development boot — the caller must
#   resolve the actual slot via bootconf.
#   Prints the canonical slot label (A, B) or "dev" on success.
#   Dies on unrecognized values.
_pf_map_rauc_booted_to_slot() {
  local rauc_booted="${1:?_pf_map_rauc_booted_to_slot: missing RAUC booted field}"

  case "$rauc_booted" in
    A | rootfs.0)
      echo "A"
      ;;
    B | rootfs.1)
      echo "B"
      ;;
    dev)
      echo "dev"
      ;;
    *)
      die "_pf_map_rauc_booted_to_slot: unrecognized RAUC booted value: '$rauc_booted'"
      ;;
  esac
}

# _pf_validate_bootconf_slot SLOT
#   Validate that a bootconf slot value is exactly "A" or "B".
#   Dies if the slot is not exactly A or B.
#   This should be called before using any slot value from bootconf
#   to ensure it is a valid A/B slot label.
#   Args: $1 = slot value to validate
_pf_validate_bootconf_slot() {
  local slot="${1:?_pf_validate_bootconf_slot: missing slot value}"

  case "$slot" in
    A | B) ;;
    *)
      die "_pf_validate_bootconf_slot: bootconf returned unexpected value: '$slot' (expected A or B)"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Individual checks — independently callable
# ---------------------------------------------------------------------------

# preflight_scenario_require_root()
#   PF-26: Verify we are running as root (EUID == 0).
preflight_scenario_require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "PF-26: this operation requires root (EUID=${EUID:-$(id -u)})"
  fi

  debug "PF-26: running as root"
}

# _preflight_build_efi_target_unambiguous EFI_DEV LOOP_DEV
#   PF-27: Verify the supplied EFI_DEV is a valid child partition of LOOP_DEV
#   with the expected GPT label, and that no "efi-B" partition exists on the
#   same loop image.
#   Args: EFI_DEV — the EFI partition device to validate
#         LOOP_DEV — the parent loop device the image is attached to
_preflight_build_efi_target_unambiguous() {
  local efi_dev="${1:?_preflight_build_efi_target_unambiguous: missing EFI_DEV}"
  local loop_dev="${2:?_preflight_build_efi_target_unambiguous: missing LOOP_DEV}"

  # --- Verify EFI_DEV is a block device ---
  [[ -b "$efi_dev" ]] \
    || die "PF-27: EFI_DEV is not a block device: $efi_dev"

  # --- Verify EFI_DEV is a child of LOOP_DEV ---
  _pf_verify_device_child_of_loop "$efi_dev" "$loop_dev"

  # --- Verify the GPT label is "efi-A" ---
  local efi_label
  efi_label="$(_pf_get_partition_label "$efi_dev")"

  if [[ "$efi_label" != "efi-A" ]]; then
    die "PF-27: unexpected GPT label on EFI partition: '$efi_label' (expected 'efi-A')"
  fi

  # --- Verify no "efi-B" partition exists on the same loop image ---
  # Walk all partitions of LOOP_DEV and check labels.
  local _old_nullglob
  _old_nullglob=$(shopt -p nullglob 2>/dev/null)
  shopt -s nullglob
  local partition
  for partition in /dev/disk/by-partsets/*/efi; do
    [[ -e "$partition" ]] || continue
    local part_dev
    part_dev="$(readlink -f "$partition" 2>/dev/null)" || continue
    [[ -b "$part_dev" ]] || continue

    # Skip the efi-A we already validated.
    [[ "$part_dev" == "$efi_dev" ]] && continue

    local part_label
    part_label="$(blkid -s LABEL -o value "$part_dev" 2>/dev/null)" || continue
    if [[ "$part_label" == "efi-B" ]]; then
      # Verify this efi-B is on the same loop device.
      local part_mm efi_mm
      part_mm="$(_pf_resolve_parent_device_major_minor "$part_dev" 2>/dev/null)" || continue
      efi_mm="$(_pf_get_major_minor "$loop_dev" 2>/dev/null)" || continue
      if [[ "$part_mm" == "$efi_mm" ]]; then
        die "PF-27: efi-B device exists ($part_dev) on the same loop image — refusing to proceed (strict policy: no efi-B allowed during build)"
      fi
    fi
  done
  eval "$_old_nullglob" 2>/dev/null || shopt -u nullglob

  debug "PF-27: efi target unambiguous (efi-A=$efi_dev, no efi-B on $loop_dev)"
}

# _preflight_build_partitions_same_image ROOTFS_DEV EFI_DEV LOOP_DEV
#   PF-28: Verify rootfs-A and efi-A are distinct child partitions of the
#   supplied LOOP_DEV, have the expected GPT labels ("rootfs-A" and "efi-A"),
#   and have valid PARTUUIDs.
#   Args: ROOTFS_DEV — the rootfs partition device
#         EFI_DEV    — the EFI partition device
#         LOOP_DEV   — the parent loop device the image is attached to
_preflight_build_partitions_same_image() {
  local rootfs_dev="${1:?_preflight_build_partitions_same_image: missing ROOTFS_DEV}"
  local efi_dev="${2:?_preflight_build_partitions_same_image: missing EFI_DEV}"
  local loop_dev="${3:?_preflight_build_partitions_same_image: missing LOOP_DEV}"

  # --- Verify both are block devices ---
  [[ -b "$rootfs_dev" ]] \
    || die "PF-28: ROOTFS_DEV is not a block device: $rootfs_dev"
  [[ -b "$efi_dev" ]] \
    || die "PF-28: EFI_DEV is not a block device: $efi_dev"

  # --- Verify both are children of LOOP_DEV ---
  _pf_verify_device_child_of_loop "$rootfs_dev" "$loop_dev"
  _pf_verify_device_child_of_loop "$efi_dev" "$loop_dev"

  # --- Verify they are distinct devices ---
  if [[ "$rootfs_dev" == "$efi_dev" ]]; then
    die "PF-28: rootfs and EFI are the same device ($rootfs_dev) — expected distinct partitions"
  fi

  local rootfs_mm efi_mm
  rootfs_mm="$(_pf_get_major_minor "$rootfs_dev")"
  efi_mm="$(_pf_get_major_minor "$efi_dev")"
  if [[ "$rootfs_mm" == "$efi_mm" ]]; then
    die "PF-28: rootfs ($rootfs_dev) and EFI ($efi_dev) have identical major:minor ($rootfs_mm) — expected distinct partitions"
  fi

  # --- Verify GPT labels ---
  local rootfs_label efi_label
  rootfs_label="$(_pf_get_partition_label "$rootfs_dev")"
  efi_label="$(_pf_get_partition_label "$efi_dev")"

  if [[ "$rootfs_label" != "rootfs-A" ]]; then
    die "PF-28: unexpected GPT label on rootfs partition: '$rootfs_label' (expected 'rootfs-A')"
  fi

  if [[ "$efi_label" != "efi-A" ]]; then
    die "PF-28: unexpected GPT label on EFI partition: '$efi_label' (expected 'efi-A')"
  fi

  # --- Verify PARTUUIDs are valid (non-empty) ---
  local rootfs_partuuid efi_partuuid
  rootfs_partuuid="$(_pf_get_partition_uuid "$rootfs_dev")"
  efi_partuuid="$(_pf_get_partition_uuid "$efi_dev")"

  debug "PF-28: partitions on same image (rootfs=$rootfs_dev label=$rootfs_label partuuid=$rootfs_partuuid, efi=$efi_dev label=$efi_label partuuid=$efi_partuuid, parent=$loop_dev)"
}

# _preflight_flashless_slot_sources_agree()
#   PF-29: Verify that steamos-bootconf "this-image" agrees with RAUC
#   "booted".  Both must resolve to the same slot.
#   RAUC booted=dev is a distinct scenario — it is NOT accepted as
#   agreement.  Flashless must refuse dev and route through Recovery.
#   Requires bootconf to be exactly A or B (validated via
#   _pf_validate_bootconf_slot).
#   RAUC and bootconf are queried once and stored as an immutable snapshot.
#   Returns a snapshot descriptor (associative-style key=value pairs via
#   the PF_SNAPSHOT_* globals) on success.
#   Sets: PF_SNAPSHOT_BOOTCONF_SLOT, PF_SNAPSHOT_RAUC_BOOTED,
#         PF_SNAPSHOT_RAUC_SLOT, PF_SNAPSHOT_RAUC_IS_DEV.
# shellcheck disable=SC2034 # PF_SNAPSHOT_* are set for downstream consumers
_preflight_flashless_slot_sources_agree() {
  local bootconf_slot rauc_booted rauc_slot rauc_is_dev=0

  # --- Query bootconf once and validate it is exactly A or B ---
  bootconf_slot="$(steamos-bootconf this-image 2>/dev/null)" \
    || die "PF-29: steamos-bootconf this-image failed"

  _pf_validate_bootconf_slot "$bootconf_slot"

  # --- Query RAUC once under the same logical transaction ---
  # Capture JSON response first, then parse — do not rely on pipeline status.
  local rauc_json
  rauc_json="$(rauc status --output-format=json 2>/dev/null)" \
    || die "PF-29: rauc status failed"

  [[ -n "$rauc_json" ]] \
    || die "PF-29: RAUC returned empty response"

  rauc_booted="$(printf '%s' "$rauc_json" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("booted",""))' 2>/dev/null)" \
    || rauc_booted=""

  [[ -n "$rauc_booted" ]] \
    || die "PF-29: RAUC booted field is empty"

  rauc_slot="$(_pf_map_rauc_booted_to_slot "$rauc_booted")"

  # --- RAUC booted=dev is a DISTINCT scenario — refuse in flashless ---
  # Flashless cannot safely determine which slot is actually active when
  # RAUC reports a development boot.  Route through Recovery instead.
  if [[ "$rauc_slot" == "dev" ]]; then
    rauc_is_dev=1
    die "PF-29: RAUC booted=dev (development boot) — flashless cannot proceed safely; use Recovery workflow"
  fi

  if [[ "$rauc_slot" != "$bootconf_slot" ]]; then
    die "PF-29: slot sources disagree (bootconf=$bootconf_slot, RAUC=$rauc_slot)"
  fi
  debug "PF-29: slot sources agree: $bootconf_slot"

  # --- Store immutable snapshot for downstream checks ---
  PF_SNAPSHOT_BOOTCONF_SLOT="$bootconf_slot"
  PF_SNAPSHOT_RAUC_BOOTED="$rauc_booted"
  PF_SNAPSHOT_RAUC_SLOT="$rauc_slot"
  PF_SNAPSHOT_RAUC_IS_DEV="$rauc_is_dev"
}

# _preflight_flashless_target_is_standby()
#   PF-30: Verify the target slot is NOT the currently booted slot.
#   Overwriting the active slot would be catastrophic.
#   Accepts explicit target slot and target devices as parameters to
#   avoid relying on host-side /dev/disk/by-partsets resolution.
#
#   IMMUTABILITY NOTE:
#     PF_CURRENT_SLOT and PF_TARGET_SLOT are mutable globals retained
#     for backward compatibility.  This function clears them before
#     validation to prevent stale values from a prior call from
#     contaminating the current check.  The new snapshot pattern
#     (PF_SNAPSHOT_*) partially addresses this by storing an immutable
#     snapshot; prefer using the snapshot globals for new code.
#
#   Args: $1 = declared target slot (A or B)
#         $2 = declared target rootfs device
#         $3 = declared target EFI device
#         $4 = declared target var device
#   Returns the validated scenario descriptor (writes PF_CURRENT_SLOT,
#   PF_TARGET_SLOT globals for backward compatibility).
_preflight_flashless_target_is_standby() {
  local declared_target="${1:?_preflight_flashless_target_is_standby: missing declared target slot}"
  local declared_rootfs="${2:-}"
  local declared_efi="${3:-}"
  local declared_var="${4:-}"

  # --- Clear mutable globals before validation to prevent stale state ---
  # PF_CURRENT_SLOT and PF_TARGET_SLOT may hold values from a prior call.
  # Clear them so that any code path that reads them before this function
  # completes sees an empty value rather than stale data.
  PF_CURRENT_SLOT=""
  PF_TARGET_SLOT=""

  # --- Resolve current slot from bootconf (authoritative source) ---
  local bootconf_slot
  bootconf_slot="$(steamos-bootconf this-image 2>/dev/null)" \
    || die "PF-30: steamos-bootconf this-image failed"

  _pf_validate_bootconf_slot "$bootconf_slot"

  PF_CURRENT_SLOT="$bootconf_slot"

  # --- Validate declared target is exactly A or B ---
  case "$declared_target" in
    A | B) ;;
    *) die "PF-30: declared target slot is not A or B: '$declared_target'" ;;
  esac

  # --- Assert declared target != current (booted) slot ---
  # This is the critical safety check: overwriting the active slot would
  # be catastrophic.  Since both PF_CURRENT_SLOT and declared_target are
  # validated as exactly A or B, and there are only two slots, checking
  # inequality is sufficient — no additional "expected opposite" assertion
  # is needed.
  if [[ "$declared_target" == "$PF_CURRENT_SLOT" ]]; then
    die "PF-30: declared target slot ($declared_target) equals current (booted) slot ($PF_CURRENT_SLOT) — refusing to overwrite active slot"
  fi

  PF_TARGET_SLOT="$declared_target"

  # --- Validate target devices match partset devices for declared target ---
  # When target devices are provided, cross-check them against /dev/disk/by-partsets.
  if [[ -d "/dev/disk/by-partsets/$PF_TARGET_SLOT" ]]; then
    local -A partset_devs declared_devs
    local dev_name resolved

    for dev_name in rootfs efi var; do
      resolved="$(readlink -f "/dev/disk/by-partsets/$PF_TARGET_SLOT/$dev_name" 2>/dev/null)" || resolved=""
      if [[ -n "$resolved" && -b "$resolved" ]]; then
        partset_devs["$dev_name"]="$resolved"
      fi
    done

    [[ -n "${declared_rootfs:-}" ]] && declared_devs["rootfs"]="$declared_rootfs"
    [[ -n "${declared_efi:-}" ]] && declared_devs["efi"]="$declared_efi"
    [[ -n "${declared_var:-}" ]] && declared_devs["var"]="$declared_var"

    for dev_name in rootfs efi var; do
      local declared_val="${declared_devs[$dev_name]:-}"
      local partset_val="${partset_devs[$dev_name]:-}"

      if [[ -n "$declared_val" && -n "$partset_val" ]]; then
        if [[ "$declared_val" != "$partset_val" ]]; then
          die "PF-30: declared $dev_name ($declared_val) does not match partset $dev_name ($partset_val) for target slot $PF_TARGET_SLOT"
        fi
      fi
    done
  fi

  # --- Assert target devices are NOT the same as active-slot devices ---
  # This prevents accidentally writing to the booted slot's partitions.
  if [[ -d "/dev/disk/by-partsets/$PF_CURRENT_SLOT" ]]; then
    local dev_name active_dev target_dev

    for dev_name in rootfs efi var; do
      active_dev="$(readlink -f "/dev/disk/by-partsets/$PF_CURRENT_SLOT/$dev_name" 2>/dev/null)" || continue
      [[ -b "$active_dev" ]] || continue

      case "$dev_name" in
        rootfs) target_dev="${declared_rootfs:-}" ;;
        efi) target_dev="${declared_efi:-}" ;;
        var) target_dev="${declared_var:-}" ;;
      esac

      if [[ -n "$target_dev" && -b "$target_dev" ]]; then
        local active_mm target_mm
        active_mm="$(_pf_get_major_minor "$active_dev" 2>/dev/null)" || continue
        target_mm="$(_pf_get_major_minor "$target_dev" 2>/dev/null)" || continue
        if [[ "$active_mm" == "$target_mm" ]]; then
          die "PF-30: target $dev_name device ($target_dev) has same major:minor as active $dev_name ($active_dev) — devices are identical"
        fi
      fi
    done
  fi

  debug "PF-30: target=$PF_TARGET_SLOT is standby (current=$PF_CURRENT_SLOT)"
}

# _preflight_flashless_target_partitions_not_mounted()
#   PF-31: Verify that ALL target partitions (EFI, rootfs, var) are not
#   already mounted.  A mounted target partition would indicate a stale
#   mount from a previous operation, which could corrupt the filesystem.
#
#   Uses major/minor comparison for mount verification (not just device
#   path matching) to handle symlinks and device-mapper aliases correctly.
#
#   Fails closed: if mount state cannot be determined for a device, the
#   check fails rather than silently passing.
#
#   LIMITATION — mount namespace scope:
#     This check inspects the *current* mount namespace only.  A flock
#     (used elsewhere to exclude cooperating installers) cannot prove
#     that another mount namespace has not mounted the target device.
#     A process in a different mount namespace may hold a mount that is
#     invisible to findmnt(8) in this namespace.  This is an inherent
#     limitation of Linux mount namespaces: there is no cross-namespace
#     mount enumeration API.  The flock provides best-effort coordination
#     among cooperating installers; this check covers the remaining
#     (non-flock) case within the current namespace.
#
#   Args: $1 = target slot (A or B), or uses PF_TARGET_SLOT
#         $2 = declared target rootfs device (optional; resolved from partsets if omitted)
#         $3 = declared target EFI device (optional; resolved from partsets if omitted)
#         $4 = declared target var device (optional; resolved from partsets if omitted)
_preflight_flashless_target_partitions_not_mounted() {
  local target_slot="${1:-}"
  local declared_rootfs="${2:-}"
  local declared_efi="${3:-}"
  local declared_var="${4:-}"

  if [[ -z "$target_slot" ]]; then
    target_slot="${PF_TARGET_SLOT:?_preflight_flashless_target_partitions_not_mounted: PF_TARGET_SLOT not set}"
  fi

  # --- Resolve target devices ---
  local efi_dev rootfs_dev var_dev

  if [[ -n "$declared_efi" && -b "$declared_efi" ]]; then
    efi_dev="$declared_efi"
  else
    efi_dev="$(readlink -f "/dev/disk/by-partsets/$target_slot/efi" 2>/dev/null)" \
      || die "PF-31: cannot resolve target EFI device for slot $target_slot"
  fi

  if [[ -n "$declared_rootfs" && -b "$declared_rootfs" ]]; then
    rootfs_dev="$declared_rootfs"
  else
    rootfs_dev="$(readlink -f "/dev/disk/by-partsets/$target_slot/rootfs" 2>/dev/null)" \
      || die "PF-31: cannot resolve target rootfs device for slot $target_slot"
  fi

  if [[ -n "$declared_var" && -b "$declared_var" ]]; then
    var_dev="$declared_var"
  else
    var_dev="$(readlink -f "/dev/disk/by-partsets/$target_slot/var" 2>/dev/null)" 2>/dev/null || var_dev=""
  fi

  # --- Validate all resolved devices are block devices ---
  [[ -b "$efi_dev" ]] \
    || die "PF-31: target EFI is not a block device: $efi_dev"
  [[ -b "$rootfs_dev" ]] \
    || die "PF-31: target rootfs is not a block device: $rootfs_dev"

  if [[ -n "$var_dev" ]]; then
    [[ -b "$var_dev" ]] \
      || die "PF-31: target var is not a block device: $var_dev"
  fi

  # --- Check mount state for each device using major/minor comparison ---
  # Collect all currently mounted device major:minor pairs once.
  local mounted_info
  mounted_info="$(findmnt -rn -o SOURCE,TARGET 2>/dev/null)" || mounted_info=""

  # Check EFI
  local mount_point _rc
  mount_point="$(_pf_is_device_mounted "$efi_dev" "$mounted_info")"
  _rc=$?
  if [[ $_rc -eq 0 ]]; then
    die "PF-31: target EFI is already mounted: $efi_dev at $mount_point"
  elif [[ $_rc -eq 2 ]]; then
    die "PF-31: failed to determine mount state for target EFI ($efi_dev) — failing closed"
  fi

  # Check rootfs
  mount_point="$(_pf_is_device_mounted "$rootfs_dev" "$mounted_info")"
  _rc=$?
  if [[ $_rc -eq 0 ]]; then
    die "PF-31: target rootfs is already mounted: $rootfs_dev at $mount_point"
  elif [[ $_rc -eq 2 ]]; then
    die "PF-31: failed to determine mount state for target rootfs ($rootfs_dev) — failing closed"
  fi

  # Check var (if available)
  if [[ -n "$var_dev" ]]; then
    mount_point="$(_pf_is_device_mounted "$var_dev" "$mounted_info")"
    _rc=$?
    if [[ $_rc -eq 0 ]]; then
      die "PF-31: target var is already mounted: $var_dev at $mount_point"
    elif [[ $_rc -eq 2 ]]; then
      die "PF-31: failed to determine mount state for target var ($var_dev) — failing closed"
    fi
  fi

  debug "PF-31: all target partitions not mounted (efi=$efi_dev rootfs=$rootfs_dev var=${var_dev:-<none>})"
}

# _preflight_flashless_target_verity_not_active()
#   PF-31b: Verify that no device-mapper (verity/overlay) mappings are
#   active on the target partitions.  An active dm device indicates an
#   incomplete previous operation or an active encryption/verity layer
#   that would interfere with a raw dd write.
#
#   Uses dmsetup to enumerate active device-mapper targets and compares
#   their backing device major:minor numbers against the target partition
#   devices.
#
#   Args: $1 = target slot (A or B), or uses PF_TARGET_SLOT
#         $2 = declared target rootfs device (optional)
#         $3 = declared target EFI device (optional)
#         $4 = declared target var device (optional)
_preflight_flashless_target_verity_not_active() {
  local target_slot="${1:-}"
  local declared_rootfs="${2:-}"
  local declared_efi="${3:-}"
  local declared_var="${4:-}"

  if [[ -z "$target_slot" ]]; then
    target_slot="${PF_TARGET_SLOT:?_preflight_flashless_target_verity_not_active: PF_TARGET_SLOT not set}"
  fi

  # --- Require dmsetup ---
  if ! command -v dmsetup &>/dev/null; then
    debug "PF-31b: dmsetup not available — skipping verity check"
    return 0
  fi

  # --- Resolve target devices ---
  local rootfs_dev efi_dev var_dev

  if [[ -n "$declared_rootfs" && -b "$declared_rootfs" ]]; then
    rootfs_dev="$declared_rootfs"
  else
    rootfs_dev="$(readlink -f "/dev/disk/by-partsets/$target_slot/rootfs" 2>/dev/null)" 2>/dev/null || rootfs_dev=""
  fi

  if [[ -n "$declared_efi" && -b "$declared_efi" ]]; then
    efi_dev="$declared_efi"
  else
    efi_dev="$(readlink -f "/dev/disk/by-partsets/$target_slot/efi" 2>/dev/null)" 2>/dev/null || efi_dev=""
  fi

  if [[ -n "$declared_var" && -b "$declared_var" ]]; then
    var_dev="$declared_var"
  else
    var_dev="$(readlink -f "/dev/disk/by-partsets/$target_slot/var" 2>/dev/null)" 2>/dev/null || var_dev=""
  fi

  # --- Enumerate active device-mapper targets ---
  local dm_info
  dm_info="$(dmsetup ls --target crypt,verity,snapshot,striped,mirror,linear 2>/dev/null)" || dm_info=""

  if [[ -z "$dm_info" ]]; then
    debug "PF-31b: no active dm targets (or dmsetup returned empty)"
    return 0
  fi

  # --- Check each target device against active dm mappings ---
  local _pf_dm_check_failed=0

  _pf_check_dm_active() {
    local device="$1"
    local label="$2"

    [[ -n "$device" && -b "$device" ]] || return 0

    local device_mm
    device_mm="$(_pf_get_major_minor "$device" 2>/dev/null)" || return 0

    # For each dm device listed, check its table for backing devices with matching major:minor.
    local dm_name
    while IFS= read -r line; do
      dm_name="$(printf '%s' "$line" | awk '{print $1}')"
      [[ -z "$dm_name" ]] && continue

      # Get the dm device's table to inspect backing devices.
      local dm_table
      dm_table="$(dmsetup table "/dev/mapper/$dm_name" 2>/dev/null)" || continue

      # Parse the table line — the backing device major:minor is after the target type.
      # Format: <start_sector> <num_sectors> <target_type> <target_args...>
      # For linear:  <start> <count> linear <major> <minor> <offset>
      # For verity:  <start> <count> verity <version> <data_device> ...
      local backing_mm
      backing_mm="$(printf '%s' "$dm_table" | awk '{
        # Extract all numbers from the line after the 3rd field (target_type).
        for (i=4; i<=NF; i++) {
          if ($i ~ /^[0-9]+:[0-9]+$/) {
            print $i; exit
          }
        }
      }')" || backing_mm=""

      if [[ -n "$backing_mm" && "$backing_mm" == "$device_mm" ]]; then
        die "PF-31b: target $label ($device) has active dm mapping: $dm_name (backing=$backing_mm)"
      fi

      # Also check: resolve the dm device's own major:minor and compare with
      # the target — a device-mapper node may alias the same major:minor.
      local dm_dev="/dev/mapper/$dm_name"
      if [[ -b "$dm_dev" ]]; then
        local dm_mm
        dm_mm="$(_pf_get_major_minor "$dm_dev" 2>/dev/null)" || continue
        if [[ "$dm_mm" == "$device_mm" ]]; then
          die "PF-31b: target $label ($device) shares major:minor with active dm device: $dm_dev ($dm_mm)"
        fi
      fi
    done <<<"$dm_info"
  }

  _pf_check_dm_active "$rootfs_dev" "rootfs"
  _pf_check_dm_active "$efi_dev" "efi"
  _pf_check_dm_active "$var_dev" "var"

  unset -f _pf_check_dm_active

  debug "PF-31b: no active verity/dm mappings on target partitions"
}

# _preflight_flashless_no_pending_transition()
#   PF-32: Verify there is no pending slot transition and that the RAUC
#   state is compatible with a safe flashless install.
#
#   Accepts the current slot as a parameter (from the orchestrator snapshot)
#   instead of re-querying bootconf.
#
#   Requires ALL of the following:
#     1. steamos-bootconf selected-image == current slot (no reboot pending)
#     2. RAUC installer operation is idle (not mid-install)
#     3. RAUC booted slot agrees with current slot (consistency check)
#     4. RAUC activated/primary state is compatible (no pending transition)
#     5. Target slot is not already selected as next boot
#     6. No reboot/update transition is pending in target bootconf state
#
#   Args: $1 = current slot (A or B) — from orchestrator snapshot
#         $2 = target slot (A or B) — from orchestrator snapshot
#         $3 = RAUC JSON response (raw) — from orchestrator snapshot
_preflight_flashless_no_pending_transition() {
  local current_slot="${1:-}"
  local target_slot="${2:-}"
  local rauc_json="${3:-}"

  # --- Resolve current slot from parameter or bootconf ---
  if [[ -z "$current_slot" ]]; then
    current_slot="$(steamos-bootconf this-image 2>/dev/null)" \
      || die "PF-32: steamos-bootconf this-image failed"

    _pf_validate_bootconf_slot "$current_slot"
  fi

  if [[ -z "$target_slot" ]]; then
    target_slot="${PF_TARGET_SLOT:-}"
  fi

  # --- 1. Check bootconf selected-image matches current slot ---
  local selected
  selected="$(steamos-bootconf selected-image 2>/dev/null)" \
    || die "PF-32: steamos-bootconf selected-image failed"

  # Validate selected slot is exactly A or B.
  _pf_validate_bootconf_slot "$selected"

  if [[ "$selected" != "$current_slot" ]]; then
    die "PF-32: pending slot transition detected (current=$current_slot, selected=$selected) — refusing flashless install"
  fi

  # --- 2. Check RAUC installer operation is idle ---
  if [[ -n "$rauc_json" ]]; then
    local rauc_operation
    rauc_operation="$(printf '%s' "$rauc_json" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("operation",""))' 2>/dev/null)" \
      || rauc_operation=""

    if [[ -n "$rauc_operation" && "$rauc_operation" != "" ]]; then
      die "PF-32: RAUC installer operation is not idle: '$rauc_operation' — refusing flashless install"
    fi
  fi

  # --- 3. Check RAUC booted slot agrees with bootconf current slot ---
  if [[ -n "$rauc_json" ]]; then
    local rauc_booted
    rauc_booted="$(printf '%s' "$rauc_json" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("booted",""))' 2>/dev/null)" \
      || rauc_booted=""

    if [[ -n "$rauc_booted" ]]; then
      local rauc_slot
      rauc_slot="$(_pf_map_rauc_booted_to_slot "$rauc_booted")"

      if [[ "$rauc_slot" != "dev" ]]; then
        if [[ "$rauc_slot" != "$current_slot" ]]; then
          die "PF-32: RAUC booted slot ($rauc_slot) disagrees with bootconf current slot ($current_slot) — refusing flashless install"
        fi
        debug "PF-32: RAUC booted slot ($rauc_slot) agrees with bootconf current slot ($current_slot)"
      fi
    fi
  fi

  # --- 4. Check RAUC compatible state (no pending transition) ---
  if [[ -n "$rauc_json" ]]; then
    local rauc_booted rauc_primary
    rauc_booted="$(printf '%s' "$rauc_json" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("booted",""))' 2>/dev/null)" \
      || rauc_booted=""
    rauc_primary="$(printf '%s' "$rauc_json" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("primary",""))' 2>/dev/null)" \
      || rauc_primary=""

    # If booted and primary differ, a transition is pending in RAUC.
    if [[ -n "$rauc_booted" && -n "$rauc_primary" && "$rauc_booted" != "$rauc_primary" ]]; then
      die "PF-32: RAUC pending transition (booted=$rauc_booted, primary=$rauc_primary) — refusing flashless install"
    fi

    # Also validate that RAUC primary state is compatible with no pending
    # transition: primary must agree with booted when primary is a slot label.
    if [[ -n "$rauc_primary" ]]; then
      local rauc_primary_slot
      rauc_primary_slot="$(_pf_map_rauc_booted_to_slot "$rauc_primary" 2>/dev/null)" || rauc_primary_slot=""
      if [[ -n "$rauc_primary_slot" && "$rauc_primary_slot" != "dev" ]]; then
        if [[ -n "$rauc_booted" ]]; then
          local rauc_booted_slot
          rauc_booted_slot="$(_pf_map_rauc_booted_to_slot "$rauc_booted" 2>/dev/null)" || rauc_booted_slot=""
          if [[ -n "$rauc_booted_slot" && "$rauc_booted_slot" != "dev" ]]; then
            if [[ "$rauc_primary_slot" != "$rauc_booted_slot" ]]; then
              die "PF-32: RAUC primary ($rauc_primary) differs from booted ($rauc_booted) — pending transition, refusing flashless install"
            fi
          fi
        fi
      fi
    fi
  fi

  # --- 5. Check target slot is not already selected as next boot ---
  if [[ -n "$target_slot" && "$selected" == "$target_slot" ]]; then
    die "PF-32: target slot ($target_slot) is already selected as next boot (selected=$selected) — refusing flashless install"
  fi

  # --- 6. Check target bootconf has no pending reboot/update transition ---
  if [[ -n "$target_slot" ]]; then
    local target_conf="/esp/SteamOS/conf/${target_slot}.conf"
    if [[ -f "$target_conf" ]]; then
      # Check for image-invalid=0 on the target — this indicates the target
      # was already activated (a previous partial operation).
      local target_image_invalid
      target_image_invalid="$(grep '^image-invalid=' "$target_conf" 2>/dev/null | cut -d= -f2)" || target_image_invalid=""
      if [[ "$target_image_invalid" == "0" ]]; then
        die "PF-32: target $target_slot bootconf shows image-invalid=0 — target already activated, refusing flashless install"
      fi

      # Check for reboot-pending or update-pending flags.
      local target_reboot_pending
      target_reboot_pending="$(grep '^reboot-pending=' "$target_conf" 2>/dev/null | cut -d= -f2)" || target_reboot_pending=""
      if [[ "$target_reboot_pending" == "1" ]]; then
        die "PF-32: target $target_slot bootconf has reboot-pending=1 — refusing flashless install"
      fi

      local target_update_pending
      target_update_pending="$(grep '^update-pending=' "$target_conf" 2>/dev/null | cut -d= -f2)" || target_update_pending=""
      if [[ "$target_update_pending" == "1" ]]; then
        die "PF-32: target $target_slot bootconf has update-pending=1 — refusing flashless install"
      fi
    fi
  fi

  debug "PF-32: no pending transition (selected=$selected == current=$current_slot, RAUC idle, target=$target_slot safe)"
}

# _preflight_flashless_slot_values_valid()
#   PF-33: Verify slot values are exactly A or B and that current != target.
#   This function is independently callable — it validates both that the
#   slot labels are well-formed (A or B) and that they are distinct
#   (current must not equal target).  Overwriting the active slot would
#   be catastrophic; this is a defense-in-depth check against callers
#   that may have corrupted state.
_preflight_flashless_slot_values_valid() {
  local current="${1:?_preflight_flashless_slot_values_valid: missing current slot}"
  local target="${2:?_preflight_flashless_slot_values_valid: missing target slot}"

  case "$current" in
    A | B) ;;
    *) die "PF-33: invalid current slot value: '$current'" ;;
  esac

  case "$target" in
    A | B) ;;
    *) die "PF-33: invalid target slot value: '$target'" ;;
  esac

  if [[ "$current" == "$target" ]]; then
    die "PF-33: current slot ($current) equals target slot ($target) — slots must be distinct"
  fi

  debug "PF-33: slot values valid (current=$current, target=$target)"
}

# _pf_verify_recovery_topology_descriptor DESCRIPTOR...
#   Validate that a recovery topology descriptor contains all required fields.
#   The descriptor is a sequence of KEY=VALUE pairs passed as arguments.
#   Required fields:
#     TARGET_SLOT           — target slot label (A or B)
#     ROOTFS_DEVICE         — block device path for the rootfs partition
#     ROOTFS_PARTUUID       — PARTUUID of the rootfs partition
#     EFI_DEVICE            — block device path for the EFI partition
#     EFI_PARTUUID          — PARTUUID of the EFI partition
#     VAR_DEVICE            — block device path for the var partition
#     VAR_PARTUUID          — PARTUUID of the var partition
#     VERITY_DEVICE         — block device path for the verity partition (may be empty)
#     VERITY_POLICY         — verity policy string (may be empty)
#     SHARED_ESP_DEVICE     — block device path for the shared ESP partition
#     SHARED_ESP_PARTUUID   — PARTUUID of the shared ESP partition
#   Returns 0 on success, dies on missing or invalid fields.
_pf_verify_recovery_topology_descriptor() {
  local -A descriptor=()
  local pair key value

  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    descriptor["$key"]="$value"
  done

  local -a required_keys=(
    TARGET_SLOT ROOTFS_DEVICE ROOTFS_PARTUUID
    EFI_DEVICE EFI_PARTUUID
    VAR_DEVICE VAR_PARTUUID
    VERITY_DEVICE VERITY_POLICY
    SHARED_ESP_DEVICE SHARED_ESP_PARTUUID
  )

  for key in "${required_keys[@]}"; do
    if [[ -z "${descriptor[$key]+_}" ]]; then
      die "_pf_verify_recovery_topology_descriptor: missing required field: $key"
    fi
  done

  # Validate TARGET_SLOT is exactly A or B.
  case "${descriptor[TARGET_SLOT]}" in
    A | B) ;;
    *) die "_pf_verify_recovery_topology_descriptor: invalid TARGET_SLOT: '${descriptor[TARGET_SLOT]}' (expected A or B)" ;;
  esac

  # Validate mandatory block devices exist.
  local -a device_keys=(ROOTFS_DEVICE EFI_DEVICE VAR_DEVICE SHARED_ESP_DEVICE)
  local dk
  for dk in "${device_keys[@]}"; do
    local dev="${descriptor[$dk]}"
    if [[ -n "$dev" ]]; then
      [[ -b "$dev" ]] \
        || die "_pf_verify_recovery_topology_descriptor: $dk is not a block device: $dev"
    fi
  done

  # Validate mandatory PARTUUIDs are non-empty.
  local -a partuuid_keys=(ROOTFS_PARTUUID EFI_PARTUUID VAR_PARTUUID SHARED_ESP_PARTUUID)
  local pk
  for pk in "${partuuid_keys[@]}"; do
    [[ -n "${descriptor[$pk]}" ]] \
      || die "_pf_verify_recovery_topology_descriptor: $pk is empty"
  done

  debug "_pf_verify_recovery_topology_descriptor: descriptor valid (target=${descriptor[TARGET_SLOT]})"
}

# _preflight_recovery_target_explicit()
#   PF-34: Verify the recovery target slot was resolved independently
#   (not inherited from a stale global).  Accepts a complete topology
#   descriptor instead of just a slot label.
#
#   The topology descriptor is a sequence of KEY=VALUE pairs describing:
#     TARGET_SLOT           — target slot label (A or B)
#     ROOTFS_DEVICE         — block device path for the rootfs partition
#     ROOTFS_PARTUUID       — PARTUUID of the rootfs partition
#     EFI_DEVICE            — block device path for the EFI partition
#     EFI_PARTUUID          — PARTUUID of the EFI partition
#     VAR_DEVICE            — block device path for the var partition
#     VAR_PARTUUID          — PARTUUID of the var partition
#     VERITY_DEVICE         — block device path for the verity partition
#     VERITY_POLICY         — verity policy string
#     SHARED_ESP_DEVICE     — block device path for the shared ESP partition
#     SHARED_ESP_PARTUUID   — PARTUUID of the shared ESP partition
#
#   The descriptor is validated and stored immutably in PF_RECOVERY_DESCRIPTOR.
#   Args: $1 = topology descriptor (KEY=VALUE pairs, one per argument)
#   Sets: PF_TARGET_SLOT, PF_RECOVERY_DESCRIPTOR (globals).
_preflight_recovery_target_explicit() {
  local explicit_target="${1:?_preflight_recovery_target_explicit: missing topology descriptor}"

  # Validate the descriptor contains all required fields.
  _pf_verify_recovery_topology_descriptor "$@"

  local target_slot="${explicit_target#TARGET_SLOT=}"

  case "$target_slot" in
    A | B) ;;
    *) die "PF-34: invalid recovery target slot: '$target_slot'" ;;
  esac

  PF_TARGET_SLOT="$target_slot"

  # Store the full descriptor as an immutable associative array.
  # Downstream checks reference PF_RECOVERY_DESCRIPTOR instead of
  # re-resolving devices from host-global /dev/disk/by-partsets.
  declare -gA PF_RECOVERY_DESCRIPTOR=()
  local pair key value
  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    PF_RECOVERY_DESCRIPTOR["$key"]="$value"
  done

  debug "PF-34: recovery target explicitly set: $PF_TARGET_SLOT (descriptor stored)"
}

# _preflight_recovery_target_devices_agree()
#   PF-35: Verify the recovery topology descriptor devices are co-located
#   on the same parent disk, cross-check mounted rootfs and EFI against
#   the descriptor, and verify all devices share the same parent.
#
#   Uses the topology descriptor (PF_RECOVERY_DESCRIPTOR) instead of
#   host-global /dev/disk/by-partsets, which may not represent the
#   actual mounted recovery target.
#
#   Cross-checks:
#     1. Mounted rootfs (/) device major:minor matches descriptor's
#        ROOTFS_DEVICE.
#     2. Mounted EFI (/efi) device major:minor matches descriptor's
#        EFI_DEVICE.
#     3. All descriptor devices (rootfs, EFI, var) share the same parent
#        disk (co-location check via major:minor comparison).
#     4. All descriptor devices are genuinely distinct — different device
#        paths, different major:minor, different GPT labels, and
#        different PARTUUIDs (PF-28 style distinctness check).
#
#   Args: $1 = topology descriptor (KEY=VALUE pairs) — optional if
#              PF_RECOVERY_DESCRIPTOR is already set.
#   Reads: PF_RECOVERY_DESCRIPTOR (global).
#   Sets: PF_RECOVERY_DESCRIPTOR (if not already set).
_preflight_recovery_target_devices_agree() {
  # --- Accept descriptor from argument or pre-stored global ---
  if [[ $# -gt 0 ]]; then
    # Store the descriptor if not already set.
    if [[ ${#PF_RECOVERY_DESCRIPTOR[@]} -eq 0 ]]; then
      declare -gA PF_RECOVERY_DESCRIPTOR=()
      local pair key value
      for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        PF_RECOVERY_DESCRIPTOR["$key"]="$value"
      done
    fi
  fi

  if [[ ${#PF_RECOVERY_DESCRIPTOR[@]} -eq 0 ]]; then
    die "PF-35: no topology descriptor available (pass descriptor or call _preflight_recovery_target_explicit first)"
  fi

  local target_slot="${PF_RECOVERY_DESCRIPTOR[TARGET_SLOT]:-}"
  local rootfs_dev="${PF_RECOVERY_DESCRIPTOR[ROOTFS_DEVICE]:-}"
  local efi_dev="${PF_RECOVERY_DESCRIPTOR[EFI_DEVICE]:-}"
  local var_dev="${PF_RECOVERY_DESCRIPTOR[VAR_DEVICE]:-}"

  [[ -n "$rootfs_dev" ]] \
    || die "PF-35: ROOTFS_DEVICE is empty in topology descriptor"
  [[ -n "$efi_dev" ]] \
    || die "PF-35: EFI_DEVICE is empty in topology descriptor"
  [[ -n "$var_dev" ]] \
    || die "PF-35: VAR_DEVICE is empty in topology descriptor"

  [[ -b "$rootfs_dev" ]] \
    || die "PF-35: target rootfs is not a block device: $rootfs_dev"
  [[ -b "$efi_dev" ]] \
    || die "PF-35: target EFI is not a block device: $efi_dev"
  [[ -b "$var_dev" ]] \
    || die "PF-35: target var is not a block device: $var_dev"

  # --- Cross-check: mounted rootfs (/) against descriptor's ROOTFS_DEVICE ---
  local mounted_root
  mounted_root="$(findmnt -rn -o SOURCE / 2>/dev/null)" \
    || die "PF-35: findmnt / failed — cannot verify root mount identity"
  [[ -n "$mounted_root" ]] \
    || die "PF-35: findmnt / returned empty — root filesystem not mounted?"

  local mounted_root_dev
  mounted_root_dev="$(readlink -f "$mounted_root" 2>/dev/null)" || mounted_root_dev="$mounted_root"
  [[ -b "$mounted_root_dev" ]] \
    || die "PF-35: mounted / source ($mounted_root) is not a block device"

  local mounted_root_mm rootfs_mm
  mounted_root_mm="$(_pf_get_major_minor "$mounted_root_dev" 2>/dev/null)" \
    || die "PF-35: cannot determine major:minor for mounted / device ($mounted_root_dev)"
  rootfs_mm="$(_pf_get_major_minor "$rootfs_dev" 2>/dev/null)" \
    || die "PF-35: cannot determine major:minor for descriptor rootfs ($rootfs_dev)"

  if [[ "$mounted_root_mm" != "$rootfs_mm" ]]; then
    die "PF-35: mounted / device ($mounted_root_dev mm=$mounted_root_mm) does not match descriptor ROOTFS_DEVICE ($rootfs_dev mm=$rootfs_mm) for target slot $target_slot"
  fi
  debug "PF-35: mounted / device matches descriptor rootfs: $mounted_root_dev (mm=$mounted_root_mm)"

  # --- Cross-check: mounted EFI (/efi) against descriptor's EFI_DEVICE ---
  local mounted_efi
  mounted_efi="$(findmnt -rn -o SOURCE /efi 2>/dev/null)" \
    || die "PF-35: findmnt /efi failed — cannot verify EFI mount identity"
  [[ -n "$mounted_efi" ]] \
    || die "PF-35: findmnt /efi returned empty — /efi not mounted?"

  local mounted_efi_dev
  mounted_efi_dev="$(readlink -f "$mounted_efi" 2>/dev/null)" || mounted_efi_dev="$mounted_efi"
  [[ -b "$mounted_efi_dev" ]] \
    || die "PF-35: mounted /efi source ($mounted_efi) is not a block device"

  local mounted_efi_mm efi_mm
  mounted_efi_mm="$(_pf_get_major_minor "$mounted_efi_dev" 2>/dev/null)" \
    || die "PF-35: cannot determine major:minor for mounted /efi device ($mounted_efi_dev)"
  efi_mm="$(_pf_get_major_minor "$efi_dev" 2>/dev/null)" \
    || die "PF-35: cannot determine major:minor for descriptor EFI_DEVICE ($efi_dev)"

  if [[ "$mounted_efi_mm" != "$efi_mm" ]]; then
    die "PF-35: mounted /efi device ($mounted_efi_dev mm=$mounted_efi_mm) does not match descriptor EFI_DEVICE ($efi_dev mm=$efi_mm) for target slot $target_slot"
  fi
  debug "PF-35: mounted /efi device matches descriptor EFI: $mounted_efi_dev (mm=$mounted_efi_mm)"

  # --- Co-location check: all devices on the same parent disk ---
  if ! _pf_check_same_parent_disk "$rootfs_dev" "$efi_dev"; then
    local rootfs_parent efi_parent
    rootfs_parent="$(_pf_resolve_parent_disk "$rootfs_dev")"
    efi_parent="$(_pf_resolve_parent_disk "$efi_dev")"
    die "PF-35: target devices on different disks (rootfs=$rootfs_dev parent=$rootfs_parent, efi=$efi_dev parent=$efi_parent)"
  fi

  if ! _pf_check_same_parent_disk "$rootfs_dev" "$var_dev"; then
    local rootfs_parent var_parent
    rootfs_parent="$(_pf_resolve_parent_disk "$rootfs_dev")"
    var_parent="$(_pf_resolve_parent_disk "$var_dev")"
    die "PF-35: target devices on different disks (rootfs=$rootfs_dev parent=$rootfs_parent, var=$var_dev parent=$var_parent)"
  fi

  # --- Distinctness check: partitions must be genuinely distinct ---
  # Co-location (same parent disk) does not imply distinctness — two device
  # paths could resolve to the same partition.  Verify rootfs/efi and
  # rootfs/var are truly separate devices with different identities.
  _pf_verify_partitions_distinct "$rootfs_dev" "$efi_dev" "rootfs" "efi"
  _pf_verify_partitions_distinct "$rootfs_dev" "$var_dev" "rootfs" "var"

  local rootfs_parent
  rootfs_parent="$(_pf_resolve_parent_disk "$rootfs_dev")"
  debug "PF-35: target devices on same disk: $rootfs_parent (rootfs=$rootfs_dev, efi=$efi_dev, var=$var_dev)"
}

# _preflight_recovery_target_slot_permitted()
#   PF-35b: Verify the target slot is the permitted current/repatch slot.
#
#   Recovery scenario contract:
#     - Recovery operates on the *other* slot — it must NOT be the
#       currently booted slot.
#     - The target must be either the current slot's opposite (standard
#       A/B recovery) OR the current slot itself (repatch scenario where
#       the running system is updated in place).
#     - This function enforces that the target slot is a valid A or B
#       and that it is either the opposite of the current slot (standby
#       recovery) or the same slot (repatch).
#
#   The caller must explicitly declare the recovery mode:
#     - "standby"  — target is the opposite of the current slot (default)
#     - "repatch"  — target is the current slot (re-patching in place)
#
#   This prevents recovery from targeting an arbitrary slot that is
#   neither the standby nor the current slot, which would indicate a
#   corrupted or inconsistent system state.
#
#   Args: $1 = target slot (A or B) — from PF_TARGET_SLOT or descriptor
#         $2 = recovery mode ("standby" or "repatch", default: "standby")
#         $3 = current slot (A or B) — from orchestrator snapshot; if
#              empty, queries bootconf (fallback for standalone use).
#   Reads: PF_TARGET_SLOT (global).
_preflight_recovery_target_slot_permitted() {
  local target_slot="${1:-${PF_TARGET_SLOT:?_preflight_recovery_target_slot_permitted: PF_TARGET_SLOT not set}}"
  local recovery_mode="${2:-standby}"
  local current_slot="${3:-}"

  # --- Validate target slot is exactly A or B ---
  _pf_validate_bootconf_slot "$target_slot"

  # --- Validate recovery mode ---
  case "$recovery_mode" in
    standby | repatch) ;;
    *) die "PF-35b: invalid recovery mode: '$recovery_mode' (expected 'standby' or 'repatch')" ;;
  esac

  # --- Resolve current slot from parameter (preferred) or bootconf (fallback) ---
  # The orchestrator should query bootconf once and pass the snapshot value
  # via $3 to avoid duplicate queries.  If $3 is empty, fall back to
  # querying bootconf directly (standalone callable contract).
  local bootconf_slot="$current_slot"
  if [[ -z "$bootconf_slot" ]]; then
    bootconf_slot="$(steamos-bootconf this-image 2>/dev/null)" \
      || die "PF-35b: steamos-bootconf this-image failed"

    _pf_validate_bootconf_slot "$bootconf_slot"
  fi

  # --- Enforce the recovery scenario contract ---
  case "$recovery_mode" in
    standby)
      # Target must be the opposite of the current slot.
      if [[ "$target_slot" == "$bootconf_slot" ]]; then
        die "PF-35b: standby recovery target ($target_slot) equals current slot ($bootconf_slot) — use repatch mode or select the opposite slot"
      fi
      # Verify it is the expected opposite.
      local expected_target
      case "$bootconf_slot" in
        A) expected_target="B" ;;
        B) expected_target="A" ;;
      esac
      if [[ "$target_slot" != "$expected_target" ]]; then
        die "PF-35b: standby recovery target ($target_slot) does not match expected opposite slot ($expected_target) for current=$bootconf_slot"
      fi
      debug "PF-35b: standby recovery target=$target_slot is permitted (current=$bootconf_slot)"
      ;;
    repatch)
      # Target must be the current slot (re-patching in place).
      if [[ "$target_slot" != "$bootconf_slot" ]]; then
        die "PF-35b: repatch recovery target ($target_slot) does not equal current slot ($bootconf_slot) — use standby mode for cross-slot recovery"
      fi
      debug "PF-35b: repatch recovery target=$target_slot is permitted (current=$bootconf_slot)"
      ;;
  esac
}

# _pf_is_device_mounted_at MOUNT_POINT DEVICE MOUNTED_INFO
#   Check if DEVICE is the device mounted at MOUNT_POINT.
#   MOUNTED_INFO is the pre-fetched output of findmnt -rn -o SOURCE,TARGET.
#   Uses major/minor comparison for device identity.
#   Returns:
#     0 — device IS mounted at the specified mount point
#     1 — device is NOT mounted at the specified mount point (or not mounted at all)
#     2 — cannot determine (device is not a block device or major:minor failed)
_pf_is_device_mounted_at() {
  local mount_point="${1:?_pf_is_device_mounted_at: missing mount point}"
  local device="${2:?_pf_is_device_mounted_at: missing device path}"
  local mounted_info="${3:-}"

  [[ -b "$device" ]] || return 2 # cannot determine

  local device_mm
  device_mm="$(_pf_get_major_minor "$device" 2>/dev/null)" || return 2

  local line src tgt
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    tgt="$(printf '%s' "$line" | awk '{print $2}')"
    src="$(printf '%s' "$line" | awk '{print $1}')"

    # Only compare entries for the specified mount point.
    [[ "$tgt" == "$mount_point" ]] || continue

    [[ -b "$src" ]] || continue

    local src_mm
    src_mm="$(_pf_get_major_minor "$src" 2>/dev/null)" || continue

    if [[ "$device_mm" == "$src_mm" ]]; then
      return 0 # device is mounted at mount_point
    fi
  done <<<"$mounted_info"

  return 1 # device is not mounted at mount_point
}

# _preflight_live_identity_sources_agree()
#   PF-36: Verify RAUC, bootconf, root, EFI, and ESP identity sources agree.
#   All must resolve to the same slot.
#   When RAUC returns "dev", trust bootconf (accept "dev" as agreement).
#   Fails closed on ALL loss-of-identity conditions:
#     - Missing /dev/disk/by-partsets is FATAL
#     - Missing rootfs link is FATAL
#     - Missing EFI link is FATAL
#     - findmnt / failure is FATAL
#     - findmnt /efi failure is FATAL
#     - /esp mount/device validation is mandatory
#   Uses major/minor comparison for all device identity checks.
#
#   Args: $1 = bootconf slot (A or B) — from orchestrator snapshot
#         $2 = RAUC booted value — from orchestrator snapshot
_preflight_live_identity_sources_agree() {
  local bootconf_slot="${1:-}"
  local rauc_booted="${2:-}"

  # --- Resolve bootconf slot if not provided ---
  if [[ -z "$bootconf_slot" ]]; then
    bootconf_slot="$(steamos-bootconf this-image 2>/dev/null)" \
      || die "PF-36: steamos-bootconf this-image failed"
  fi

  # --- Validate bootconf slot is exactly A or B ---
  _pf_validate_bootconf_slot "$bootconf_slot"

  # --- Resolve RAUC booted if not provided ---
  if [[ -z "$rauc_booted" ]]; then
    # Capture JSON first, then parse — do not rely on pipeline status.
    local rauc_json
    rauc_json="$(rauc status --output-format=json 2>/dev/null)" \
      || die "PF-36: rauc status failed"

    [[ -n "$rauc_json" ]] \
      || die "PF-36: RAUC returned empty response"

    rauc_booted="$(printf '%s' "$rauc_json" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("booted",""))' 2>/dev/null)" \
      || rauc_booted=""
  fi

  [[ -n "$rauc_booted" ]] \
    || die "PF-36: RAUC booted field is empty"

  local rauc_slot
  rauc_slot="$(_pf_map_rauc_booted_to_slot "$rauc_booted")"

  # "dev" from RAUC means development boot — trust bootconf entirely.
  # In the Live scenario, the system is running and bootconf is authoritative;
  # RAUC booted=dev does not prevent safe operation on the running system.
  if [[ "$rauc_slot" == "dev" ]]; then
    debug "PF-36: RAUC booted=dev — trusting bootconf slot: $bootconf_slot"
  else
    if [[ "$rauc_slot" != "$bootconf_slot" ]]; then
      die "PF-36: slot sources disagree (bootconf=$bootconf_slot, RAUC=$rauc_slot)"
    fi
    debug "PF-36: bootconf and RAUC agree: $bootconf_slot"
  fi

  # --- /dev/disk/by-partsets is MANDATORY — missing is FATAL ---
  [[ -d "/dev/disk/by-partsets" ]] \
    || die "PF-36: /dev/disk/by-partsets/ not found — cannot verify live identity (refusing to continue)"

  # --- Rootfs link is MANDATORY — missing is FATAL ---
  local rootfs_dev
  rootfs_dev="$(readlink -f "/dev/disk/by-partsets/$bootconf_slot/rootfs" 2>/dev/null)" \
    || die "PF-36: cannot resolve rootfs symlink for slot $bootconf_slot (/dev/disk/by-partsets/$bootconf_slot/rootfs missing or broken)"
  [[ -n "$rootfs_dev" ]] \
    || die "PF-36: rootfs for slot $bootconf_slot resolved to empty path"
  [[ -b "$rootfs_dev" ]] \
    || die "PF-36: rootfs for slot $bootconf_slot is not a block device: $rootfs_dev"
  debug "PF-36: rootfs resolves for slot $bootconf_slot: $rootfs_dev"

  # --- EFI link is MANDATORY — missing is FATAL ---
  local efi_dev
  efi_dev="$(readlink -f "/dev/disk/by-partsets/$bootconf_slot/efi" 2>/dev/null)" \
    || die "PF-36: cannot resolve EFI symlink for slot $bootconf_slot (/dev/disk/by-partsets/$bootconf_slot/efi missing or broken)"
  [[ -n "$efi_dev" ]] \
    || die "PF-36: EFI for slot $bootconf_slot resolved to empty path"
  [[ -b "$efi_dev" ]] \
    || die "PF-36: EFI for slot $bootconf_slot is not a block device: $efi_dev"
  debug "PF-36: EFI resolves for slot $bootconf_slot: $efi_dev"

  # --- Cross-reference: mounted / device MUST match partset rootfs ---
  # findmnt / failure is FATAL — we cannot verify identity otherwise.
  local mounted_root
  mounted_root="$(findmnt -rn -o SOURCE / 2>/dev/null)" \
    || die "PF-36: findmnt / failed — cannot verify root mount identity"
  [[ -n "$mounted_root" ]] \
    || die "PF-36: findmnt / returned empty — root filesystem not mounted?"

  local mounted_root_dev
  mounted_root_dev="$(readlink -f "$mounted_root" 2>/dev/null)" || mounted_root_dev="$mounted_root"
  [[ -b "$mounted_root_dev" ]] \
    || die "PF-36: mounted / source ($mounted_root) is not a block device"

  local mounted_root_mm rootfs_mm
  mounted_root_mm="$(_pf_get_major_minor "$mounted_root_dev" 2>/dev/null)" \
    || die "PF-36: cannot determine major:minor for mounted / device ($mounted_root_dev)"
  rootfs_mm="$(_pf_get_major_minor "$rootfs_dev" 2>/dev/null)" \
    || die "PF-36: cannot determine major:minor for partset rootfs ($rootfs_dev)"

  if [[ "$mounted_root_mm" != "$rootfs_mm" ]]; then
    die "PF-36: mounted / device ($mounted_root mm=$mounted_root_mm) does not match partset rootfs ($rootfs_dev mm=$rootfs_mm) for slot $bootconf_slot"
  fi
  debug "PF-36: mounted / device matches partset rootfs: $mounted_root (mm=$mounted_root_mm)"

  # --- Cross-reference: mounted /efi device MUST match partset EFI ---
  # findmnt /efi failure is FATAL.
  local mounted_efi
  mounted_efi="$(findmnt -rn -o SOURCE /efi 2>/dev/null)" \
    || die "PF-36: findmnt /efi failed — cannot verify EFI mount identity"
  [[ -n "$mounted_efi" ]] \
    || die "PF-36: findmnt /efi returned empty — /efi not mounted?"

  local mounted_efi_dev
  mounted_efi_dev="$(readlink -f "$mounted_efi" 2>/dev/null)" || mounted_efi_dev="$mounted_efi"
  [[ -b "$mounted_efi_dev" ]] \
    || die "PF-36: mounted /efi source ($mounted_efi) is not a block device"

  local mounted_efi_mm efi_mm
  mounted_efi_mm="$(_pf_get_major_minor "$mounted_efi_dev" 2>/dev/null)" \
    || die "PF-36: cannot determine major:minor for mounted /efi device ($mounted_efi_dev)"
  efi_mm="$(_pf_get_major_minor "$efi_dev" 2>/dev/null)" \
    || die "PF-36: cannot determine major:minor for partset EFI ($efi_dev)"

  if [[ "$mounted_efi_mm" != "$efi_mm" ]]; then
    die "PF-36: mounted /efi device ($mounted_efi mm=$mounted_efi_mm) does not match partset EFI ($efi_dev mm=$efi_mm) for slot $bootconf_slot"
  fi
  debug "PF-36: mounted /efi device matches partset EFI: $mounted_efi (mm=$mounted_efi_mm)"

  # --- Validate /esp mount and device ---
  # /esp must exist and be accessible, and the device mounted there must
  # match the partset EFI device (major:minor comparison).
  [[ -d "/esp" ]] \
    || die "PF-36: /esp directory does not exist — EFI system partition not mounted"

  # Find what device is mounted at /esp.
  local esp_source
  esp_source="$(findmnt -rn -o SOURCE /esp 2>/dev/null)" \
    || die "PF-36: findmnt /esp failed — /esp may not be mounted"
  [[ -n "$esp_source" ]] \
    || die "PF-36: findmnt /esp returned empty — /esp is not mounted"

  local esp_dev
  esp_dev="$(readlink -f "$esp_source" 2>/dev/null)" || esp_dev="$esp_source"
  [[ -b "$esp_dev" ]] \
    || die "PF-36: /esp mount source ($esp_source) is not a block device"

  local esp_mm
  esp_mm="$(_pf_get_major_minor "$esp_dev" 2>/dev/null)" \
    || die "PF-36: cannot determine major:minor for /esp device ($esp_dev)"

  # The /esp device must match the partset EFI device — they are the same
  # partition (EFI system partition) mounted at two paths.
  if [[ "$esp_mm" != "$efi_mm" ]]; then
    die "PF-36: /esp device ($esp_dev mm=$esp_mm) does not match partset EFI ($efi_dev mm=$efi_mm) — /esp and /efi should be the same partition"
  fi
  debug "PF-36: /esp device matches partset EFI: $esp_dev (mm=$esp_mm)"

  debug "PF-36: live identity sources agree (slot=$bootconf_slot, rootfs=$rootfs_dev, efi=$efi_dev, esp=$esp_dev)"
}

# ---------------------------------------------------------------------------
# Orchestrators
# ---------------------------------------------------------------------------

# preflight_scenario_validate_build LOOP_DEV ROOTFS_DEV EFI_DEV
#   Run all build-scenario preflight checks.
#   Args: LOOP_DEV  — source image loop device
#         ROOTFS_DEV — rootfs partition device
#         EFI_DEV    — EFI partition device
preflight_scenario_validate_build() {
  local loop_dev="${1:?preflight_scenario_validate_build: missing loop device}"
  local rootfs_dev="${2:?preflight_scenario_validate_build: missing rootfs device}"
  local efi_dev="${3:?preflight_scenario_validate_build: missing EFI device}"

  # --- Verify ROOTFS_DEV and EFI_DEV are actually supplied (not empty) ---
  [[ -n "$rootfs_dev" ]] \
    || die "preflight_scenario_validate_build: ROOTFS_DEV is empty"
  [[ -n "$efi_dev" ]] \
    || die "preflight_scenario_validate_build: EFI_DEV is empty"

  debug "preflight_scenario_validate_build: loop=$loop_dev rootfs=$rootfs_dev efi=$efi_dev"

  # PF-26: Root required.
  preflight_scenario_require_root

  # PF-27: EFI target unambiguous (no efi-B), validated against supplied devices.
  _preflight_build_efi_target_unambiguous "$efi_dev" "$loop_dev"

  # PF-28: rootfs-A and efi-A on same loop image, distinct devices with expected labels.
  _preflight_build_partitions_same_image "$rootfs_dev" "$efi_dev" "$loop_dev"

  # PF-27b: rootfs and EFI are distinct from each other.
  if [[ "$rootfs_dev" == "$efi_dev" ]]; then
    die "PF-27b: ROOTFS_DEV and EFI_DEV must be distinct devices (got $rootfs_dev for both)"
  fi

  debug "preflight_scenario_validate_build: all checks passed"
}

# preflight_scenario_validate_flashless()
#   Run all flashless-scenario preflight checks.
#
#   Orchestrator strategy:
#     1. Query RAUC once and store the full JSON response.
#     2. Query bootconf (this-image, selected-image) once.
#     3. Build a validated snapshot of the system state.
#     4. Pass the snapshot to all downstream checks (PF-29 through PF-32)
#        to avoid duplicate queries and ensure consistency.
#     5. Retain the immutable scenario descriptor (PF_CURRENT_SLOT,
#        PF_TARGET_SLOT, PF_SNAPSHOT_*) for downstream consumers.
#
#   RAUC booted=dev is treated as a distinct scenario — it is NOT
#   accepted as agreement.  Flashless must refuse dev and route through
#   Recovery.
#
#   Sets: PF_CURRENT_SLOT, PF_TARGET_SLOT, PF_SNAPSHOT_BOOTCONF_SLOT,
#         PF_SNAPSHOT_RAUC_BOOTED, PF_SNAPSHOT_RAUC_SLOT,
#         PF_SNAPSHOT_RAUC_IS_DEV, PF_SNAPSHOT_RAUC_JSON,
#         PF_SNAPSHOT_SELECTED_SLOT.
# shellcheck disable=SC2034 # PF_SNAPSHOT_* are set for downstream consumers
preflight_scenario_validate_flashless() {
  debug "preflight_scenario_validate_flashless: starting"

  # --- Phase 0: Root required ---
  preflight_scenario_require_root

  # --- Phase 1: Query RAUC once (single authoritative read) ---
  # Capture JSON response first, then parse — do not rely on pipeline status.
  local rauc_json
  rauc_json="$(rauc status --output-format=json 2>/dev/null)" \
    || die "preflight_scenario_validate_flashless: rauc status failed"

  [[ -n "$rauc_json" ]] \
    || die "preflight_scenario_validate_flashless: RAUC returned empty response"

  # Store for downstream consumption.
  PF_SNAPSHOT_RAUC_JSON="$rauc_json"

  # --- Phase 2: Query bootconf once (single authoritative read) ---
  local bootconf_slot selected_slot

  bootconf_slot="$(steamos-bootconf this-image 2>/dev/null)" \
    || die "preflight_scenario_validate_flashless: steamos-bootconf this-image failed"

  selected_slot="$(steamos-bootconf selected-image 2>/dev/null)" \
    || die "preflight_scenario_validate_flashless: steamos-bootconf selected-image failed"

  # Validate bootconf slots are exactly A or B.
  _pf_validate_bootconf_slot "$bootconf_slot"
  _pf_validate_bootconf_slot "$selected_slot"

  # Store for downstream consumption.
  PF_SNAPSHOT_BOOTCONF_SLOT="$bootconf_slot"
  PF_SNAPSHOT_SELECTED_SLOT="$selected_slot"

  # --- Phase 3: Parse RAUC snapshot ---
  # Parse the captured JSON — do not re-query RAUC.
  local rauc_booted rauc_operation rauc_primary
  rauc_booted="$(printf '%s' "$rauc_json" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("booted",""))' 2>/dev/null)" \
    || rauc_booted=""
  rauc_operation="$(printf '%s' "$rauc_json" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("operation",""))' 2>/dev/null)" \
    || rauc_operation=""
  rauc_primary="$(printf '%s' "$rauc_json" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("primary",""))' 2>/dev/null)" \
    || rauc_primary=""

  [[ -n "$rauc_booted" ]] \
    || die "PF-29: RAUC booted field is empty"

  local rauc_slot rauc_is_dev=0
  rauc_slot="$(_pf_map_rauc_booted_to_slot "$rauc_booted")"

  if [[ "$rauc_slot" == "dev" ]]; then
    rauc_is_dev=1
  fi

  # Store parsed RAUC snapshot.
  PF_SNAPSHOT_RAUC_BOOTED="$rauc_booted"
  PF_SNAPSHOT_RAUC_SLOT="$rauc_slot"
  PF_SNAPSHOT_RAUC_IS_DEV="$rauc_is_dev"
  PF_SNAPSHOT_RAUC_OPERATION="$rauc_operation"
  PF_SNAPSHOT_RAUC_PRIMARY="$rauc_primary"

  # --- Phase 4: Validate snapshot consistency ---
  # PF-29: Slot sources agree (bootconf vs RAUC).
  # RAUC booted=dev is a DISTINCT scenario — refuse in flashless.
  if [[ "$rauc_slot" == "dev" ]]; then
    die "PF-29: RAUC booted=dev (development boot) — flashless cannot proceed safely; use Recovery workflow"
  fi

  if [[ "$rauc_slot" != "$bootconf_slot" ]]; then
    die "PF-29: slot sources disagree (bootconf=$bootconf_slot, RAUC=$rauc_slot)"
  fi
  debug "PF-29: slot sources agree: $bootconf_slot"

  # PF-30: Target is standby (not active). Sets PF_CURRENT_SLOT, PF_TARGET_SLOT.
  # Use the snapshot bootconf_slot — do NOT re-query.
  PF_CURRENT_SLOT="$bootconf_slot"

  local expected_target
  case "$PF_CURRENT_SLOT" in
    A) expected_target="B" ;;
    B) expected_target="A" ;;
    *) die "PF-30: unexpected current slot: $PF_CURRENT_SLOT" ;;
  esac
  PF_TARGET_SLOT="$expected_target"

  # Validate current and target are distinct.
  if [[ "$PF_CURRENT_SLOT" == "$PF_TARGET_SLOT" ]]; then
    die "PF-30: current slot ($PF_CURRENT_SLOT) equals target slot ($PF_TARGET_SLOT) — refusing to overwrite active slot"
  fi

  # Validate target devices are NOT the same as active-slot devices.
  if [[ -d "/dev/disk/by-partsets/$PF_CURRENT_SLOT" ]]; then
    local dev_name active_dev target_dev

    for dev_name in rootfs efi var; do
      active_dev="$(readlink -f "/dev/disk/by-partsets/$PF_CURRENT_SLOT/$dev_name" 2>/dev/null)" || continue
      [[ -b "$active_dev" ]] || continue

      target_dev="$(readlink -f "/dev/disk/by-partsets/$PF_TARGET_SLOT/$dev_name" 2>/dev/null)" || continue
      [[ -b "$target_dev" ]] || continue

      local active_mm target_mm
      active_mm="$(_pf_get_major_minor "$active_dev" 2>/dev/null)" || continue
      target_mm="$(_pf_get_major_minor "$target_dev" 2>/dev/null)" || continue
      if [[ "$active_mm" == "$target_mm" ]]; then
        die "PF-30: target $dev_name device ($target_dev) has same major:minor as active $dev_name ($active_dev) — devices are identical"
      fi
    done
  fi

  debug "PF-30: target=$PF_TARGET_SLOT is standby (current=$PF_CURRENT_SLOT)"

  # PF-33: Slot values are exactly A or B.
  _preflight_flashless_slot_values_valid "$PF_CURRENT_SLOT" "$PF_TARGET_SLOT"

  # PF-31: Target partitions (EFI, rootfs, var) not mounted.
  # Use snapshot — resolve from partsets using PF_TARGET_SLOT.
  local target_rootfs_dev="" target_efi_dev="" target_var_dev=""
  if [[ -d "/dev/disk/by-partsets/$PF_TARGET_SLOT" ]]; then
    target_rootfs_dev="$(readlink -f "/dev/disk/by-partsets/$PF_TARGET_SLOT/rootfs" 2>/dev/null)" || target_rootfs_dev=""
    target_efi_dev="$(readlink -f "/dev/disk/by-partsets/$PF_TARGET_SLOT/efi" 2>/dev/null)" || target_efi_dev=""
    target_var_dev="$(readlink -f "/dev/disk/by-partsets/$PF_TARGET_SLOT/var" 2>/dev/null)" || target_var_dev=""
  fi

  _preflight_flashless_target_partitions_not_mounted "$PF_TARGET_SLOT" \
    "$target_rootfs_dev" "$target_efi_dev" "$target_var_dev"

  # PF-31b: Target verity/device-mapper not active.
  _preflight_flashless_target_verity_not_active "$PF_TARGET_SLOT" \
    "$target_rootfs_dev" "$target_efi_dev" "$target_var_dev"

  # PF-32: No pending transition (pass snapshot to avoid re-querying).
  _preflight_flashless_no_pending_transition "$PF_CURRENT_SLOT" "$PF_TARGET_SLOT" "$rauc_json"

  debug "preflight_scenario_validate_flashless: all checks passed (current=$PF_CURRENT_SLOT, target=$PF_TARGET_SLOT)"
}

# preflight_scenario_validate_recovery TOPOLOGY_DESCRIPTOR...
#   Run all recovery-scenario preflight checks.
#
#   Accepts a complete topology descriptor as KEY=VALUE pairs describing:
#     TARGET_SLOT           — target slot label (A or B)
#     ROOTFS_DEVICE         — block device path for the rootfs partition
#     ROOTFS_PARTUUID       — PARTUUID of the rootfs partition
#     EFI_DEVICE            — block device path for the EFI partition
#     EFI_PARTUUID          — PARTUUID of the EFI partition
#     VAR_DEVICE            — block device path for the var partition
#     VAR_PARTUUID          — PARTUUID of the var partition
#     VERITY_DEVICE         — block device path for the verity partition
#     VERITY_POLICY         — verity policy string
#     SHARED_ESP_DEVICE     — block device path for the shared ESP partition
#     SHARED_ESP_PARTUUID   — PARTUUID of the shared ESP partition
#
#   Recovery scenario contract:
#     - Recovery does NOT rely on host-global /dev/disk/by-partsets for
#       device resolution.  Instead, all device identity comes from the
#       caller-supplied topology descriptor.
#     - Mounted rootfs (/) and EFI (/efi) are cross-checked against the
#       descriptor to ensure the descriptor matches the actual system state.
#     - Target slot must be either the standby slot (opposite of current)
#       or the current slot (repatch mode), enforced by PF-35b.
#
#   Orchestrator strategy:
#     - Query bootconf once and pass the current slot to PF-35b to avoid
#       duplicate queries (slot state queried once pattern).
#
#   Args: $1 = topology descriptor (KEY=VALUE pairs, one per argument)
#   Sets: PF_TARGET_SLOT, PF_RECOVERY_DESCRIPTOR (globals).
preflight_scenario_validate_recovery() {
  local first_arg="${1:?preflight_scenario_validate_recovery: missing topology descriptor}"
  local target_slot="${first_arg#TARGET_SLOT=}"

  debug "preflight_scenario_validate_recovery: target=$target_slot (descriptor received)"

  # PF-26: Root required.
  preflight_scenario_require_root

  # PF-34: Validate and store the topology descriptor.
  _preflight_recovery_target_explicit "$@"

  # PF-35: Cross-check mounted rootfs and EFI against descriptor;
  #         verify all devices on same parent disk.
  _preflight_recovery_target_devices_agree "$@"

  # --- Query bootconf once for the current slot (single authoritative read) ---
  # Pass the snapshot to PF-35b so it does not re-query bootconf.
  local bootconf_slot
  bootconf_slot="$(steamos-bootconf this-image 2>/dev/null)" \
    || die "preflight_scenario_validate_recovery: steamos-bootconf this-image failed"
  _pf_validate_bootconf_slot "$bootconf_slot"

  # PF-35b: Verify target slot is the permitted current/repatch slot.
  # Pass bootconf_slot snapshot to avoid duplicate query.
  local recovery_mode="${PF_RECOVERY_MODE:-standby}"
  _preflight_recovery_target_slot_permitted "$PF_TARGET_SLOT" "$recovery_mode" "$bootconf_slot"

  debug "preflight_scenario_validate_recovery: all checks passed (target=$PF_TARGET_SLOT, mode=$recovery_mode)"
}

# preflight_scenario_validate_live()
#   Run all live-scenario preflight checks.
#
#   Orchestrator strategy:
#     1. Query RAUC once and store the full JSON response (capture-first).
#     2. Query bootconf once (single authoritative read).
#     3. Build a validated snapshot of the system state.
#     4. Pass the snapshot to PF-36 to avoid duplicate queries.
#     5. Set PF_CURRENT_SLOT and PF_SNAPSHOT_* for downstream consumers.
#
#   RAUC booted=dev is accepted in the Live scenario — the system is
#   running and bootconf is authoritative.  Unlike Flashless, Live does
#   not refuse dev; it trusts bootconf as the identity source.
#
#   Sets: PF_CURRENT_SLOT, PF_SNAPSHOT_BOOTCONF_SLOT,
#         PF_SNAPSHOT_RAUC_BOOTED, PF_SNAPSHOT_RAUC_JSON.
# shellcheck disable=SC2034 # PF_SNAPSHOT_* are set for downstream consumers
preflight_scenario_validate_live() {
  debug "preflight_scenario_validate_live: starting"

  # PF-26: Root required.
  preflight_scenario_require_root

  # --- Phase 1: Query RAUC once (single authoritative read) ---
  # Capture JSON response first, then parse — do not rely on pipeline status.
  local rauc_json
  rauc_json="$(rauc status --output-format=json 2>/dev/null)" \
    || die "preflight_scenario_validate_live: rauc status failed"

  [[ -n "$rauc_json" ]] \
    || die "preflight_scenario_validate_live: RAUC returned empty response"

  # Store for downstream consumption.
  PF_SNAPSHOT_RAUC_JSON="$rauc_json"

  # --- Phase 2: Query bootconf once (single authoritative read) ---
  local bootconf_slot
  bootconf_slot="$(steamos-bootconf this-image 2>/dev/null)" \
    || die "preflight_scenario_validate_live: steamos-bootconf this-image failed"

  # Validate bootconf slot is exactly A or B.
  _pf_validate_bootconf_slot "$bootconf_slot"

  PF_CURRENT_SLOT="$bootconf_slot"
  PF_SNAPSHOT_BOOTCONF_SLOT="$bootconf_slot"

  # --- Phase 3: Parse RAUC snapshot ---
  # Parse the captured JSON — do not re-query RAUC.
  local rauc_booted
  rauc_booted="$(printf '%s' "$rauc_json" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("booted",""))' 2>/dev/null)" \
    || rauc_booted=""

  [[ -n "$rauc_booted" ]] \
    || die "PF-36: RAUC booted field is empty"

  PF_SNAPSHOT_RAUC_BOOTED="$rauc_booted"

  # --- Phase 4: PF-36 — identity sources agree (pass snapshot, no re-query) ---
  _preflight_live_identity_sources_agree "$bootconf_slot" "$rauc_booted"

  debug "preflight_scenario_validate_live: all checks passed (current=$PF_CURRENT_SLOT)"
}
