#!/bin/bash
#
# steamos-build-installer — lib/preflight_bootconf.sh
# Boot configuration policy validation: ensures the bootconf state for a
# given slot is consistent with the intended operation before any
# destructive change begins.
#
# Validates three policy dimensions:
#   PF-57  Reset policy — create-only must not silently leave a stale config;
#          replace must not target the booted slot; update must find a
#          parseable existing config.
#   PF-58  Current-slot health — the booted slot's config must be parseable;
#          fatal for replace, update, preserve.
#   PF-59  Secure Boot compatibility — signing tool must exist when SB is on;
#          conditional on a SECURE_BOOT_POLICY parameter.
#
# Supported operation modes:
#   create-only  — target config must NOT exist; would leave existing unchanged
#   replace      — target must be inactive (not the booted slot)
#   update       — config must exist and be parseable; only allowlisted fields change
#   preserve     — config must exist and be parseable; no mutation planned
#
# Requires: lib/common.sh (die, debug, warn)
# Do not run it directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/preflight_bootconf.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _pf_bootconf_conf_path CONF_DIR SLOT
#   Get the path to the slot's configuration file within CONF_DIR.
#   Prints the full path (e.g. /esp/SteamOS/conf/B.conf).
#   Returns 0 on success, 1 on invalid slot.  Does NOT die.
_pf_bootconf_conf_path() {
  local conf_dir="$1"
  local slot="$2"

  case "$slot" in
    A | B) ;;
    *) return 1 ;;
  esac

  echo "${conf_dir}/${slot}.conf"
}

# _pf_bootconf_resolve_current_slot CONF_DIR EFI_MOUNT
#   Resolve the currently booted slot.
#   Uses steamos-bootconf this-image with --conf-dir and --efi-dir
#   to query the target rather than the running host.
#   Prints the slot label (A or B).
#   Returns 0 on success, 1 on failure.  Does NOT die.
_pf_bootconf_resolve_current_slot() {
  local conf_dir="$1"
  local efi_mount="$2"

  local slot
  slot="$(steamos-bootconf this-image --conf-dir "$conf_dir" --efi-dir "$efi_mount" 2>/dev/null)" \
    || return 1

  case "$slot" in
    A | B) ;;
    *) return 1 ;;
  esac

  echo "$slot"
}

# _pf_bootconf_is_parseable CONF_FILE
#   Check whether CONF_FILE exists and is a parseable bootconf config.
#   A file is considered parseable if it exists, is a regular file,
#   is non-empty, and contains at least one line with "key: value"
#   format (SteamOS bootconf format).
#   Returns 0 if parseable, 1 otherwise.  Does NOT die.
_pf_bootconf_is_parseable() {
  local conf_file="${1:?_pf_bootconf_is_parseable: missing config file path}"

  if [[ ! -f "$conf_file" ]]; then
    return 1
  fi

  if [[ ! -s "$conf_file" ]]; then
    return 1
  fi

  # SteamOS bootconf uses "key: value" format, not "key=value".
  if ! grep -qE '^[^#].+:[[:space:]].+' "$conf_file" 2>/dev/null; then
    return 1
  fi

  return 0
}

# _pf_bootconf_tool_validates CONF_DIR EFI_MOUNT SLOT
#   Full validation of a slot's bootconf config using steamos-bootconf.
#   Calls steamos-bootconf config --no-create --get title to verify the
#   tool can actually parse the config.
#   Returns 0 if the tool succeeds (config is valid), 1 otherwise.
#   Does NOT die.
_pf_bootconf_tool_validates() {
  local conf_dir="${1:?_pf_bootconf_tool_validates: missing conf directory}"
  local efi_mount="${2:?_pf_bootconf_tool_validates: missing EFI mount point}"
  local slot="${3:?_pf_bootconf_tool_validates: missing slot label}"

  case "$slot" in
    A | B) ;;
    *) return 1 ;;
  esac

  # Try to validate using steamos-bootconf.
  # The --no-create flag ensures we don't create a new config.
  # --get title verifies the tool can parse at least one field.
  if steamos-bootconf \
    --conf-dir "$conf_dir" \
    --efi-dir "$efi_mount" \
    --image "$slot" \
    config --no-create --get title &>/dev/null; then
    return 0
  fi

  return 1
}

# _pf_secure_boot_enabled
#   Check whether UEFI Secure Boot is currently active.
#   Uses mokutil --sb-state when available, falls back to reading the
#   efivar if present.
#   Prints one of: "enabled", "disabled", "indeterminate"
#   Never dies — callers decide severity.
_pf_secure_boot_enabled() {
  # Prefer mokutil when available.
  if command -v mokutil &>/dev/null; then
    local sb_state
    sb_state="$(mokutil --sb-state 2>/dev/null)" || sb_state=""

    case "$sb_state" in
      *enabled*)
        echo "enabled"
        return 0
        ;;
      *disabled* | *not*)
        echo "disabled"
        return 0
        ;;
    esac
  fi

  # Fallback: read the SecureBoot efivar directly.
  local efivar="/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  if [[ -r "$efivar" ]]; then
    # The last byte of the SecureBoot efivar is 1 when enabled, 0 when disabled.
    local sb_byte
    sb_byte="$(od -An -t u1 -j4 -N1 "$efivar" 2>/dev/null | tr -d ' ')" || sb_byte=""

    case "$sb_byte" in
      1)
        echo "enabled"
        return 0
        ;;
      0)
        echo "disabled"
        return 0
        ;;
    esac
  fi

  # Cannot determine Secure Boot state.
  echo "indeterminate"
  return 0
}

# _pf_signing_tool_available
#   Check whether a UEFI binary signing tool is available.
#   Looks for sbsign (from sbsigntools) and pesign.
#   Returns 0 if a signing tool is found, 1 otherwise.  Does NOT die.
_pf_signing_tool_available() {
  if command -v sbsign &>/dev/null; then
    return 0
  fi

  if command -v pesign &>/dev/null; then
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# Individual checks — independently callable
# ---------------------------------------------------------------------------

# preflight_bootconf_reset_policy CONF_DIR SLOT OPERATION_MODE [CURRENT_SLOT] [EFI_MOUNT] [SELECTED_SLOT]
#   PF-57: Enforce reset/creation policy constraints.
#
#   OPERATION_MODE must be one of:
#     "create-only"  — target config must NOT exist; leaves existing unchanged
#     "replace"      — target must be inactive (not the booted slot)
#     "update"       — config must exist and be parseable
#     "preserve"     — config must exist and be parseable (no mutation)
#
#   When mode is "create-only" and a config file already exists for SLOT,
#   warn that the existing config would be left unchanged.
#   When mode is "replace" and SLOT equals CURRENT_SLOT, die (cannot replace
#   the currently booted slot).
#   When mode is "replace" and SLOT equals SELECTED_SLOT, warn because
#   replacing the next-boot slot could cause a failed boot.
#   When mode is "update" or "preserve" and the config does not exist or is
#   not parseable, die (nothing to update/preserve).
#
#   CURRENT_SLOT is optional; when not provided and mode is "replace",
#   the check resolves it internally using EFI_MOUNT.
#   EFI_MOUNT is the mounted EFI partition (used with steamos-bootconf
#   to resolve the current slot when CURRENT_SLOT is empty).
#   SELECTED_SLOT is optional; when provided and mode is "replace" and
#   SLOT equals SELECTED_SLOT, a warning is emitted.
preflight_bootconf_reset_policy() {
  local conf_dir="${1:?preflight_bootconf_reset_policy: missing conf directory}"
  local slot="${2:?preflight_bootconf_reset_policy: missing slot label}"
  local mode="${3:?preflight_bootconf_reset_policy: missing operation mode}"
  local current_slot="${4:-}"
  local efi_mount="${5:-}"
  local selected_slot="${6:-}"

  case "$mode" in
    create-only | replace | update | preserve) ;;
    *) die "PF-57: invalid operation mode: '$mode' (expected create-only, replace, update, or preserve)" ;;
  esac

  local conf_file
  if ! conf_file="$(_pf_bootconf_conf_path "$conf_dir" "$slot")"; then
    die "PF-57: invalid slot label: $slot"
  fi

  case "$mode" in
    create-only)
      if [[ -f "$conf_file" ]]; then
        die "PF-57: create-only mode would leave the existing config unchanged for slot $slot ($conf_file exists) — use update or replace mode to modify it"
      fi
      debug "PF-57: no existing config for slot $slot — create-only is safe"
      ;;
    replace)
      # Replace must not target the booted slot.
      if [[ -z "$current_slot" ]]; then
        local resolved
        if ! resolved="$(_pf_bootconf_resolve_current_slot "$conf_dir" "$efi_mount")"; then
          # Issue #6: You cannot safely replace without knowing which slot is booted.
          die "PF-57: could not resolve current slot — cannot safely replace without knowing the booted slot"
        fi
        current_slot="$resolved"
      fi
      if [[ "$slot" == "$current_slot" ]]; then
        die "PF-57: replace mode cannot target the currently booted slot ($slot) — switch slots first"
      fi
      # Issue #2: Warn if replacing the selected/next-boot slot.
      if [[ -n "$selected_slot" && "$slot" == "$selected_slot" ]]; then
        warn "PF-57: replace mode is targeting the selected/next-boot slot ($slot) — this could cause a failed boot"
      fi
      debug "PF-57: replace mode for slot $slot — booted-slot check passed"
      ;;
    update | preserve)
      if [[ ! -f "$conf_file" ]]; then
        die "PF-57: $mode mode requires an existing config for slot $slot ($conf_file does not exist)"
      fi
      # Quick gate: file looks roughly like a bootconf config.
      if ! _pf_bootconf_is_parseable "$conf_file"; then
        die "PF-57: $mode mode requires a parseable config for slot $slot ($conf_file is not parseable)"
      fi
      # Full validation: verify steamos-bootconf can actually parse it.
      if [[ -n "$efi_mount" ]]; then
        if ! _pf_bootconf_tool_validates "$conf_dir" "$efi_mount" "$slot"; then
          die "PF-57: $mode mode — steamos-bootconf cannot parse the config for slot $slot"
        fi
      fi
      debug "PF-57: $mode mode for slot $slot — existing config is present and parseable"
      ;;
  esac
}

# preflight_bootconf_current_health CONF_DIR CURRENT_SLOT OPERATION_MODE SCENARIO [REPAIR_OVERRIDE] [EFI_MOUNT]
#   PF-58: Verify the currently booted slot's bootconfig is parseable.
#
#   A corrupt or missing current-slot config means the system is running
#   on potentially invalid state.  For mutating operations (replace, update)
#   and preservation this is fatal — we cannot safely proceed.  For non-mutating scenarios
#   (build, diagnostic) this is a warning.
#
#   REPAIR_OVERRIDE is optional; when set (non-empty), warn-on-failure behavior
#   applies even for mutating operations.  When not set, the current behavior
#   (die for replace/update/preserve) applies.
#
#   EFI_MOUNT is optional; when provided, steamos-bootconf tool validation
#   is used as a second-stage check after the quick grep gate.
#
#   SCENARIO is optional; when "build", the check is skipped entirely
#   (no booted slot exists in a build context).
preflight_bootconf_current_health() {
  local conf_dir="${1:?preflight_bootconf_current_health: missing conf directory}"
  local current_slot="${2:?preflight_bootconf_current_health: missing current slot}"
  local operation_mode="${3:-}"
  local scenario="${4:-}"
  local repair_override="${5:-}"
  local efi_mount="${6:-}"

  # In a build scenario there is no booted slot — skip entirely.
  if [[ "$scenario" == "build" ]]; then
    debug "PF-58: build scenario — no booted slot to check"
    return 0
  fi

  local conf_file
  if ! conf_file="$(_pf_bootconf_conf_path "$conf_dir" "$current_slot")"; then
    die "PF-58: invalid current slot label: $current_slot"
  fi

  local is_healthy=true
  local missing_msg=""

  # Stage 1: Quick gate — file existence and rough parseability.
  if [[ ! -f "$conf_file" ]]; then
    is_healthy=false
    missing_msg="current-slot ($current_slot) bootconf config is missing: $conf_file"
  elif ! _pf_bootconf_is_parseable "$conf_file"; then
    is_healthy=false
    missing_msg="current-slot ($current_slot) bootconf config is not parseable: $conf_file"
  fi

  # Stage 2: Full validation — steamos-bootconf can actually parse it.
  if [[ "$is_healthy" == true && -n "$efi_mount" ]]; then
    if ! _pf_bootconf_tool_validates "$conf_dir" "$efi_mount" "$current_slot"; then
      is_healthy=false
      missing_msg="current-slot ($current_slot) bootconf config failed steamos-bootconf validation: $conf_file"
    fi
  fi

  if [[ "$is_healthy" == true ]]; then
    debug "PF-58: current-slot ($current_slot) bootconf config is healthy: $conf_file"
    return 0
  fi

  # For mutating operations on or near the current slot, this is fatal
  # unless repair_override is active.
  case "$operation_mode" in
    replace | update | preserve)
      if [[ -n "$repair_override" ]]; then
        warn "PF-58: $missing_msg — repair override active, proceeding with caution for $operation_mode"
        return 0
      fi
      die "PF-58: $missing_msg — cannot proceed with $operation_mode"
      ;;
    *)
      warn "PF-58: $missing_msg — proceeding with caution"
      return 0
      ;;
  esac
}

# preflight_bootconf_secure_boot_compat SECURE_BOOT_POLICY
#   PF-59: Verify Secure Boot compatibility.
#
#   SECURE_BOOT_POLICY determines behavior:
#     "disabled"          — skip entirely (Secure Boot not relevant)
#     "unsupported"       — skip entirely (platform cannot do SB)
#     "signing-required"  — signing tool must be present; no fallback
#     "auto" (default)    — detect state and act accordingly
#
#   In "auto" mode (original behavior):
#     1. Secure Boot disabled  -> pass
#     2. Secure Boot enabled
#        a. signing tool available -> pass
#        b. signing tool missing   -> die
#     3. Secure Boot indeterminate -> warn and continue
preflight_bootconf_secure_boot_compat() {
  local sb_policy="${1:-auto}"

  case "$sb_policy" in
    disabled | unsupported)
      debug "PF-59: Secure Boot policy is '$sb_policy' — skipping check"
      return 0
      ;;
    signing-required)
      # Must have a working signing tool.  No graceful degradation.
      if ! _pf_signing_tool_available; then
        die "PF-59: Secure Boot signing is required but no signing tool found (sbsign/pesign)"
      fi
      debug "PF-59: Secure Boot signing required — tool available"
      return 0
      ;;
    auto)
      # Detect state and act accordingly (fall through).
      ;;
    *)
      die "PF-59: invalid secure boot policy: '$sb_policy'"
      ;;
  esac

  # Auto mode: detect actual Secure Boot state.
  local sb_state
  sb_state="$(_pf_secure_boot_enabled)"

  case "$sb_state" in
    disabled)
      debug "PF-59: Secure Boot is disabled — no signing tool required"
      return 0
      ;;
    enabled)
      if _pf_signing_tool_available; then
        debug "PF-59: Secure Boot is enabled and signing tool is available"
        return 0
      fi
      die "PF-59: Secure Boot is enabled but no signing tool found (sbsign/pesign) — cannot sign EFI binaries"
      ;;
    indeterminate)
      warn "PF-59: Secure Boot state is indeterminate (mokutil unavailable) — proceeding with caution"
      return 0
      ;;
    *)
      die "PF-59: unexpected Secure Boot state: '$sb_state'"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

# preflight_bootconf_validate ESP_MOUNT EFI_MOUNT SLOT OPERATION_MODE \
#                             [CURRENT_SLOT] [SCENARIO] [SECURE_BOOT_POLICY] \
#                             [SELECTED_SLOT] [REPAIR_OVERRIDE]
#   Run the full boot configuration policy validation sequence:
#     PF-57  Reset/creation policy enforced for the given operation mode
#     PF-58  Current-slot bootconf is healthy (parseable) when applicable
#     PF-59  Secure Boot compatibility (conditional on policy)
#
#   Required Args:
#     ESP_MOUNT       — mounted ESP partition (used to locate conf dir)
#     EFI_MOUNT       — mounted EFI partition (passed to steamos-bootconf)
#     SLOT            — target slot label (A or B)
#     OPERATION_MODE  — create-only, replace, update, or preserve
#
#   Optional Args:
#     CURRENT_SLOT    — pre-resolved booted slot (e.g. from RAUC cross-check).
#                       If empty, resolved via steamos-bootconf this-image
#                       with --conf-dir and --efi-dir.
#     SCENARIO        — build, flashless, recovery, live, or empty (agnostic).
#                       "build" skips PF-58 entirely (no booted slot).
#     SECURE_BOOT_POLICY — disabled, signing-required, unsupported, or auto.
#                          Defaults to "auto".
#     SELECTED_SLOT   — the selected/next-boot slot (A or B). When provided
#                        and mode is "replace" and SLOT equals SELECTED_SLOT,
#                        PF-57 emits a warning.
#     REPAIR_OVERRIDE — when set (non-empty), PF-58 warn-on-failure behavior
#                        applies even for mutating operations instead of dying.
#
#   The ESP_MOUNT is used to derive the bootconf conf directory at
#   $ESP_MOUNT/SteamOS/conf/ (the standard SteamOS layout).
#
#   Dies on the first fatal check failure; returns 0 when all checks pass.
preflight_bootconf_validate() {
  local esp_mount="${1:?preflight_bootconf_validate: missing ESP mount point}"
  local efi_mount="${2:?preflight_bootconf_validate: missing EFI mount point}"
  local slot="${3:?preflight_bootconf_validate: missing slot label}"
  local mode="${4:?preflight_bootconf_validate: missing operation mode}"
  local current_slot="${5:-}"
  local scenario="${6:-}"
  local sb_policy="${7:-auto}"
  local selected_slot="${8:-}"
  local repair_override="${9:-}"

  local conf_dir="$esp_mount/SteamOS/conf"

  debug "preflight_bootconf_validate: esp=$esp_mount efi=$efi_mount slot=$slot mode=$mode conf_dir=$conf_dir scenario=$scenario sb_policy=$sb_policy selected_slot=$selected_slot repair_override=$repair_override"

  # --- Validate slot label ---
  case "$slot" in
    A | B) ;;
    *) die "PF-57: invalid slot label: $slot" ;;
  esac

  # --- Validate operation mode ---
  case "$mode" in
    create-only | replace | update | preserve) ;;
    *) die "PF-57: invalid operation mode: '$mode'" ;;
  esac

  # --- Validate scenario (if provided) ---
  case "$scenario" in
    "" | build | flashless | recovery | live) ;;
    *) die "preflight_bootconf_validate: invalid scenario: '$scenario'" ;;
  esac

  # --- Validate secure boot policy (if provided) ---
  case "$sb_policy" in
    disabled | signing-required | unsupported | auto) ;;
    *) die "preflight_bootconf_validate: invalid secure boot policy: '$sb_policy'" ;;
  esac

  # --- Resolve conf directory ---
  if [[ ! -d "$conf_dir" ]]; then
    case "$mode" in
      create-only | replace)
        debug "preflight_bootconf_validate: conf directory $conf_dir does not exist — will be created by operation"
        ;;
      *)
        die "PF-57: bootconf conf directory does not exist: $conf_dir"
        ;;
    esac
  fi

  # --- Resolve current slot (if not provided) ---
  if [[ -z "$current_slot" && "$scenario" != "build" ]]; then
    if ! current_slot="$(_pf_bootconf_resolve_current_slot "$conf_dir" "$efi_mount")"; then
      # Issue #5: For live/flashless/recovery scenarios, failing to resolve
      # the current slot is fatal — we cannot safely proceed without it.
      case "$scenario" in
        flashless | recovery | live)
          die "preflight_bootconf_validate: could not resolve current booted slot in '$scenario' scenario — cannot proceed"
          ;;
        *)
          warn "preflight_bootconf_validate: could not resolve current booted slot — PF-58 and PF-57 replace check may be incomplete"
          ;;
      esac
    fi
  fi

  # --- PF-57: Reset/creation policy ---
  preflight_bootconf_reset_policy "$conf_dir" "$slot" "$mode" "$current_slot" "$efi_mount" "$selected_slot"

  # --- PF-58: Current-slot health ---
  # Only check when the conf directory exists (we cannot check a missing dir).
  if [[ -d "$conf_dir" && -n "$current_slot" ]]; then
    preflight_bootconf_current_health "$conf_dir" "$current_slot" "$mode" "$scenario" "$repair_override" "$efi_mount"
  elif [[ "$scenario" != "build" && -z "$current_slot" ]]; then
    warn "PF-58: current slot could not be resolved — skipping health check"
  fi

  # --- PF-59: Secure Boot compatibility ---
  preflight_bootconf_secure_boot_compat "$sb_policy"

  debug "preflight_bootconf_validate: all bootconf policy checks passed (slot=$slot mode=$mode)"
}
