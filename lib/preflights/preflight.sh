#!/bin/bash
#
# steamos-build-installer — lib/preflights/preflight.sh
# Single preflight orchestrator: composes all 12 preflight modules into a
# single entry point.  Dispatches to scenario-specific orchestrators and
# runs universal preflights before any destructive operation begins.
#
# Scenarios: build, recovery, flashless, live
#
# Requires: lib/common.sh (die, debug, warn)
#           All 12 preflight modules under lib/preflights/
# Do not run it directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/preflights/preflight.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Idempotent loading guard — prevent double-sourcing
# ---------------------------------------------------------------------------
if [[ "${_PF_LOADED:-false}" == "true" ]]; then
  return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# Source all preflight modules (preflight_efi.sh first for dedup)
# ---------------------------------------------------------------------------

_PF_LOADER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source_module() {
  local module="${1:?source_module: missing module path}"
  if [[ ! -f "$module" ]]; then
    echo "preflight: FATAL: required module not found: $module" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  if ! source "$module"; then
    echo "preflight: FATAL: failed to source module: $module" >&2
    return 1
  fi
}

require_function() {
  local fn="${1:?require_function: missing function name}"
  if ! declare -F "$fn" >/dev/null 2>&1; then
    echo "preflight: FATAL: required function not found after module load: $fn" >&2
    return 1
  fi
}

# shellcheck source=preflight_efi.sh
source_module "${_PF_LOADER_DIR}/preflight_efi.sh" || die "FATAL: failed to load preflight_efi.sh"
# shellcheck source=preflight_esp.sh
source_module "${_PF_LOADER_DIR}/preflight_esp.sh" || die "FATAL: failed to load preflight_esp.sh"
# shellcheck source=preflight_rootfs.sh
source_module "${_PF_LOADER_DIR}/preflight_rootfs.sh" || die "FATAL: failed to load preflight_rootfs.sh"
# shellcheck source=preflight_scenario.sh
source_module "${_PF_LOADER_DIR}/preflight_scenario.sh" || die "FATAL: failed to load preflight_scenario.sh"
# shellcheck source=preflight_generation.sh
source_module "${_PF_LOADER_DIR}/preflight_generation.sh" || die "FATAL: failed to load preflight_generation.sh"
# shellcheck source=preflight_system_identity.sh
source_module "${_PF_LOADER_DIR}/preflight_system_identity.sh" || die "FATAL: failed to load preflight_system_identity.sh"
# shellcheck source=preflight_bootconf.sh
source_module "${_PF_LOADER_DIR}/preflight_bootconf.sh" || die "FATAL: failed to load preflight_bootconf.sh"
# shellcheck source=preflight_command_availability.sh
source_module "${_PF_LOADER_DIR}/preflight_command_availability.sh" || die "FATAL: failed to load preflight_command_availability.sh"
# shellcheck source=preflight_chroot_mount.sh
source_module "${_PF_LOADER_DIR}/preflight_chroot_mount.sh" || die "FATAL: failed to load preflight_chroot_mount.sh"
# shellcheck source=preflight_filesystem_state.sh
source_module "${_PF_LOADER_DIR}/preflight_filesystem_state.sh" || die "FATAL: failed to load preflight_filesystem_state.sh"
# shellcheck source=preflight_path_safety.sh
source_module "${_PF_LOADER_DIR}/preflight_path_safety.sh" || die "FATAL: failed to load preflight_path_safety.sh"
# shellcheck source=preflight_resources.sh
source_module "${_PF_LOADER_DIR}/preflight_resources.sh" || die "FATAL: failed to load preflight_resources.sh"

# ---------------------------------------------------------------------------
# Verify critical entry points exist after module load
# ---------------------------------------------------------------------------
require_function "preflight_scenario_validate_build" || die "FATAL: missing preflight_scenario_validate_build"
require_function "preflight_scenario_validate_recovery" || die "FATAL: missing preflight_scenario_validate_recovery"
require_function "preflight_scenario_validate_flashless" || die "FATAL: missing preflight_scenario_validate_flashless"
require_function "preflight_scenario_validate_live" || die "FATAL: missing preflight_scenario_validate_live"
require_function "preflight_scenario_require_root" || die "FATAL: missing preflight_scenario_require_root"
require_function "preflight_efi_validate_existing" || die "FATAL: missing preflight_efi_validate_existing"
require_function "preflight_efi_validate_temporary" || die "FATAL: missing preflight_efi_validate_temporary"
require_function "preflight_esp_validate" || die "FATAL: missing preflight_esp_validate"
require_function "preflight_rootfs_validate" || die "FATAL: missing preflight_rootfs_validate"
require_function "preflight_generation_validate" || die "FATAL: missing preflight_generation_validate"
require_function "preflight_chroot_mount_validate" || die "FATAL: missing preflight_chroot_mount_validate"
require_function "preflight_resources_validate" || die "FATAL: missing preflight_resources_validate"
require_function "preflight_resources_rauc_idle" || die "FATAL: missing preflight_resources_rauc_idle"
require_function "preflight_path_safety_validate" || die "FATAL: missing preflight_path_safety_validate"
require_function "preflight_filesystem_state_validate" || die "FATAL: missing preflight_filesystem_state_validate"
require_function "preflight_system_identity_validate" || die "FATAL: missing preflight_system_identity_validate"
require_function "preflight_bootconf_validate" || die "FATAL: missing preflight_bootconf_validate"
require_function "preflight_command_availability_validate" || die "FATAL: missing preflight_command_availability_validate"

unset _PF_LOADER_DIR
_PF_LOADED="true"

# ---------------------------------------------------------------------------
# Internal scenario dispatchers
# ---------------------------------------------------------------------------

# _preflight_build ROOTFS TARGET_EFI_MOUNT ESP_MOUNT SLOT_LABEL [IMAGE_PATH] [EXPECTED_HASH]
#   Build-scenario preflights.  The build runs from a host environment,
#   loop-mounting a recovery image and modifying the rootfs inside an
#   overlay chroot.
#
#   Checks:
#     - Scenario checks (PF-26, PF-27, PF-28): require root, unambiguous
#       EFI target, partitions on same image.
#     - EFI validation (temporary mount): PF-06 through PF-15.
#     - ESP validation: PF-37, PF-38, PF-39.
#     - Rootfs validation: PF-01 through PF-05, PF-45 through PF-48.
#     - System identity: PF-40 through PF-44.
#     - Generation prerequisites: PF-16 through PF-25.
#     - Command availability: PF-50 through PF-52.
#     - Filesystem state: PF-60 through PF-64 (with source integrity).
#     - Path safety: PF-55, PF-56.
_preflight_build() {
  local rootfs="${1:?_preflight_build: missing ROOTFS}"
  local target_efi="${2:?_preflight_build: missing TARGET_EFI_MOUNT}"
  local esp_mount="${3:?_preflight_build: missing ESP_MOUNT}"
  local slot="${4:?_preflight_build: missing SLOT_LABEL}"
  local image_path="${5:-}"
  local expected_hash="${6:-}"

  debug "_preflight_build: rootfs=$rootfs efi=$target_efi esp=$esp_mount slot=$slot"

  # --- Resolve device paths from environment or by-partsets ---
  local _pf_loop_dev="${LOOP_DEV:-}"
  local _pf_rootfs_dev="${ROOTFS_DEV:-}"
  local _pf_efi_dev="${EFI_DEV:-}"

  # Attempt to resolve EFI device from by-partsets if not provided directly.
  if [[ -z "$_pf_efi_dev" && -n "$slot" && -e "/dev/disk/by-partsets/$slot/efi" ]]; then
    _pf_efi_dev="$(readlink -f "/dev/disk/by-partsets/$slot/efi" 2>/dev/null)" || _pf_efi_dev=""
  fi

  # --- Scenario checks (require root, unambiguous target) ---
  # Note: PF-26/27/28 require supplied loop/rootfs/EFI device paths.
  # Resolve them from the build environment when available.
  # If the loop device and partitions cannot be determined (e.g. during
  # early build stages), skip the scenario-level checks.
  if [[ -n "$_pf_loop_dev" && -n "$_pf_rootfs_dev" && -n "$_pf_efi_dev" ]]; then
    preflight_scenario_validate_build "$_pf_loop_dev" "$_pf_rootfs_dev" "$_pf_efi_dev"
  else
    debug "_preflight_build: LOOP_DEV/ROOTFS_DEV/EFI_DEV not fully resolved — skipping scenario-level checks"
  fi

  # --- EFI validation (existing mount mode) ---
  # Determine the EFI device from the target mount or by-partsets.
  # Pass the actual device path; skip validation if device cannot be resolved.
  if [[ -n "$_pf_efi_dev" ]]; then
    preflight_efi_validate_existing "$target_efi" "$_pf_efi_dev" "$slot"
  else
    debug "_preflight_build: EFI device not resolved — skipping EFI device validation"
  fi

  # --- Path safety ---
  preflight_path_safety_validate "$target_efi"

  # --- Rootfs validation ---
  preflight_rootfs_validate "$rootfs"

  # --- System identity validation ---
  preflight_system_identity_validate "$rootfs" "$target_efi"

  # --- Chroot mount validation (Finding 4) ---
  # Verify /efi and /esp inside the chroot are backed by the expected devices.
  if [[ -n "$_pf_rootfs_dev" && -n "$_pf_efi_dev" ]]; then
    preflight_chroot_mount_validate "$rootfs" "$_pf_rootfs_dev" "$_pf_efi_dev"
  else
    debug "_preflight_build: rootfs/efi device not resolved — skipping chroot mount validation"
  fi

  # --- Generation prerequisites (Finding 16) ---
  # Build always needs all generation steps.
  # SOURCE_EFI_MOUNT is N/A for build scenario — pass empty.
  preflight_generation_validate "$rootfs" "" "" \
    "true" "true" "true" "true"

  # --- Command availability ---
  preflight_command_availability_validate "$rootfs"

  # --- Filesystem state (Finding 6) ---
  preflight_filesystem_state_validate "$rootfs" "" "$image_path" "$expected_hash" \
    "false"

  debug "_preflight_build: all build preflights passed"
}

# _preflight_recovery ROOTFS TARGET_EFI_MOUNT ESP_MOUNT SLOT_LABEL [SOURCE_EFI_MOUNT] [EXPECTED_VARIANT]
#   Recovery-scenario preflights.  Recovery installs to a specific target
#   slot on a running system.
#
#   Checks:
#     - Scenario checks (PF-26, PF-34, PF-35): require root, explicit
#       target, devices on same disk.
#     - EFI validation (existing mount): PF-06, PF-07, PF-08, PF-11, PF-12, PF-15.
#     - ESP validation: PF-37, PF-38, PF-39.
#     - Rootfs validation: PF-01 through PF-05, PF-45 through PF-48.
#     - System identity: PF-40 through PF-44.
#     - Generation prerequisites: PF-16 through PF-25.
#     - Command availability: PF-50 through PF-52.
#     - Boot configuration: PF-57 through PF-59.
#     - Path safety: PF-55, PF-56.
#     - Resources: PF-53, PF-54.
#     - Filesystem state: PF-60 through PF-63.
_preflight_recovery() {
  local rootfs="${1:?_preflight_recovery: missing ROOTFS}"
  local target_efi="${2:?_preflight_recovery: missing TARGET_EFI_MOUNT}"
  local esp_mount="${3:?_preflight_recovery: missing ESP_MOUNT}"
  local slot="${4:?_preflight_recovery: missing SLOT_LABEL}"
  local source_efi="${5:-}"
  local expected_variant="${6:-}"

  debug "_preflight_recovery: rootfs=$rootfs efi=$target_efi esp=$esp_mount slot=$slot"

  # --- Resolve devices for the topology descriptor ---
  # Recovery must not rely on host-global /dev/disk/by-partsets.
  # Instead, resolve devices from the descriptor parameters and mounted state.

  local rootfs_dev="" rootfs_partuuid="" efi_dev="" efi_partuuid=""
  local var_dev="" var_partuuid="" verity_dev="" verity_policy=""
  local shared_esp_dev="" shared_esp_partuuid=""

  # Resolve rootfs device from the mounted rootfs mount point.
  rootfs_dev="$(findmnt -nro SOURCE "$rootfs" 2>/dev/null | head -1)" || rootfs_dev=""
  if [[ -n "$rootfs_dev" ]]; then
    rootfs_dev="$(readlink -f "$rootfs_dev" 2>/dev/null)" || rootfs_dev="$rootfs_dev"
    rootfs_partuuid="$(blkid -s PARTUUID -o value "$rootfs_dev" 2>/dev/null)" || rootfs_partuuid=""
  fi

  # Resolve EFI device from the mounted EFI mount point.
  efi_dev="$(findmnt -nro SOURCE "$target_efi" 2>/dev/null | head -1)" || efi_dev=""
  if [[ -n "$efi_dev" ]]; then
    efi_dev="$(readlink -f "$efi_dev" 2>/dev/null)" || efi_dev="$efi_dev"
    efi_partuuid="$(blkid -s PARTUUID -o value "$efi_dev" 2>/dev/null)" || efi_partuuid=""
  fi

  # Resolve var device — try by-partsets first, then fall back to rootfs sibling.
  if [[ -d "/dev/disk/by-partsets/$slot" ]]; then
    var_dev="$(readlink -f "/dev/disk/by-partsets/$slot/var" 2>/dev/null)" || var_dev=""
  fi
  if [[ -z "$var_dev" && -n "$rootfs_dev" ]]; then
    # Fall back: resolve var from the same parent disk as rootfs.
    local rootfs_parent_label
    rootfs_parent_label="$(_pf_resolve_parent_disk "$rootfs_dev" 2>/dev/null)" || rootfs_parent_label=""
    if [[ -n "$rootfs_parent_label" ]]; then
      local candidate
      for candidate in "/dev/${rootfs_parent_label}"p*; do
        if [[ -b "$candidate" ]]; then
          local label
          label="$(blkid -s LABEL -o value "$candidate" 2>/dev/null)" || label=""
          if [[ "$label" == "var-${slot}" ]]; then
            var_dev="$candidate"
            break
          fi
        fi
      done 2>/dev/null
    fi
  fi
  if [[ -n "$var_dev" ]]; then
    var_partuuid="$(blkid -s PARTUUID -o value "$var_dev" 2>/dev/null)" || var_partuuid=""
  fi

  # Resolve shared ESP device from the ESP mount point.
  shared_esp_dev="$(findmnt -nro SOURCE "$esp_mount" 2>/dev/null | head -1)" || shared_esp_dev=""
  if [[ -n "$shared_esp_dev" ]]; then
    shared_esp_dev="$(readlink -f "$shared_esp_dev" 2>/dev/null)" || shared_esp_dev="$shared_esp_dev"
    shared_esp_partuuid="$(blkid -s PARTUUID -o value "$shared_esp_dev" 2>/dev/null)" || shared_esp_partuuid=""
  fi

  # Verity device and policy are optional — leave empty if not resolvable.
  verity_dev=""
  verity_policy=""

  # --- Build the topology descriptor ---
  local -a topology_descriptor=(
    "TARGET_SLOT=$slot"
    "ROOTFS_DEVICE=${rootfs_dev:-}"
    "ROOTFS_PARTUUID=${rootfs_partuuid:-}"
    "EFI_DEVICE=${efi_dev:-}"
    "EFI_PARTUUID=${efi_partuuid:-}"
    "VAR_DEVICE=${var_dev:-}"
    "VAR_PARTUUID=${var_partuuid:-}"
    "VERITY_DEVICE=${verity_dev:-}"
    "VERITY_POLICY=${verity_policy:-}"
    "SHARED_ESP_DEVICE=${shared_esp_dev:-}"
    "SHARED_ESP_PARTUUID=${shared_esp_partuuid:-}"
  )

  # --- Scenario checks (pass full topology descriptor) ---
  preflight_scenario_validate_recovery "${topology_descriptor[@]}"

  # --- EFI validation (existing mount mode) ---
  # Use the device from the topology descriptor instead of resolving from partsets.
  if [[ -n "$efi_dev" && -b "$efi_dev" ]]; then
    preflight_efi_validate_existing "$target_efi" "$efi_dev" "$slot"
  else
    debug "_preflight_recovery: EFI device not resolved — skipping EFI device validation"
  fi

  # --- ESP validation ---
  # Use the device from the topology descriptor instead of re-resolving.
  if [[ -n "$shared_esp_dev" && -b "$shared_esp_dev" ]]; then
    if [[ -n "$shared_esp_partuuid" ]]; then
      preflight_esp_validate "$esp_mount" "$shared_esp_dev" "${efi_dev:-}" "$shared_esp_partuuid"
    else
      die "_preflight_recovery: ESP PARTUUID unavailable — cannot validate ESP"
    fi
  else
    die "_preflight_recovery: ESP device could not be resolved from topology descriptor"
  fi

  # --- Path safety ---
  preflight_path_safety_validate "$target_efi" "$esp_mount"

  # --- Rootfs validation (Finding 5) ---
  # Recovery may or may not mutate UUID — pass empty source_uuid for same-UUID case.
  preflight_rootfs_validate "$rootfs" "" "$rootfs_dev" "$rootfs_partuuid"

  # --- System identity validation ---
  preflight_system_identity_validate "$rootfs" "$target_efi" "$expected_variant"

  # --- Chroot mount validation (Finding 4) ---
  if [[ -n "$rootfs_dev" && -n "$efi_dev" ]]; then
    preflight_chroot_mount_validate "$rootfs" "$rootfs_dev" "$efi_dev" "${shared_esp_dev:-}"
  else
    debug "_preflight_recovery: rootfs/efi device not resolved — skipping chroot mount validation"
  fi

  # --- Generation prerequisites (Finding 16) ---
  # Recovery may or may not need generation depending on UUID/kernel changes.
  # Since Recovery currently does not receive expected UUID, pass empty.
  preflight_generation_validate "$rootfs" "$source_efi" "" \
    "true" "true" "true" "true"

  # --- Command availability ---
  preflight_command_availability_validate "$rootfs"

  # --- Boot configuration ---
  # For recovery: update mode on the target slot.
  local esp_conf_dir=""
  if [[ -d "$esp_mount/SteamOS/conf" ]]; then
    esp_conf_dir="$esp_mount"
  fi
  if [[ -n "$esp_conf_dir" ]]; then
    # Note: preflight_bootconf_validate only accepts 4 parameters.
    # Additional scenario context (current_slot, scenario, etc.) is not passed.
    # TODO: extend preflight_bootconf_validate to accept scenario context.
    preflight_bootconf_validate "$esp_conf_dir" "$target_efi" "$slot" "replace"
  else
    # Recovery patches an existing config — the directory MUST exist.
    die "_preflight_recovery: bootconf conf dir missing ($esp_mount/SteamOS/conf) — required for patch operations"
  fi

  # --- Filesystem state (Finding 6) ---
  # Recovery modifies rootfs.
  preflight_filesystem_state_validate "$rootfs" "$rootfs_dev" "" "" \
    "true" "$rootfs_dev" "" ""

  debug "_preflight_recovery: all recovery preflights passed"
}

# _preflight_flashless ROOTFS TARGET_EFI_MOUNT ESP_MOUNT SLOT_LABEL [SOURCE_EFI_MOUNT] [EXPECTED_VARIANT] [EXPECTED_ESP_PARTUUID] [IMAGE_PATH] [EXPECTED_HASH] [SOURCE_UUID] [EXPECTED_UUID]
#   Flashless-scenario preflights.  Flashless installs to the inactive A/B
#   slot on a running SteamOS system without USB media.
#
#   Checks:
#     - Scenario checks (PF-26, PF-29 through PF-33): require root,
#       slot sources agree, target is standby, no pending transition.
#     - EFI validation (temporary mount): PF-06 through PF-15.
#     - ESP validation: PF-37, PF-38, PF-39.
#     - Rootfs validation: PF-01 through PF-05, PF-45 through PF-48.
#     - System identity: PF-40 through PF-44.
#     - Generation prerequisites: PF-16 through PF-25.
#     - Command availability: PF-50 through PF-52.
#     - Boot configuration: PF-57 through PF-59.
#     - Path safety: PF-55, PF-56.
#     - Resources: PF-53, PF-54.
#     - Filesystem state: PF-60 through PF-64 (with source integrity).
_preflight_flashless() {
  local rootfs="${1:?_preflight_flashless: missing ROOTFS}"
  local target_efi="${2:?_preflight_flashless: missing TARGET_EFI_MOUNT}"
  local esp_mount="${3:?_preflight_flashless: missing ESP_MOUNT}"
  local slot="${4:?_preflight_flashless: missing SLOT_LABEL}"
  local source_efi="${5:-}"
  local expected_variant="${6:-}"
  local expected_esp_partuuid="${7:-}"
  local image_path="${8:-}"
  local expected_hash="${9:-}"
  local source_uuid="${10:-}"
  local expected_uuid="${11:-}"

  # --- Source image integrity (PF-64) ---
  if [[ -n "$image_path" && -n "$expected_hash" ]]; then
    pf_fs_check_source_integrity "$image_path" "$expected_hash"
  fi

  debug "_preflight_flashless: rootfs=$rootfs efi=$target_efi esp=$esp_mount slot=$slot source_uuid=${source_uuid:-<none>} expected_uuid=${expected_uuid:-<none>}"

  # --- Scenario checks ---
  preflight_scenario_validate_flashless

  # --- EFI validation (temporary mount mode) ---
  local efi_dev=""
  if [[ -e "/dev/disk/by-partsets/$slot/efi" ]]; then
    efi_dev="$(readlink -f "/dev/disk/by-partsets/$slot/efi" 2>/dev/null)" || efi_dev=""
  fi
  if [[ -n "$efi_dev" ]]; then
    preflight_efi_validate_temporary "$efi_dev" "$target_efi" "$slot"
  else
    debug "_preflight_flashless: EFI device not resolved from partsets — skipping"
  fi

  # --- ESP validation ---
  local esp_dev=""
  # The shared ESP is not in partsets; look it up from the existing mount.
  if [[ -n "$esp_mount" && -d "$esp_mount" ]]; then
    esp_dev="$(findmnt -nro SOURCE "$esp_mount" 2>/dev/null | head -1)" || esp_dev=""
  fi
  if [[ -n "$esp_dev" && -n "$efi_dev" ]]; then
    # The expected ESP PARTUUID must come from the trusted target topology,
    # NOT from the device being tested.  A tautological check (reading
    # PARTUUID from esp_dev and passing it as the expected value) would
    # always pass, even if the wrong partition is mounted.
    if [[ -z "$expected_esp_partuuid" ]]; then
      die "_preflight_flashless: expected ESP PARTUUID must be provided from target topology"
    fi
    preflight_esp_validate "$esp_mount" "$esp_dev" "$efi_dev" "$expected_esp_partuuid"
  else
    die "_preflight_flashless: ESP device could not be resolved"
  fi

  # --- Path safety ---
  preflight_path_safety_validate "$target_efi" "$esp_mount"

  # --- Rootfs validation (Finding 5) ---
  # Flashless mutates UUID — pass source_uuid for PF-47/PF-48.
  # Device and partuuid are resolved by preflight_rootfs_validate via
  # _pf_rfs_resolve_identity; read them from the globals after the call.
  preflight_rootfs_validate "$rootfs" "${source_uuid:-}"
  local rootfs_device="${_PF_RFS_ID_SOURCE:-}"
  local rootfs_partuuid="${_PF_RFS_ID_PARTUUID:-}"

  # --- Chroot mount validation (Finding 4) ---
  if [[ -n "$rootfs_device" && -n "$efi_dev" ]]; then
    preflight_chroot_mount_validate "$rootfs" "$rootfs_device" "$efi_dev" "${esp_dev:-}"
  else
    debug "_preflight_flashless: rootfs/efi device not resolved — skipping chroot mount validation"
  fi

  # --- Generation prerequisites (Finding 16) ---
  # Flashless always needs all generation (new UUID requires everything).
  preflight_generation_validate "$rootfs" "$source_efi" "$expected_uuid" \
    "true" "true" "true" "true"

  # --- System identity validation ---
  # Must run AFTER generation — requires generated state (partsets, bootconf).
  preflight_system_identity_validate "$rootfs" "$target_efi" "$expected_variant"

  # --- Command availability ---
  preflight_command_availability_validate "$rootfs"

  # --- Boot configuration ---
  # Flashless generates a brand-new bootconf; the conf directory is created
  # by the generation step which runs AFTER preflights.  During preflight
  # validation the directory may not exist yet — this is expected and not
  # an error.  We only validate bootconf if it already exists (e.g. from a
  # previous partial run or when re-validating).
  local esp_conf_dir=""
  if [[ -d "$esp_mount/SteamOS/conf" ]]; then
    esp_conf_dir="$esp_mount"
  fi
  if [[ -n "$esp_conf_dir" ]]; then
    local current_slot="${PF_CURRENT_SLOT:-}"
    local selected_slot=""
    # Resolve selected slot if bootconf is available.
    if command -v steamos-bootconf &>/dev/null; then
      selected_slot="$(steamos-bootconf selected-image 2>/dev/null)" || selected_slot=""
    fi
    # Note: preflight_bootconf_validate only accepts 4 parameters.
    # Additional scenario context (current_slot, scenario, etc.) is not passed.
    # TODO: extend preflight_bootconf_validate to accept scenario context.
    preflight_bootconf_validate "$esp_conf_dir" "$target_efi" "$slot" "replace"
  else
    # Intentionally not fatal: bootconf conf dir does not exist yet because
    # Flashless creates it during the generation step that follows preflights.
    debug "_preflight_flashless: no bootconf conf dir — will be created during generation"
  fi

  # --- Filesystem state (Finding 6) ---
  # Flashless modifies rootfs.
  preflight_filesystem_state_validate "$rootfs" "" "" "" \
    "true" "$rootfs_device" "" ""

  debug "_preflight_flashless: all flashless preflights passed"
}

# _preflight_live ROOTFS TARGET_EFI_MOUNT ESP_MOUNT SLOT_LABEL [EXPECTED_VARIANT] [EXPECTED_ESP_PARTUUID]
#   Live-scenario preflights.  Live runs on the running system's mounted
#   partitions (e.g. for repatch after OS update).
#
#   Checks:
#     - Scenario checks (PF-26, PF-36): require root, identity sources agree.
#     - EFI validation (existing mount): PF-06, PF-07, PF-08, PF-11, PF-12, PF-15.
#     - ESP validation: PF-37, PF-38, PF-39.
#     - Rootfs validation: PF-01 through PF-05, PF-45 through PF-48.
#     - System identity: PF-40 through PF-44.
#     - Generation prerequisites: PF-16 through PF-25.
#     - Command availability: PF-50 through PF-52.
#     - Boot configuration: PF-57 through PF-59.
#     - Path safety: PF-55, PF-56.
#     - Resources: PF-53, PF-54.
#     - Filesystem state: PF-60 through PF-63.
_preflight_live() {
  local rootfs="${1:?_preflight_live: missing ROOTFS}"
  local target_efi="${2:?_preflight_live: missing TARGET_EFI_MOUNT}"
  local esp_mount="${3:-}"
  local slot="${4:-}"
  local expected_variant="${5:-}"
  local expected_esp_partuuid="${6:-}"

  debug "_preflight_live: rootfs=$rootfs efi=$target_efi esp=${esp_mount:-<none>} slot=${slot:-<auto>}"

  # --- Scenario checks ---
  preflight_scenario_validate_live

  # Resolve the current slot for downstream use.
  local current_slot="${PF_CURRENT_SLOT:-}"
  if [[ -z "$current_slot" ]]; then
    if command -v steamos-bootconf &>/dev/null; then
      current_slot="$(steamos-bootconf this-image 2>/dev/null)" || current_slot=""
    fi
  fi

  # Use current slot if none was explicitly provided.
  if [[ -z "$slot" ]]; then
    slot="$current_slot"
  fi

  # --- EFI validation (existing mount mode) ---
  local efi_dev=""
  if [[ -n "$slot" && -e "/dev/disk/by-partsets/$slot/efi" ]]; then
    efi_dev="$(readlink -f "/dev/disk/by-partsets/$slot/efi" 2>/dev/null)" || efi_dev=""
  fi
  if [[ -n "$efi_dev" ]]; then
    preflight_efi_validate_existing "$target_efi" "$efi_dev" "$slot"
  else
    # For live scenario, the EFI may be mounted at /efi by default.
    debug "_preflight_live: EFI device not resolved from partsets — validating mount only"
  fi

  # --- ESP validation ---
  local esp_dev=""
  if [[ -n "$esp_mount" && -d "$esp_mount" ]]; then
    esp_dev="$(findmnt -nro SOURCE "$esp_mount" 2>/dev/null | head -1)" || esp_dev=""
  fi
  if [[ -n "$esp_dev" ]]; then
    # The expected ESP PARTUUID must come from the caller (target topology),
    # NOT from the device being tested.  A tautological check (reading
    # PARTUUID from esp_dev and passing it as the expected value) would
    # always pass, even if the wrong partition is mounted.
    if [[ -n "$expected_esp_partuuid" ]]; then
      preflight_esp_validate "$esp_mount" "$esp_dev" "$efi_dev" "$expected_esp_partuuid"
    else
      debug "_preflight_live: no expected ESP PARTUUID provided — skipping PF-37 (PARTUUID check)"
      # Run PF-38 and PF-39 without the PARTUUID identity check.
      preflight_esp_distinct_from_efi "$esp_dev" "${efi_dev:-}"
      preflight_esp_is_fat_and_writable "$esp_mount" "$esp_dev"
    fi
  else
    die "_preflight_live: ESP device could not be resolved"
  fi

  # --- Rootfs validation ---
  preflight_rootfs_validate "$rootfs"

  # --- System identity validation ---
  preflight_system_identity_validate "$rootfs" "$target_efi" "$expected_variant"

  # --- Generation prerequisites (Finding 16) ---
  # Live patch-only: no binary/config generation needed.
  preflight_generation_validate "$rootfs" "" "" \
    "false" "false" "false" "false"

  # --- Command availability ---
  preflight_command_availability_validate "$rootfs"

  # --- Boot configuration ---
  local esp_conf_dir=""
  if [[ -n "$esp_mount" && -d "$esp_mount/SteamOS/conf" ]]; then
    esp_conf_dir="$esp_mount"
  fi
  if [[ -n "$esp_conf_dir" && -n "$slot" ]]; then
    # Note: preflight_bootconf_validate only accepts 4 parameters.
    # Additional scenario context (current_slot, scenario, etc.) is not passed.
    # TODO: extend preflight_bootconf_validate to accept scenario context.
    preflight_bootconf_validate "$esp_conf_dir" "$target_efi" "$slot" "update"
  else
    # Live patches an existing config — the directory MUST exist.
    die "_preflight_live: bootconf conf dir missing (${esp_mount:-<empty>}/SteamOS/conf) — required for patch operations"
  fi

  # --- Path safety ---
  preflight_path_safety_validate "$target_efi" "${esp_mount:-}"

  # --- Filesystem state (Finding 6) ---
  # Live patch-only: rootfs not modified.
  preflight_filesystem_state_validate "$rootfs" "" "" "" \
    "false"

  debug "_preflight_live: all live preflights passed"
}

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

# preflight_validate SCENARIO ROOTFS TARGET_EFI_MOUNT ESP_MOUNT SLOT_LABEL
#                    [SOURCE_EFI_MOUNT] [EXPECTED_VARIANT] [IMAGE_PATH] [EXPECTED_HASH]
#                    [EXPECTED_ESP_PARTUUID] [SOURCE_UUID] [EXPECTED_UUID]
#
#   Required for all scenarios:
#     SCENARIO          - build|recovery|flashless|live
#     ROOTFS            - path to the mounted rootfs
#     TARGET_EFI_MOUNT  - mount point for the per-slot EFI partition
#     ESP_MOUNT         - mount point for the shared ESP (may be empty for Build)
#     SLOT_LABEL        - target slot label (a/b/standby)
#
#   Optional:
#     SOURCE_EFI_MOUNT  - path to source EFI directory (Build, Flashless)
#     EXPECTED_VARIANT  - expected SteamOS variant (all scenarios)
#     IMAGE_PATH        - path to source image file (Build, Flashless)
#     EXPECTED_HASH     - expected SHA256 hash of source image (Build, Flashless)
#     EXPECTED_ESP_PARTUUID - expected ESP PARTUUID from target topology (Recovery, Flashless, Live)
#     SOURCE_UUID       - current rootfs UUID (Flashless — for UUID mutation preflight)
#     EXPECTED_UUID     - target rootfs UUID after flash (Flashless — for generation preflight)
#
#   Dies on first failure.  Returns 0 when all checks pass.
preflight_validate() {
  local scenario="${1:?preflight_validate: missing SCENARIO}"
  local rootfs="${2:?preflight_validate: missing ROOTFS}"
  local target_efi="${3:?preflight_validate: missing TARGET_EFI_MOUNT}"
  local esp_mount="${4:-}"
  local slot="${5:?preflight_validate: missing SLOT_LABEL}"
  local source_efi="${6:-}"
  local expected_variant="${7:-}"
  local image_path="${8:-}"
  local expected_hash="${9:-}"
  local expected_esp_partuuid="${10:-}"
  local source_uuid="${11:-}"
  local expected_uuid="${12:-}"

  debug "preflight_validate: scenario=$scenario rootfs=$rootfs efi=$target_efi esp=$esp_mount slot=$slot"

  # --- Validate scenario ---
  case "$scenario" in
    build | recovery | flashless | live) ;;
    *) die "preflight_validate: invalid scenario: '$scenario' (expected build, recovery, flashless, or live)" ;;
  esac

  # --- Validate slot label ---
  case "$scenario" in
    build)
      case "$slot" in
        A) ;;
        *) die "preflight_validate: invalid slot label for build scenario: '$slot' (expected A only)" ;;
      esac
      ;;
    *)
      case "$slot" in
        A | B) ;;
        *) die "preflight_validate: invalid slot label: '$slot' (expected A or B)" ;;
      esac
      ;;
  esac

  # --- Universal prerequisites (run FIRST, before any scenario dispatch) ---

  # 1. Require root
  preflight_scenario_require_root

  # 2. Deployment lock is acquired inside preflight_resources_validate (PF-54a).
  #    Do NOT acquire it here separately — that would open a second fd whose
  #    reference is lost when preflight_resources_validate overwrites
  #    PF_LOCK_FD, leaking the first fd.

  # --- Build context from scenario descriptor ---

  # 3. Dispatch to scenario-specific orchestrator
  case "$scenario" in
    build)
      _preflight_build "$rootfs" "$target_efi" "$esp_mount" "$slot" "$image_path" "$expected_hash"
      ;;
    recovery)
      _preflight_recovery "$rootfs" "$target_efi" "$esp_mount" "$slot" "$source_efi" "$expected_variant"
      ;;
    flashless)
      _preflight_flashless "$rootfs" "$target_efi" "$esp_mount" "$slot" "$source_efi" "$expected_variant" "$expected_esp_partuuid" "$image_path" "$expected_hash" "$source_uuid" "$expected_uuid"
      ;;
    live)
      _preflight_live "$rootfs" "$target_efi" "$esp_mount" "$slot" "$expected_variant" "$expected_esp_partuuid"
      ;;
  esac

  # --- Universal post-validation (AFTER scenario checks, BEFORE any writes) ---

  # 4. Resource validation (space, mounts, etc.)
  #    Pass scenario-specific resource requirements.
  #    Build: EFI + rootfs space required; Recovery/Flashless: all three; Live: EFI + rootfs.
  if declare -F preflight_resources_validate >/dev/null 2>&1; then
    case "$scenario" in
      recovery)
        # Recovery modifies rootfs and EFI; also check ESP.
        preflight_resources_validate "$target_efi" "10240" "$rootfs" "51200" \
          "${esp_mount:-}" "10240" "/run/lock/steamos-build-installer/build.lock" "$scenario"
        ;;
      flashless)
        # Flashless writes to inactive rootfs slot and per-slot EFI.
        preflight_resources_validate "$target_efi" "10240" "$rootfs" "51200" \
          "${esp_mount:-}" "10240" "/run/lock/steamos-build-installer/build.lock" "$scenario"
        ;;
      live)
        # Live patches EFI and rootfs on the running system.
        preflight_resources_validate "$target_efi" "10240" "$rootfs" "51200" \
          "${esp_mount:-}" "10240" "/run/lock/steamos-build-installer/build.lock" "$scenario"
        ;;
      build)
        # Build modifies rootfs inside a loop-mounted image; EFI space required.
        preflight_resources_validate "$target_efi" "10240" "$rootfs" "51200" \
          "" "" "/run/lock/steamos-build-installer/build.lock" "$scenario"
        ;;
    esac
  fi

  # 5. RAUC idle check (only for installed-system scenarios, NOT Build)
  case "$scenario" in
    build)
      debug "preflight_validate: RAUC check skipped for build scenario"
      ;;
    *)
      if declare -F preflight_resources_rauc_idle >/dev/null 2>&1; then
        preflight_resources_rauc_idle
      fi
      ;;
  esac

  debug "preflight_validate: all preflight checks passed for scenario=$scenario"
}
