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
  # shellcheck disable=SC2317 # 'return' or 'exit' here is the intended early-exit
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
# shellcheck source=preflight_command_probe.sh
source_module "${_PF_LOADER_DIR}/preflight_command_probe.sh" || die "FATAL: failed to load preflight_command_probe.sh"
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
  local esp_mount="${3:-}"
  local slot="${4:?_preflight_build: missing SLOT_LABEL}"
  local image_path="${5:-}"
  local expected_hash="${6:-}"

  log "preflight: build rootfs=$rootfs efi=$target_efi esp=$esp_mount slot=$slot image=${image_path:-<none>}"

  debug "_preflight_build: rootfs=$rootfs efi=$target_efi esp=$esp_mount slot=$slot"

  # --- Resolve device paths from environment ---
  local _pf_loop_dev="${LOOP_DEV:-}"
  local _pf_rootfs_dev="${ROOTFS_DEV:-}"
  local _pf_efi_dev="${EFI_DEV:-}"

  # --- Scenario checks (require resolved devices, not mounts) ---
  if [[ -n "$_pf_loop_dev" && -n "$_pf_rootfs_dev" && -n "$_pf_efi_dev" ]]; then
    preflight_scenario_validate_build "$_pf_loop_dev" "$_pf_rootfs_dev" "$_pf_efi_dev"
  else
    debug "_preflight_build: LOOP_DEV/ROOTFS_DEV/EFI_DEV not fully resolved — skipping scenario-level checks"
  fi

  # --- EFI checks: gate on efi mount + device resolution ---
  if [[ -n "${_pf_mounts[efi]:-}" && -n "$_pf_efi_dev" ]]; then
    preflight_efi_validate_existing "$target_efi" "$_pf_efi_dev" "$slot"
  else
    debug "_preflight_build: EFI not mounted or device not resolved — skipping EFI checks"
  fi

  # --- Path safety: gate on efi mount ---
  if [[ -n "${_pf_mounts[efi]:-}" ]]; then
    preflight_path_safety_validate "$target_efi"
  else
    debug "_preflight_build: EFI not mounted — skipping path safety"
  fi

  # --- Rootfs checks: gate on rootfs mount ---
  if [[ -n "${_pf_mounts[rootfs]:-}" ]]; then
    preflight_rootfs_validate "$rootfs"
    preflight_generation_validate "$rootfs" "" "" \
      "true" "true" "true" "true"
    preflight_command_availability_validate "$rootfs"
    preflight_filesystem_state_validate "$rootfs" "" "$image_path" "$expected_hash" \
      "false"
  else
    debug "_preflight_build: rootfs not mounted — skipping rootfs checks"
  fi

  # --- System identity: needs rootfs; EFI optional for partset_map ---
  if [[ -n "${_pf_mounts[rootfs]:-}" ]]; then
    preflight_system_identity_validate "$rootfs" "${target_efi:-}"
  else
    debug "_preflight_build: rootfs not mounted — skipping system identity"
  fi

  # --- Chroot mount: needs rootfs + EFI device ---
  if [[ -n "${_pf_mounts[rootfs]:-}" && -n "$_pf_rootfs_dev" && -n "$_pf_efi_dev" ]]; then
    preflight_chroot_mount_validate "$rootfs" "$_pf_rootfs_dev" "$_pf_efi_dev"
  else
    debug "_preflight_build: rootfs/efi device not resolved — skipping chroot mount validation"
  fi

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
  local target_efi="${2:-}"
  local esp_mount="${3:-}"
  local slot="${4:?_preflight_recovery: missing SLOT_LABEL}"
  local source_efi="${5:-}"
  local expected_variant="${6:-}"

  log "preflight: recovery rootfs=$rootfs efi=$target_efi esp=$esp_mount slot=$slot variant=${expected_variant:-<none>}"

  debug "_preflight_recovery: rootfs=$rootfs efi=$target_efi esp=$esp_mount slot=$slot"

  # --- Resolve devices for the topology descriptor ---
  local rootfs_dev="" rootfs_partuuid="" efi_dev="" efi_partuuid=""
  local var_dev="" var_partuuid="" verity_dev="" verity_policy=""
  local shared_esp_dev="" shared_esp_partuuid=""

  # Resolve rootfs device from the mounted rootfs mount point.
  rootfs_dev="$(findmnt -nro SOURCE "$rootfs" 2>/dev/null | head -1)" || rootfs_dev=""
  if [[ -n "$rootfs_dev" ]]; then
    rootfs_dev="$(readlink -f "$rootfs_dev" 2>/dev/null)" || true
    rootfs_partuuid="$(blkid -s PARTUUID -o value "$rootfs_dev" 2>/dev/null)" || rootfs_partuuid=""
  fi

  # Resolve EFI device from the mounted EFI mount point.
  efi_dev="$(findmnt -nro SOURCE "$target_efi" 2>/dev/null | head -1)" || efi_dev=""
  if [[ -n "$efi_dev" ]]; then
    efi_dev="$(readlink -f "$efi_dev" 2>/dev/null)" || true
    efi_partuuid="$(blkid -s PARTUUID -o value "$efi_dev" 2>/dev/null)" || efi_partuuid=""
  fi

  # Resolve var device — try by-partsets first, then fall back to rootfs sibling.
  if [[ -d "/dev/disk/by-partsets/$slot" ]]; then
    var_dev="$(readlink -f "/dev/disk/by-partsets/$slot/var" 2>/dev/null)" || var_dev=""
  fi
  if [[ -z "$var_dev" && -n "$rootfs_dev" ]]; then
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
    shared_esp_dev="$(readlink -f "$shared_esp_dev" 2>/dev/null)" || true
    shared_esp_partuuid="$(blkid -s PARTUUID -o value "$shared_esp_dev" 2>/dev/null)" || shared_esp_partuuid=""
  fi

  verity_dev=""
  verity_policy=""

  # --- Scenario checks: gate on rootfs + efi (PF-35 needs both) ---
  if [[ -n "${_pf_mounts[rootfs]:-}" && -n "${_pf_mounts[efi]:-}" ]]; then
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
    preflight_scenario_validate_recovery "${topology_descriptor[@]}"
  else
    debug "_preflight_recovery: rootfs or EFI not mounted — skipping scenario validation"
  fi

  # --- EFI checks: gate on efi mount + device ---
  if [[ -n "${_pf_mounts[efi]:-}" && -n "$efi_dev" && -b "$efi_dev" ]]; then
    preflight_efi_validate_existing "$target_efi" "$efi_dev" "$slot"
  else
    debug "_preflight_recovery: EFI not mounted or device not resolved — skipping EFI checks"
  fi

  # --- ESP checks: gate on esp mount + device ---
  if [[ -n "${_pf_mounts[esp]:-}" && -n "$shared_esp_dev" && -b "$shared_esp_dev" ]]; then
    if [[ -n "$shared_esp_partuuid" ]]; then
      preflight_esp_validate "$esp_mount" "$shared_esp_dev" "${efi_dev:-}" "$shared_esp_partuuid"
    else
      debug "_preflight_recovery: ESP PARTUUID unavailable — skipping ESP validation"
    fi
  else
    debug "_preflight_recovery: ESP not mounted or device not resolved — skipping ESP checks"
  fi

  # --- Path safety: gate on efi mount (esp optional) ---
  if [[ -n "${_pf_mounts[efi]:-}" ]]; then
    preflight_path_safety_validate "$target_efi" "${esp_mount:-}"
  else
    debug "_preflight_recovery: EFI not mounted — skipping path safety"
  fi

  # --- Rootfs checks: gate on rootfs mount ---
  if [[ -n "${_pf_mounts[rootfs]:-}" ]]; then
    preflight_rootfs_validate "$rootfs" "" "$rootfs_dev" "$rootfs_partuuid"
  else
    debug "_preflight_recovery: rootfs not mounted — skipping rootfs checks"
  fi

  # --- System identity: gate on rootfs mount ---
  if [[ -n "${_pf_mounts[rootfs]:-}" ]]; then
    preflight_system_identity_validate "$rootfs" "${target_efi:-}" "$expected_variant"
  else
    debug "_preflight_recovery: rootfs not mounted — skipping system identity"
  fi

  # --- Chroot mount: gate on rootfs + efi device ---
  if [[ -n "${_pf_mounts[rootfs]:-}" && -n "$rootfs_dev" && -n "$efi_dev" ]]; then
    preflight_chroot_mount_validate "$rootfs" "$rootfs_dev" "$efi_dev" "${shared_esp_dev:-}"
  else
    debug "_preflight_recovery: rootfs/efi device not resolved — skipping chroot mount validation"
  fi

  # --- Generation: gate on rootfs mount ---
  if [[ -n "${_pf_mounts[rootfs]:-}" ]]; then
    preflight_generation_validate "$rootfs" "$source_efi" "" \
      "true" "true" "true" "true"
  else
    debug "_preflight_recovery: rootfs not mounted — skipping generation checks"
  fi

  # --- Command availability: gate on rootfs mount ---
  if [[ -n "${_pf_mounts[rootfs]:-}" ]]; then
    preflight_command_availability_validate "$rootfs"
  else
    debug "_preflight_recovery: rootfs not mounted — skipping command availability"
  fi

  # --- Bootconf: gate on esp + efi mount ---
  if [[ -n "${_pf_mounts[esp]:-}" && -n "${_pf_mounts[efi]:-}" ]]; then
    local esp_conf_dir=""
    if [[ -d "$esp_mount/SteamOS/conf" ]]; then
      esp_conf_dir="$esp_mount"
    fi
    if [[ -n "$esp_conf_dir" ]]; then
      preflight_bootconf_validate "$esp_conf_dir" "$target_efi" "$slot" "replace"
    else
      debug "_preflight_recovery: bootconf conf dir missing — skipping bootconf validation"
    fi
  else
    debug "_preflight_recovery: ESP or EFI not mounted — skipping bootconf validation"
  fi

  # --- Filesystem state: gate on rootfs mount ---
  if [[ -n "${_pf_mounts[rootfs]:-}" ]]; then
    preflight_filesystem_state_validate "$rootfs" "$rootfs_dev" "" "" \
      "true" "$rootfs_dev" "" ""
  else
    debug "_preflight_recovery: rootfs not mounted — skipping filesystem state"
  fi

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
  local target_efi="${2:-}"
  local esp_mount="${3:-}"
  local slot="${4:?_preflight_flashless: missing SLOT_LABEL}"
  local source_efi="${5:-}"
  local expected_variant="${6:-}"
  local expected_esp_partuuid="${7:-}"
  local image_path="${8:-}"
  local expected_hash="${9:-}"
  local source_uuid="${10:-}"
  local expected_uuid="${11:-}"

  log "preflight: flashless rootfs=$rootfs efi=$target_efi esp=$esp_mount slot=$slot variant=${expected_variant:-<none>}"

  # --- Source image integrity (PF-64): no mount needed ---
  if [[ -n "$image_path" && -n "$expected_hash" ]]; then
    pf_fs_check_source_integrity "$image_path" "$expected_hash"
  fi

  debug "_preflight_flashless: rootfs=$rootfs efi=$target_efi esp=$esp_mount slot=$slot source_uuid=${source_uuid:-<none>} expected_uuid=${expected_uuid:-<none>}"

  # --- Scenario checks: no mount needed (CLI + block device queries) ---
  preflight_scenario_validate_flashless

  # --- EFI checks: gate on efi mount + device resolution ---
  local efi_dev=""
  if [[ -e "/dev/disk/by-partsets/$slot/efi" ]]; then
    efi_dev="$(readlink -f "/dev/disk/by-partsets/$slot/efi" 2>/dev/null)" || efi_dev=""
  fi
  if [[ -n "${_pf_mounts[efi]:-}" && -n "$efi_dev" ]]; then
    preflight_efi_validate_temporary "$efi_dev" "$target_efi" "$slot"
  else
    debug "_preflight_flashless: EFI not mounted or device not resolved — skipping EFI checks"
  fi

  # --- ESP checks: gate on esp mount + device ---
  local esp_dev=""
  if [[ -n "$esp_mount" && -d "$esp_mount" ]]; then
    esp_dev="$(findmnt -nro SOURCE "$esp_mount" 2>/dev/null | head -1)" || esp_dev=""
  fi
  if [[ -n "${_pf_mounts[esp]:-}" && -n "$esp_dev" && -n "$efi_dev" ]]; then
    if [[ -n "$expected_esp_partuuid" ]]; then
      preflight_esp_validate "$esp_mount" "$esp_dev" "$efi_dev" "$expected_esp_partuuid"
    else
      debug "_preflight_flashless: no expected ESP PARTUUID — skipping ESP PARTUUID check"
      preflight_esp_distinct_from_efi "$esp_dev" "$efi_dev"
      preflight_esp_is_fat_and_writable "$esp_mount" "$esp_dev"
    fi
  else
    debug "_preflight_flashless: ESP not mounted or device not resolved — skipping ESP checks"
  fi

  # --- Path safety: gate on efi mount ---
  if [[ -n "${_pf_mounts[efi]:-}" ]]; then
    preflight_path_safety_validate "$target_efi" "${esp_mount:-}"
  else
    debug "_preflight_flashless: EFI not mounted — skipping path safety"
  fi

  # --- Rootfs checks: gate on rootfs mount ---
  local rootfs_device=""
  local rootfs_partuuid=""
  if [[ -n "${_pf_mounts[rootfs]:-}" ]]; then
    preflight_rootfs_validate "$rootfs" "${source_uuid:-}"
    rootfs_device="${_PF_RFS_ID_SOURCE:-}"
    rootfs_partuuid="${_PF_RFS_ID_PARTUUID:-}"
  else
    debug "_preflight_flashless: rootfs not mounted — skipping rootfs checks"
  fi

  # --- Chroot mount: gate on rootfs + efi device ---
  if [[ -n "${_pf_mounts[rootfs]:-}" && -n "$rootfs_device" && -n "$efi_dev" ]]; then
    preflight_chroot_mount_validate "$rootfs" "$rootfs_device" "$efi_dev" "${esp_dev:-}"
  else
    debug "_preflight_flashless: rootfs/efi device not resolved — skipping chroot mount validation"
  fi

  # --- Generation: gate on rootfs mount ---
  if [[ -n "${_pf_mounts[rootfs]:-}" ]]; then
    preflight_generation_validate "$rootfs" "$source_efi" "$expected_uuid" \
      "true" "true" "true" "true"
  else
    debug "_preflight_flashless: rootfs not mounted — skipping generation checks"
  fi

  # --- System identity: gate on rootfs mount ---
  if [[ -n "${_pf_mounts[rootfs]:-}" ]]; then
    preflight_system_identity_validate "$rootfs" "${target_efi:-}" "$expected_variant"
  else
    debug "_preflight_flashless: rootfs not mounted — skipping system identity"
  fi

  # --- Command availability: gate on rootfs mount ---
  if [[ -n "${_pf_mounts[rootfs]:-}" ]]; then
    preflight_command_availability_validate "$rootfs"
  else
    debug "_preflight_flashless: rootfs not mounted — skipping command availability"
  fi

  # --- Bootconf: gate on esp + efi mount ---
  if [[ -n "${_pf_mounts[esp]:-}" && -n "${_pf_mounts[efi]:-}" ]]; then
    local esp_conf_dir=""
    if [[ -d "$esp_mount/SteamOS/conf" ]]; then
      esp_conf_dir="$esp_mount"
    fi
    if [[ -n "$esp_conf_dir" ]]; then
      preflight_bootconf_validate "$esp_conf_dir" "$target_efi" "$slot" "replace"
    else
      debug "_preflight_flashless: no bootconf conf dir — will be created during generation"
    fi
  else
    debug "_preflight_flashless: ESP or EFI not mounted — skipping bootconf validation"
  fi

  # --- Filesystem state: gate on rootfs mount ---
  if [[ -n "${_pf_mounts[rootfs]:-}" ]]; then
    preflight_filesystem_state_validate "$rootfs" "" "" "" \
      "true" "$rootfs_device" "" ""
  else
    debug "_preflight_flashless: rootfs not mounted — skipping filesystem state"
  fi

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

  log "preflight: live rootfs=$rootfs efi=$target_efi esp=${esp_mount:-<none>} slot=${slot:-<auto>} variant=${expected_variant:-<none>}"

  debug "_preflight_live: rootfs=$rootfs efi=$target_efi esp=${esp_mount:-<none>} slot=${slot:-<auto>}"

  # --- Scenario checks: gate on rootfs + efi + esp (PF-36 needs all three) ---
  if [[ -n "${_pf_mounts[rootfs]:-}" && -n "${_pf_mounts[efi]:-}" && -n "${_pf_mounts[esp]:-}" ]]; then
    preflight_scenario_validate_live
  else
    debug "_preflight_live: rootfs, EFI, or ESP not mounted — skipping scenario validation"
  fi

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

  # --- EFI checks: gate on efi mount + device resolution ---
  local efi_dev=""
  if [[ -n "$slot" && -e "/dev/disk/by-partsets/$slot/efi" ]]; then
    efi_dev="$(readlink -f "/dev/disk/by-partsets/$slot/efi" 2>/dev/null)" || efi_dev=""
  fi
  if [[ -n "${_pf_mounts[efi]:-}" && -n "$efi_dev" ]]; then
    preflight_efi_validate_existing "$target_efi" "$efi_dev" "$slot"
  else
    debug "_preflight_live: EFI not mounted or device not resolved — skipping EFI checks"
  fi

  # --- ESP checks: gate on esp mount + device ---
  local esp_dev=""
  if [[ -n "$esp_mount" && -d "$esp_mount" ]]; then
    esp_dev="$(findmnt -nro SOURCE "$esp_mount" 2>/dev/null | head -1)" || esp_dev=""
  fi
  if [[ -n "${_pf_mounts[esp]:-}" && -n "$esp_dev" ]]; then
    if [[ -n "$expected_esp_partuuid" ]]; then
      preflight_esp_validate "$esp_mount" "$esp_dev" "$efi_dev" "$expected_esp_partuuid"
    else
      debug "_preflight_live: no expected ESP PARTUUID — skipping PF-37 (PARTUUID check)"
      preflight_esp_distinct_from_efi "$esp_dev" "${efi_dev:-}"
      preflight_esp_is_fat_and_writable "$esp_mount" "$esp_dev"
    fi
  else
    debug "_preflight_live: ESP not mounted or device not resolved — skipping ESP checks"
  fi

  # --- Rootfs checks: gate on rootfs mount ---
  if [[ -n "${_pf_mounts[rootfs]:-}" ]]; then
    preflight_rootfs_validate "$rootfs"
  else
    debug "_preflight_live: rootfs not mounted — skipping rootfs checks"
  fi

  # --- System identity: gate on rootfs mount ---
  if [[ -n "${_pf_mounts[rootfs]:-}" ]]; then
    preflight_system_identity_validate "$rootfs" "${target_efi:-}" "$expected_variant"
  else
    debug "_preflight_live: rootfs not mounted — skipping system identity"
  fi

  # --- Generation: gate on rootfs mount (all flags false — patch-only) ---
  if [[ -n "${_pf_mounts[rootfs]:-}" ]]; then
    preflight_generation_validate "$rootfs" "" "" \
      "false" "false" "false" "false"
  else
    debug "_preflight_live: rootfs not mounted — skipping generation checks"
  fi

  # --- Command availability: gate on rootfs mount ---
  if [[ -n "${_pf_mounts[rootfs]:-}" ]]; then
    preflight_command_availability_validate "$rootfs"
  else
    debug "_preflight_live: rootfs not mounted — skipping command availability"
  fi

  # --- Bootconf: gate on esp + efi mount ---
  local esp_conf_dir=""
  if [[ -n "${_pf_mounts[esp]:-}" && -n "$esp_mount" && -d "$esp_mount/SteamOS/conf" ]]; then
    esp_conf_dir="$esp_mount"
  fi
  if [[ -n "$esp_conf_dir" && -n "$slot" ]]; then
    preflight_bootconf_validate "$esp_conf_dir" "$target_efi" "$slot" "update"
  else
    debug "_preflight_live: ESP or EFI not mounted, or bootconf dir missing — skipping bootconf validation"
  fi

  # --- Path safety: gate on efi mount ---
  if [[ -n "${_pf_mounts[efi]:-}" ]]; then
    preflight_path_safety_validate "$target_efi" "${esp_mount:-}"
  else
    debug "_preflight_live: EFI not mounted — skipping path safety"
  fi

  # --- Filesystem state: gate on rootfs mount ---
  if [[ -n "${_pf_mounts[rootfs]:-}" ]]; then
    preflight_filesystem_state_validate "$rootfs" "" "" "" \
      "false"
  else
    debug "_preflight_live: rootfs not mounted — skipping filesystem state"
  fi

  debug "_preflight_live: all live preflights passed"
}

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

# _pf_check_mount KEY PATH
#   Probe whether PATH is a real mountpoint and record the result.
#   Used by preflight_validate() to build the _pf_mounts table that
#   scenario orchestrators consult before calling module-level checks.
_pf_check_mount() {
  local key="${1:?_pf_check_mount: missing key}"
  local path="${2:-}"

  if [[ -n "$path" && -d "$path" ]] && mountpoint -q "$path" 2>/dev/null; then
    _pf_mounts["$key"]=1
  fi
}

# preflight_validate --scenario <name> --rootfs <path> --slot <A|B>
#                    [--efi <path>] [--esp <path>]
#                    [--source-efi <path>] [--variant <name>]
#                    [--image <path>] [--hash <sha256>]
#                    [--esp-partuuid <uuid>] [--source-uuid <uuid>]
#                    [--expected-uuid <uuid>]
#
#   Required flags:
#     --scenario   build|recovery|flashless|live
#     --rootfs     path to the mounted rootfs
#     --slot       target slot label (A or B; build requires A only)
#
#   Optional flags:
#     --efi        mount point for the per-slot EFI partition
#     --esp        mount point for the shared ESP (may be empty for Build)
#     --source-efi path to source EFI directory (Build, Flashless)
#     --variant    expected SteamOS variant (all scenarios)
#     --image      path to source image file (Build, Flashless)
#     --hash       expected SHA256 hash of source image (Build, Flashless)
#     --esp-partuuid  expected ESP PARTUUID from target topology (Recovery, Flashless, Live)
#     --source-uuid   current rootfs UUID (Flashless — for UUID mutation preflight)
#     --expected-uuid target rootfs UUID after flash (Flashless — for generation preflight)
#
#   Dies on first failure.  Returns 0 when all checks pass.
preflight_validate() {
  local scenario=""
  local rootfs=""
  local target_efi=""
  local esp_mount=""
  local slot=""
  local source_efi=""
  local expected_variant=""
  local image_path=""
  local expected_hash=""
  local expected_esp_partuuid=""
  local source_uuid=""
  local expected_uuid=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --scenario)
        scenario="${2:?preflight_validate: --scenario requires a value}"
        shift 2
        ;;
      --rootfs)
        rootfs="${2:?preflight_validate: --rootfs requires a value}"
        shift 2
        ;;
      --efi)
        target_efi="${2:-}"
        shift 2
        ;;
      --esp)
        esp_mount="${2:-}"
        shift 2
        ;;
      --slot)
        slot="${2:?preflight_validate: --slot requires a value}"
        shift 2
        ;;
      --source-efi)
        source_efi="${2:-}"
        shift 2
        ;;
      --variant)
        expected_variant="${2:-}"
        shift 2
        ;;
      --image)
        image_path="${2:-}"
        shift 2
        ;;
      --hash)
        expected_hash="${2:-}"
        shift 2
        ;;
      --esp-partuuid)
        expected_esp_partuuid="${2:-}"
        shift 2
        ;;
      --source-uuid)
        source_uuid="${2:-}"
        shift 2
        ;;
      --expected-uuid)
        expected_uuid="${2:-}"
        shift 2
        ;;
      --)
        shift
        break
        ;;
      -*) die "preflight_validate: unknown option: $1" ;;
      *) die "preflight_validate: unexpected argument: $1 (use --flag value)" ;;
    esac
  done

  # --- Required arg validation ---
  [[ -n "$scenario" ]] || die "preflight_validate: --scenario is required (build, recovery, flashless, live)"
  [[ -n "$rootfs" ]] || die "preflight_validate: --rootfs is required"
  [[ -n "$slot" ]] || die "preflight_validate: --slot is required (A or B)"

  # --- Detect which filesystems are available (mounted) ---
  local -A _pf_mounts=()
  _pf_check_mount "rootfs" "$rootfs"
  _pf_check_mount "efi" "$target_efi"
  _pf_check_mount "esp" "$esp_mount"

  debug "preflight_validate: scenario=$scenario rootfs=$rootfs efi=$target_efi esp=$esp_mount slot=$slot"
  debug "preflight_validate: mounts={rootfs=${_pf_mounts[rootfs]:-0} efi=${_pf_mounts[efi]:-0} esp=${_pf_mounts[esp]:-0}}"

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

  # --- Dispatch to scenario-specific orchestrator ---
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
  if declare -F preflight_resources_validate >/dev/null 2>&1; then
    case "$scenario" in
      recovery)
        preflight_resources_validate "$target_efi" "10240" "$rootfs" "51200" \
          "${esp_mount:-}" "10240" "/run/lock/steamos-build-installer/build.lock" "$scenario"
        ;;
      flashless)
        preflight_resources_validate "$target_efi" "10240" "$rootfs" "51200" \
          "${esp_mount:-}" "10240" "/run/lock/steamos-build-installer/build.lock" "$scenario"
        ;;
      live)
        preflight_resources_validate "$target_efi" "10240" "$rootfs" "51200" \
          "${esp_mount:-}" "10240" "/run/lock/steamos-build-installer/build.lock" "$scenario"
        ;;
      build)
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
