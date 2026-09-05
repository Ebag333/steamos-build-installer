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

# _pf_resolve_parent_disk DEVICE
#   Determine the parent disk of a partition (NVMe, SATA, loop, etc.).
#   Handles NVMe (nvme0n1p2 → nvme0n1), SATA/USB (sda2 → sda),
#   and loop devices (loop0p1 → loop0).
#   Dies if the device path cannot be decomposed.
_pf_resolve_parent_disk() {
  local device="${1:?_pf_resolve_parent_disk: missing device path}"

  local base
  base="$(basename "$device")"

  local parent
  case "$base" in
    # NVMe: nvme0n1p2 → nvme0n1
    nvme*p[0-9]*)
      parent="${base%%p*}"
      ;;
    # Loop: loop0p1 → loop0
    loop[0-9]*p[0-9]*)
      parent="${base%%p*}"
      ;;
    # SATA/USB: sda2 → sda, vda1 → vda, nvme0n1 (no partition suffix)
    *[0-9])
      # Strip trailing digits (partition number) from the base name.
      parent="${base%%[0-9]*}"
      # Handle extended partition letters: sda12 → sda, nvme0n1p12 → nvme0n1
      case "$parent" in
        nvme*lp) parent="${parent%%p}" ;;
      esac
      ;;
    *)
      parent="$base"
      ;;
  esac

  [[ -n "$parent" ]] \
    || die "_pf_resolve_parent_disk: could not determine parent of '$device'"

  echo "$parent"
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

# preflight_build_efi_target_unambiguous()
#   PF-27: Strict policy — exactly one efi-A device exists under
#   /dev/disk/by-partsets/A/efi and no efi-B device exists.
#   A stale efi-B indicates an incomplete previous flash or partition
#   corruption.  The build must not proceed until the disk is clean.
preflight_build_efi_target_unambiguous() {
  local efi_a efi_b

  efi_a="$(readlink -f "/dev/disk/by-partsets/A/efi" 2>/dev/null)" || efi_a=""
  efi_b="$(readlink -f "/dev/disk/by-partsets/B/efi" 2>/dev/null)" || efi_b=""

  if [[ -n "$efi_b" && -b "$efi_b" ]]; then
    die "PF-27: efi-B device exists ($efi_b) — refusing to proceed (strict policy: no efi-B allowed during build)"
  fi

  if [[ -z "$efi_a" || ! -b "$efi_a" ]]; then
    die "PF-27: efi-A device not found or not a block device"
  fi

  debug "PF-27: efi target unambiguous (efi-A=$efi_a, no efi-B)"
}

# preflight_build_partitions_same_image()
#   PF-28: Verify rootfs-A and efi-A belong to the same parent disk.
#   This confirms the source image partitions are co-located and the
#   build will not accidentally mix partitions from different disks.
preflight_build_partitions_same_image() {
  local rootfs_a efi_a

  rootfs_a="$(readlink -f "/dev/disk/by-partsets/A/rootfs" 2>/dev/null)" \
    || die "PF-28: cannot resolve rootfs-A device"
  efi_a="$(readlink -f "/dev/disk/by-partsets/A/efi" 2>/dev/null)" \
    || die "PF-28: cannot resolve efi-A device"

  [[ -b "$rootfs_a" ]] \
    || die "PF-28: rootfs-A is not a block device: $rootfs_a"
  [[ -b "$efi_a" ]] \
    || die "PF-28: efi-A is not a block device: $efi_a"

  local rootfs_parent efi_parent
  rootfs_parent="$(_pf_resolve_parent_disk "$rootfs_a")"
  efi_parent="$(_pf_resolve_parent_disk "$efi_a")"

  if [[ "$rootfs_parent" != "$efi_parent" ]]; then
    die "PF-28: rootfs-A ($rootfs_a) and efi-A ($efi_a) are on different disks ($rootfs_parent != $efi_parent)"
  fi

  debug "PF-28: rootfs-A and efi-A share parent disk: $rootfs_parent"
}

# preflight_flashless_slot_sources_agree()
#   PF-29: Verify that steamos-bootconf "this-image" agrees with RAUC
#   "booted".  Both must resolve to the same slot.
#   When RAUC returns "dev", trust bootconf (accept "dev" as agreement).
preflight_flashless_slot_sources_agree() {
  local bootconf_slot rauc_booted rauc_slot

  bootconf_slot="$(steamos-bootconf this-image 2>/dev/null)" \
    || die "PF-29: steamos-bootconf this-image failed"

  rauc_booted="$(rauc status --output-format=json 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("booted",""))' 2>/dev/null)" \
    || rauc_booted=""

  [[ -n "$rauc_booted" ]] \
    || die "PF-29: RAUC booted field is empty"

  rauc_slot="$(_pf_map_rauc_booted_to_slot "$rauc_booted")"

  # "dev" from RAUC means development boot — trust bootconf entirely.
  if [[ "$rauc_slot" == "dev" ]]; then
    debug "PF-29: RAUC booted=dev — trusting bootconf slot: $bootconf_slot"
    return 0
  fi

  if [[ "$rauc_slot" != "$bootconf_slot" ]]; then
    die "PF-29: slot sources disagree (bootconf=$bootconf_slot, RAUC=$rauc_slot)"
  fi

  debug "PF-29: slot sources agree: $bootconf_slot"
}

# preflight_flashless_target_is_standby()
#   PF-30: Verify the target slot is NOT the currently booted slot.
#   Overwriting the active slot would be catastrophic.
#   Sets: PF_CURRENT_SLOT, PF_TARGET_SLOT (global).
preflight_flashless_target_is_standby() {
  local bootconf_slot
  bootconf_slot="$(steamos-bootconf this-image 2>/dev/null)" \
    || die "PF-30: steamos-bootconf this-image failed"

  PF_CURRENT_SLOT="$bootconf_slot"

  case "$PF_CURRENT_SLOT" in
    A) PF_TARGET_SLOT="B" ;;
    B) PF_TARGET_SLOT="A" ;;
    *) die "PF-30: unexpected current slot: $PF_CURRENT_SLOT" ;;
  esac

  if [[ "$PF_TARGET_SLOT" == "$PF_CURRENT_SLOT" ]]; then
    die "PF-30: target slot ($PF_TARGET_SLOT) equals current slot ($PF_CURRENT_SLOT) — refusing to overwrite active slot"
  fi

  debug "PF-30: target=$PF_TARGET_SLOT is standby (current=$PF_CURRENT_SLOT)"
}

# preflight_flashless_target_efi_not_mounted()
#   PF-31: Verify the target EFI partition is not already mounted.
#   A mounted target EFI would indicate a stale mount from a previous
#   operation, which could corrupt the filesystem.
preflight_flashless_target_efi_not_mounted() {
  local target_slot="${1:-}"
  local efi_dev

  if [[ -z "$target_slot" ]]; then
    target_slot="${PF_TARGET_SLOT:?preflight_flashless_target_efi_not_mounted: PF_TARGET_SLOT not set}"
  fi

  efi_dev="$(readlink -f "/dev/disk/by-partsets/$target_slot/efi" 2>/dev/null)" \
    || die "PF-31: cannot resolve target EFI device for slot $target_slot"

  [[ -b "$efi_dev" ]] \
    || die "PF-31: target EFI is not a block device: $efi_dev"

  local mounts
  mounts="$(findmnt -rn -S "$efi_dev" 2>/dev/null)" || mounts=""

  if [[ -n "$mounts" ]]; then
    die "PF-31: target EFI is already mounted: $efi_dev"
  fi

  debug "PF-31: target EFI not mounted: $efi_dev"
}

# preflight_flashless_no_pending_transition()
#   PF-32: Verify there is no pending slot transition by checking that
#   steamos-bootconf "selected-image" matches the current slot.
#   A mismatch means the system is about to reboot into a different slot
#   and overwriting the target could strand the system.
preflight_flashless_no_pending_transition() {
  local bootconf_slot selected

  bootconf_slot="$(steamos-bootconf this-image 2>/dev/null)" \
    || die "PF-32: steamos-bootconf this-image failed"

  selected="$(steamos-bootconf selected-image 2>/dev/null)" \
    || die "PF-32: steamos-bootconf selected-image failed"

  if [[ "$selected" != "$bootconf_slot" ]]; then
    die "PF-32: pending slot transition detected (current=$bootconf_slot, selected=$selected) — refusing flashless install"
  fi

  debug "PF-32: no pending transition (selected=$selected == current=$bootconf_slot)"
}

# preflight_flashless_slot_values_valid()
#   PF-33: Verify slot values are exactly A or B.
#   Catches corrupted slot state from RAUC or bootconf.
preflight_flashless_slot_values_valid() {
  local current="${1:?preflight_flashless_slot_values_valid: missing current slot}"
  local target="${2:?preflight_flashless_slot_values_valid: missing target slot}"

  case "$current" in
    A | B) ;;
    *) die "PF-33: invalid current slot value: '$current'" ;;
  esac

  case "$target" in
    A | B) ;;
    *) die "PF-33: invalid target slot value: '$target'" ;;
  esac

  debug "PF-33: slot values valid (current=$current, target=$target)"
}

# preflight_recovery_target_explicit()
#   PF-34: Verify the recovery target slot was resolved independently
#   (not inherited from a stale global).  The caller must provide the
#   target explicitly — recovery must not rely on unscoped host-side
#   steamos-bootconf.
#   Args: $1 = explicitly provided target slot (A or B)
#   Sets: PF_TARGET_SLOT (global).
preflight_recovery_target_explicit() {
  local explicit_target="${1:?preflight_recovery_target_explicit: missing explicit target slot}"

  case "$explicit_target" in
    A | B) ;;
    *) die "PF-34: invalid recovery target slot: '$explicit_target'" ;;
  esac

  PF_TARGET_SLOT="$explicit_target"

  debug "PF-34: recovery target explicitly set: $PF_TARGET_SLOT"
}

# preflight_recovery_target_devices_agree()
#   PF-35: Verify rootfs, EFI, and partset for the target slot are on
#   the same parent disk.  This prevents a partial flash where rootfs
#   lands on one disk and EFI on another.
preflight_recovery_target_devices_agree() {
  local target_slot="${1:-${PF_TARGET_SLOT:?preflight_recovery_target_devices_agree: PF_TARGET_SLOT not set}}"

  local rootfs_dev efi_dev var_dev
  rootfs_dev="$(readlink -f "/dev/disk/by-partsets/$target_slot/rootfs" 2>/dev/null)" \
    || die "PF-35: cannot resolve target rootfs for slot $target_slot"
  efi_dev="$(readlink -f "/dev/disk/by-partsets/$target_slot/efi" 2>/dev/null)" \
    || die "PF-35: cannot resolve target EFI for slot $target_slot"
  var_dev="$(readlink -f "/dev/disk/by-partsets/$target_slot/var" 2>/dev/null)" \
    || die "PF-35: cannot resolve target var for slot $target_slot"

  [[ -b "$rootfs_dev" ]] \
    || die "PF-35: target rootfs is not a block device: $rootfs_dev"
  [[ -b "$efi_dev" ]] \
    || die "PF-35: target EFI is not a block device: $efi_dev"
  [[ -b "$var_dev" ]] \
    || die "PF-35: target var is not a block device: $var_dev"

  local rootfs_parent efi_parent var_parent
  rootfs_parent="$(_pf_resolve_parent_disk "$rootfs_dev")"
  efi_parent="$(_pf_resolve_parent_disk "$efi_dev")"
  var_parent="$(_pf_resolve_parent_disk "$var_dev")"

  if [[ "$rootfs_parent" != "$efi_parent" ]]; then
    die "PF-35: target devices on different disks (rootfs=$rootfs_dev parent=$rootfs_parent, efi=$efi_dev parent=$efi_parent)"
  fi

  if [[ "$rootfs_parent" != "$var_parent" ]]; then
    die "PF-35: target devices on different disks (rootfs=$rootfs_dev parent=$rootfs_parent, var=$var_dev parent=$var_parent)"
  fi

  debug "PF-35: target devices on same disk: $rootfs_parent"
}

# preflight_live_identity_sources_agree()
#   PF-36: Verify RAUC, bootconf, root, and EFI identity sources agree.
#   All must resolve to the same slot.
#   When RAUC returns "dev", trust bootconf (accept "dev" as agreement).
#   Skip root/EFI slot resolution if /dev/disk/by-partsets/ doesn't exist.
#   Cross-reference partset devices against the actual mounted / and /efi
#   via findmnt to ensure the booted system is using the expected partitions.
preflight_live_identity_sources_agree() {
  local bootconf_slot rauc_booted rauc_slot

  bootconf_slot="$(steamos-bootconf this-image 2>/dev/null)" \
    || die "PF-36: steamos-bootconf this-image failed"

  rauc_booted="$(rauc status --output-format=json 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("booted",""))' 2>/dev/null)" \
    || rauc_booted=""

  [[ -n "$rauc_booted" ]] \
    || die "PF-36: RAUC booted field is empty"

  rauc_slot="$(_pf_map_rauc_booted_to_slot "$rauc_booted")"

  # "dev" from RAUC means development boot — trust bootconf entirely.
  if [[ "$rauc_slot" == "dev" ]]; then
    debug "PF-36: RAUC booted=dev — trusting bootconf slot: $bootconf_slot"
  else
    if [[ "$rauc_slot" != "$bootconf_slot" ]]; then
      die "PF-36: slot sources disagree (bootconf=$bootconf_slot, RAUC=$rauc_slot)"
    fi
    debug "PF-36: bootconf and RAUC agree: $bootconf_slot"
  fi

  # Skip root/EFI slot resolution if /dev/disk/by-partsets/ doesn't exist.
  if [[ ! -d "/dev/disk/by-partsets" ]]; then
    warn "PF-36: /dev/disk/by-partsets/ not found — skipping root/EFI slot resolution"
    return 0
  fi

  # Verify rootfs for the bootconf slot actually resolves.
  local rootfs_dev
  rootfs_dev="$(readlink -f "/dev/disk/by-partsets/$bootconf_slot/rootfs" 2>/dev/null)" || true
  if [[ -n "$rootfs_dev" ]]; then
    [[ -b "$rootfs_dev" ]] \
      || die "PF-36: rootfs for slot $bootconf_slot is not a block device: $rootfs_dev"
    debug "PF-36: rootfs resolves for slot $bootconf_slot: $rootfs_dev"
  fi

  # Verify EFI for the bootconf slot actually resolves.
  local efi_dev
  efi_dev="$(readlink -f "/dev/disk/by-partsets/$bootconf_slot/efi" 2>/dev/null)" || true
  if [[ -n "$efi_dev" ]]; then
    [[ -b "$efi_dev" ]] \
      || die "PF-36: EFI for slot $bootconf_slot is not a block device: $efi_dev"
    debug "PF-36: EFI resolves for slot $bootconf_slot: $efi_dev"
  fi

  # Cross-reference: verify that the actual mounted / device matches the
  # partset rootfs device for the booted slot.
  local mounted_root
  mounted_root="$(findmnt -rn -o SOURCE / 2>/dev/null)" || mounted_root=""
  if [[ -n "$mounted_root" && -n "$rootfs_dev" ]]; then
    local mounted_root_base
    mounted_root_base="$(basename "$mounted_root")"
    local rootfs_dev_base
    rootfs_dev_base="$(basename "$rootfs_dev")"
    if [[ "$mounted_root" != "$rootfs_dev" && "$mounted_root_base" != "$rootfs_dev_base" ]]; then
      die "PF-36: mounted / device ($mounted_root) does not match partset rootfs ($rootfs_dev) for slot $bootconf_slot"
    fi
    debug "PF-36: mounted / device matches partset rootfs: $mounted_root"
  fi

  # Cross-reference: verify that the actual mounted /efi device matches the
  # partset EFI device for the booted slot.
  local mounted_efi
  mounted_efi="$(findmnt -rn -o SOURCE /efi 2>/dev/null)" || mounted_efi=""
  if [[ -n "$mounted_efi" && -n "$efi_dev" ]]; then
    local mounted_efi_base
    mounted_efi_base="$(basename "$mounted_efi")"
    local efi_dev_base
    efi_dev_base="$(basename "$efi_dev")"
    if [[ "$mounted_efi" != "$efi_dev" && "$mounted_efi_base" != "$efi_dev_base" ]]; then
      die "PF-36: mounted /efi device ($mounted_efi) does not match partset EFI ($efi_dev) for slot $bootconf_slot"
    fi
    debug "PF-36: mounted /efi device matches partset EFI: $mounted_efi"
  fi

  debug "PF-36: live identity sources agree"
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

  debug "preflight_scenario_validate_build: loop=$loop_dev rootfs=$rootfs_dev efi=$efi_dev"

  # PF-26: Root required.
  preflight_scenario_require_root

  # PF-27: EFI target unambiguous (no efi-B).
  preflight_build_efi_target_unambiguous

  # PF-28: rootfs-A and efi-A on same parent disk.
  preflight_build_partitions_same_image

  debug "preflight_scenario_validate_build: all checks passed"
}

# preflight_scenario_validate_flashless()
#   Run all flashless-scenario preflight checks.
#   Sets: PF_CURRENT_SLOT, PF_TARGET_SLOT (global).
preflight_scenario_validate_flashless() {
  debug "preflight_scenario_validate_flashless: starting"

  # PF-26: Root required.
  preflight_scenario_require_root

  # PF-29: Slot sources agree (bootconf vs RAUC).
  preflight_flashless_slot_sources_agree

  # PF-30: Target is standby (not active).  Sets PF_CURRENT_SLOT, PF_TARGET_SLOT.
  preflight_flashless_target_is_standby

  # PF-33: Slot values are exactly A or B.
  preflight_flashless_slot_values_valid "$PF_CURRENT_SLOT" "$PF_TARGET_SLOT"

  # PF-31: Target EFI not mounted.
  preflight_flashless_target_efi_not_mounted "$PF_TARGET_SLOT"

  # PF-32: No pending transition.
  preflight_flashless_no_pending_transition

  debug "preflight_scenario_validate_flashless: all checks passed (current=$PF_CURRENT_SLOT, target=$PF_TARGET_SLOT)"
}

# preflight_scenario_validate_recovery PARTSET
#   Run all recovery-scenario preflight checks.
#   Args: PARTSET — explicitly provided target slot (A or B)
#   Sets: PF_TARGET_SLOT (global).
preflight_scenario_validate_recovery() {
  local partset="${1:?preflight_scenario_validate_recovery: missing target slot}"

  debug "preflight_scenario_validate_recovery: target=$partset"

  # PF-26: Root required.
  preflight_scenario_require_root

  # PF-34: Target resolved independently (not from stale global).
  preflight_recovery_target_explicit "$partset"

  # PF-35: Target devices on same disk.
  preflight_recovery_target_devices_agree "$PF_TARGET_SLOT"

  debug "preflight_scenario_validate_recovery: all checks passed (target=$PF_TARGET_SLOT)"
}

# preflight_scenario_validate_live()
#   Run all live-scenario preflight checks.
#   Sets: PF_CURRENT_SLOT (global).
preflight_scenario_validate_live() {
  debug "preflight_scenario_validate_live: starting"

  # PF-26: Root required.
  preflight_scenario_require_root

  # PF-36: Identity sources agree (RAUC/bootconf/root/efi).
  # Also sets implicit current slot context for downstream consumers.
  local bootconf_slot
  bootconf_slot="$(steamos-bootconf this-image 2>/dev/null)" \
    || die "preflight_scenario_validate_live: steamos-bootconf this-image failed"
  PF_CURRENT_SLOT="$bootconf_slot"

  preflight_live_identity_sources_agree

  debug "preflight_scenario_validate_live: all checks passed (current=$PF_CURRENT_SLOT)"
}
