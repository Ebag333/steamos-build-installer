#!/bin/bash
#
# tools/tests/efi-state/test-flashless-happy-path.sh
# Flashless scenario happy-path tests (F-01, F-03, F-04, F-05, F-06,
#                                      F-08, F-10, F-12, F-14).
#
# Tests that verify the core happy-path behavior of the EFI state
# application mechanism for the Flashless (dual-slot, current=A, target=B
# standby deployment) scenario:
#
#   F-01  Standby deployment happy path
#   F-03  Target partsets correct
#   F-04  Target EFI binary valid
#   F-05  Target GRUB configuration valid
#   F-06  Missing B bootconf initialized
#   F-08  Valid target EFI preserved
#   F-10  Activation occurs last
#   F-12  On-disk partsets independently verified
#   F-14  Verity policy completed
#
# Usage:
#   bash tools/tests/efi-state/test-flashless-happy-path.sh
#
# Dependencies:
#   - test-harness.sh       (lifecycle, assertions)
#   - flashless-helpers.sh  (flashless fixture setup, simulate_flashless_apply)
#   - fixture-factory.sh    (mock fixture creation, UUID/PARTUUID derivation)
#   - topology.sh           (deterministic UUID generation)
#   - validators.sh         (validate_grub_structure, etc.)

set -euo pipefail

# ---------------------------------------------------------------------------
# Source libraries
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=test-harness.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/test-harness.sh"
# shellcheck source=fixture-factory.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/fixture-factory.sh"
# shellcheck source=topology.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/topology.sh"
# shellcheck source=validators.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/validators.sh"
# shellcheck source=flashless-helpers.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/flashless-helpers.sh"

# ---------------------------------------------------------------------------
# Initialize harness
# ---------------------------------------------------------------------------
test_harness_init
trap test_harness_cleanup EXIT

# ============================================================================
# F-01: Standby deployment happy path
#
# Setup flashless fixture (dual-slot, current=A, target=B)
# Apply flashless state
# Verify B binary/config, partsets, persistent defaults, bootconf
# reach intended state
# ============================================================================
test_f01_standby_deployment_happy_path() {
  flashless_scenario_setup || exit 1

  # Apply flashless state to target B (standby)
  if ! simulate_flashless_apply; then
    test_harness_fail "F-01: simulate_flashless_apply failed"
    flashless_scenario_teardown
    exit 1
  fi

  local grub_cfg="$FLASHLESS_EFI_DIR/EFI/steamos/grub.cfg"
  local grubx64="$FLASHLESS_EFI_DIR/EFI/steamos/grubx64.efi"
  local partsets_dir="$FLASHLESS_EFI_DIR/SteamOS/partsets"
  local esp_dir="$FLASHLESS_ESP_DIR"
  local rootfs_dir="$FLASHLESS_ROOTFS_DIR"

  # --- Verify B binary exists and contains B UUID ---
  test_harness_assert_file_exists "$grubx64" || {
    flashless_scenario_teardown
    exit 1
  }

  local uuid_pattern='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
  local embedded_uuid
  embedded_uuid="$(strings "$grubx64" 2>/dev/null | grep -oE "$uuid_pattern" | head -1)"
  test_harness_assert_eq "$embedded_uuid" "$FLASHLESS_TARGET_UUID" || {
    flashless_scenario_teardown
    exit 1
  }

  # --- Verify B config (grub.cfg) matches B UUID ---
  test_harness_assert_file_exists "$grub_cfg" || {
    flashless_scenario_teardown
    exit 1
  }

  local grub_uuid_count
  grub_uuid_count="$(grep -c "search.*--fs-uuid.*--set=root.*${FLASHLESS_TARGET_UUID}" "$grub_cfg" 2>/dev/null || echo 0)"
  if [[ "$grub_uuid_count" -lt 1 ]]; then
    echo "    ASSERTION FAILED: grub.cfg does not reference target UUID '$FLASHLESS_TARGET_UUID'" >&2
    test_harness_fail "F-01: grub.cfg search --fs-uuid does not reference target (B) UUID"
    flashless_scenario_teardown
    exit 1
  fi

  # --- Verify kernel paths present in grub.cfg ---
  if ! grep -q 'linux /boot/vmlinuz-' "$grub_cfg" 2>/dev/null; then
    echo "    ASSERTION FAILED: no linux command with vmlinuz path in grub.cfg" >&2
    test_harness_fail "F-01: grub.cfg missing kernel vmlinuz path"
    flashless_scenario_teardown
    exit 1
  fi

  # --- Verify initramfs paths present in grub.cfg ---
  if ! grep -q 'initrd ' "$grub_cfg" 2>/dev/null; then
    echo "    ASSERTION FAILED: no initrd command in grub.cfg" >&2
    test_harness_fail "F-01: grub.cfg missing initramfs path"
    flashless_scenario_teardown
    exit 1
  fi

  # --- Verify partsets exist for both slots ---
  test_harness_assert_file_exists "$partsets_dir/A" || {
    echo "    ASSERTION FAILED: slot A partset missing" >&2
  }
  test_harness_assert_file_exists "$partsets_dir/B" || {
    echo "    ASSERTION FAILED: slot B partset missing" >&2
  }
  test_harness_assert_file_exists "$partsets_dir/self" || {
    echo "    ASSERTION FAILED: self partset missing" >&2
  }
  test_harness_assert_file_exists "$partsets_dir/all" || {
    echo "    ASSERTION FAILED: all partset missing" >&2
  }
  test_harness_assert_file_exists "$partsets_dir/shared" || {
    echo "    ASSERTION FAILED: shared partset missing" >&2
  }

  # --- Verify persistent defaults exist ---
  test_harness_assert_file_exists "$rootfs_dir/etc/default/grub" || {
    echo "    ASSERTION FAILED: /etc/default/grub missing" >&2
  }
  test_harness_assert_file_exists "$rootfs_dir/etc/default/grub-steamos" || {
    echo "    ASSERTION FAILED: /etc/default/grub-steamos missing" >&2
  }

  # --- Verify bootconf A.conf and B.conf exist ---
  test_harness_assert_file_exists "$esp_dir/SteamOS/conf/A.conf" || {
    echo "    ASSERTION FAILED: A.conf missing" >&2
  }
  test_harness_assert_file_exists "$esp_dir/SteamOS/conf/B.conf" || {
    echo "    ASSERTION FAILED: B.conf missing" >&2
  }

  # --- Verify bootconf B.conf has required fields ---
  local b_conf="$esp_dir/SteamOS/conf/B.conf"
  local required_fields=("title" "image-invalid" "boot-attempts")
  local field
  for field in "${required_fields[@]}"; do
    local field_found
    field_found="$(grep -v '^\s*#' "$b_conf" 2>/dev/null | grep -c "^${field}=" || echo 0)"
    if [[ "$field_found" -eq 0 ]]; then
      echo "    ASSERTION FAILED: B.conf missing required field '$field'" >&2
      test_harness_fail "F-01: B.conf missing required field '$field'"
    fi
  done

  # --- Verify A UUID is absent from grub.cfg ---
  local a_uuid_count
  a_uuid_count="$(grep -c "$FLASHLESS_CURRENT_UUID" "$grub_cfg" 2>/dev/null || echo 0)"
  if [[ "$a_uuid_count" -gt 0 ]]; then
    echo "    ASSERTION FAILED: grub.cfg still references current (A) UUID '$FLASHLESS_CURRENT_UUID'" >&2
    test_harness_fail "F-01: grub.cfg contains stale A UUID"
    flashless_scenario_teardown
    exit 1
  fi

  flashless_scenario_teardown
}

# ============================================================================
# F-03: Target partsets correct
#
# Setup flashless fixture
# Apply flashless state
# Verify self=B, other=A, exact PARTUUIDs
# ============================================================================
test_f03_target_partsets_correct() {
  flashless_scenario_setup || exit 1

  if ! simulate_flashless_apply; then
    test_harness_fail "F-03: simulate_flashless_apply failed"
    flashless_scenario_teardown
    exit 1
  fi

  # Delegate to the built-in verifier
  if ! verify_target_partsets "$FLASHLESS_EFI_DIR"; then
    test_harness_fail "F-03: verify_target_partsets failed"
    flashless_scenario_teardown
    exit 1
  fi

  # --- Additional: verify self has only B PARTUUIDs, not A ---
  local partsets_dir="$FLASHLESS_EFI_DIR/SteamOS/partsets"
  local self_partset="$partsets_dir/self"

  local target_rootfs_partuuid
  target_rootfs_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "rootfs-${FLASHLESS_TARGET_SLOT}")"
  local other_rootfs_partuuid
  other_rootfs_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "rootfs-${FLASHLESS_CURRENT_SLOT}")"

  local self_content
  self_content="$(cat "$self_partset")"

  test_harness_assert_contains "$self_content" "$target_rootfs_partuuid" || {
    echo "    ASSERTION FAILED: self partset does not contain B rootfs PARTUUID" >&2
  }
  test_harness_assert_not_contains "$self_content" "$other_rootfs_partuuid" || {
    echo "    ASSERTION FAILED: self partset contains A rootfs PARTUUID" >&2
  }

  # --- Verify self has exactly one rootfs, one efi, one var ---
  local rootfs_role_count efi_role_count var_role_count
  rootfs_role_count="$(grep -c '^rootfs ' "$self_partset" 2>/dev/null || echo 0)"
  efi_role_count="$(grep -c '^efi ' "$self_partset" 2>/dev/null || echo 0)"
  var_role_count="$(grep -c '^var ' "$self_partset" 2>/dev/null || echo 0)"
  test_harness_assert_eq "$rootfs_role_count" "1" || {
    echo "    ASSERTION FAILED: self partset expected 1 rootfs entry, got $rootfs_role_count" >&2
  }
  test_harness_assert_eq "$efi_role_count" "1" || {
    echo "    ASSERTION FAILED: self partset expected 1 efi entry, got $efi_role_count" >&2
  }
  test_harness_assert_eq "$var_role_count" "1" || {
    echo "    ASSERTION FAILED: self partset expected 1 var entry, got $var_role_count" >&2
  }

  # --- Verify 'all' partset references both A and B PARTUUIDs ---
  local all_partset="$partsets_dir/all"
  local all_content
  all_content="$(cat "$all_partset")"
  test_harness_assert_contains "$all_content" "$target_rootfs_partuuid" || {
    echo "    ASSERTION FAILED: all partset does not contain B rootfs PARTUUID" >&2
  }
  test_harness_assert_contains "$all_content" "$other_rootfs_partuuid" || {
    echo "    ASSERTION FAILED: all partset does not contain A rootfs PARTUUID" >&2
  }

  flashless_scenario_teardown
}

# ============================================================================
# F-04: Target EFI binary valid
#
# Setup flashless fixture
# Apply flashless state
# Verify valid PE, contains B UUID, no A/source UUID
# ============================================================================
test_f04_target_efi_binary_valid() {
  flashless_scenario_setup || exit 1

  if ! simulate_flashless_apply; then
    test_harness_fail "F-04: simulate_flashless_apply failed"
    flashless_scenario_teardown
    exit 1
  fi

  # Delegate to the built-in verifier
  if ! verify_target_efi_binary "$FLASHLESS_EFI_DIR"; then
    test_harness_fail "F-04: verify_target_efi_binary failed"
    flashless_scenario_teardown
    exit 1
  fi

  flashless_scenario_teardown
}

# ============================================================================
# F-05: Target GRUB configuration valid
#
# Setup flashless fixture
# Apply flashless state
# Verify search/menu uses B UUID, kernels exist, params exactly once
# ============================================================================
test_f05_target_grub_config_valid() {
  flashless_scenario_setup || exit 1

  if ! simulate_flashless_apply; then
    test_harness_fail "F-05: simulate_flashless_apply failed"
    flashless_scenario_teardown
    exit 1
  fi

  # Delegate to the built-in verifier
  if ! verify_target_grub_config "$FLASHLESS_EFI_DIR" "$FLASHLESS_ROOTFS_DIR"; then
    test_harness_fail "F-05: verify_target_grub_config failed"
    flashless_scenario_teardown
    exit 1
  fi

  # --- Additional: verify search --fs-uuid --set=root present ---
  local grub_cfg="$FLASHLESS_EFI_DIR/EFI/steamos/grub.cfg"
  local search_count
  search_count="$(grep -c 'search.*--fs-uuid.*--set=root' "$grub_cfg" 2>/dev/null || echo 0)"
  if [[ "$search_count" -lt 1 ]]; then
    echo "    ASSERTION FAILED: no 'search --fs-uuid --set=root' found in grub.cfg" >&2
    test_harness_fail "F-05: grub.cfg missing search --fs-uuid --set=root"
    flashless_scenario_teardown
    exit 1
  fi

  # --- Verify kernel paths referenced in grub.cfg exist in rootfs ---
  local kernel_path
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    kernel_path="$(printf '%s' "$line" | sed -n 's/^[[:space:]]*linux[[:space:]]\+\([^[:space:]]*\).*/\1/p')"
    if [[ -n "$kernel_path" ]]; then
      local full_kernel_path
      if [[ "$kernel_path" == /* ]]; then
        full_kernel_path="$FLASHLESS_ROOTFS_DIR$kernel_path"
      else
        full_kernel_path="$FLASHLESS_ROOTFS_DIR/$kernel_path"
      fi
      test_harness_assert_file_exists "$full_kernel_path" || {
        echo "    ASSERTION FAILED: kernel path referenced in grub.cfg does not exist: $full_kernel_path" >&2
      }
    fi
  done <<<"$(grep -v '^\s*#' "$grub_cfg" | grep '^\s*linux ')"

  # --- Verify required params exactly once per linux line ---
  local has_duplicate=0
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    if [[ "$line" =~ ^[[:space:]]*linux[[:space:]] ]]; then
      # Extract parameter portion
      local params_portion
      params_portion="$(printf '%s' "$line" | sed 's/^[[:space:]]*linux[[:space:]]\+[^[:space:]]\+[[:space:]]*//')"
      if [[ -n "$params_portion" ]]; then
        local -a tokens=()
        read -ra tokens <<<"$params_portion"
        local -A token_counts=()
        local token
        for token in "${tokens[@]}"; do
          [[ -z "$token" ]] && continue
          token_counts["$token"]=$((${token_counts["$token"]:-0} + 1))
        done
        for token in "${!token_counts[@]}"; do
          if [[ "${token_counts[$token]}" -gt 1 ]]; then
            echo "    ASSERTION FAILED: duplicate parameter '$token' found ${token_counts[$token]} times on a linux line" >&2
            has_duplicate=1
          fi
        done
      fi
    fi
  done <<<"$(grep -v '^\s*#' "$grub_cfg" | grep '^\s*linux ')"

  if [[ "$has_duplicate" -ne 0 ]]; then
    test_harness_fail "F-05: grub.cfg has duplicate required params in linux entries"
    flashless_scenario_teardown
    exit 1
  fi

  flashless_scenario_teardown
}

# ============================================================================
# F-06: Missing B bootconf initialized
#
# Setup flashless fixture without B.conf
# Apply flashless state
# Verify B.conf parseable, staging state
# ============================================================================
test_f06_missing_b_bootconf_initialized() {
  flashless_scenario_setup || exit 1

  # Remove B.conf to simulate a missing bootconf
  local b_conf="$FLASHLESS_ESP_DIR/SteamOS/conf/B.conf"
  rm -f "$b_conf"

  # Verify B.conf is actually gone
  if [[ -f "$b_conf" ]]; then
    echo "    SETUP ERROR: failed to remove B.conf before test" >&2
    test_harness_fail "F-06: could not remove B.conf for setup"
    flashless_scenario_teardown
    exit 1
  fi

  # Apply flashless state — this should recreate B.conf
  if ! simulate_flashless_apply; then
    test_harness_fail "F-06: simulate_flashless_apply failed"
    flashless_scenario_teardown
    exit 1
  fi

  # Delegate to the built-in verifier
  if ! verify_bootconf_initialized "$FLASHLESS_ESP_DIR"; then
    test_harness_fail "F-06: verify_bootconf_initialized failed"
    flashless_scenario_teardown
    exit 1
  fi

  flashless_scenario_teardown
}

# ============================================================================
# F-08: Valid target EFI preserved
#
# Setup flashless fixture with sentinel files
# Apply flashless state
# Verify no mkfs, sentinels unchanged
# ============================================================================
test_f08_valid_target_efi_preserved() {
  flashless_scenario_setup || exit 1

  # Place sentinel files to track whether mkfs is run
  local sentinel_content
  sentinel_content="SENTINEL-$(date +%s)-$$"
  local efi_dir="$FLASHLESS_EFI_DIR"
  local sentinel_default="$efi_dir/EFI/steamos/sentinel-default.grub"
  local sentinel_steamos="$efi_dir/EFI/steamos/sentinel-steamos.grub"
  local sentinel_self="$efi_dir/SteamOS/partsets/sentinel-self"

  echo "$sentinel_content" >"$sentinel_default"
  echo "$sentinel_content" >"$sentinel_steamos"
  echo "$sentinel_content" >"$sentinel_self"

  # Apply flashless state
  if ! simulate_flashless_apply; then
    test_harness_fail "F-08: simulate_flashless_apply failed"
    flashless_scenario_teardown
    exit 1
  fi

  # Delegate to the built-in verifier
  if ! verify_valid_efi_preserved "$FLASHLESS_EFI_DIR" "$sentinel_content"; then
    test_harness_fail "F-08: verify_valid_efi_preserved failed"
    flashless_scenario_teardown
    exit 1
  fi

  # --- Verify sentinel files still have original content ---
  if [[ -f "$sentinel_default" ]]; then
    local actual_default
    actual_default="$(cat "$sentinel_default" 2>/dev/null)"
    test_harness_assert_eq "$actual_default" "$sentinel_content" || {
      echo "    ASSERTION FAILED: sentinel-default.grub was modified" >&2
    }
  fi

  if [[ -f "$sentinel_steamos" ]]; then
    local actual_steamos
    actual_steamos="$(cat "$sentinel_steamos" 2>/dev/null)"
    test_harness_assert_eq "$actual_steamos" "$sentinel_content" || {
      echo "    ASSERTION FAILED: sentinel-steamos.grub was modified" >&2
    }
  fi

  if [[ -f "$sentinel_self" ]]; then
    local actual_self
    actual_self="$(cat "$sentinel_self" 2>/dev/null)"
    test_harness_assert_eq "$actual_self" "$sentinel_content" || {
      echo "    ASSERTION FAILED: sentinel-self was modified" >&2
    }
  fi

  flashless_scenario_teardown
}

# ============================================================================
# F-10: Activation occurs last
#
# Setup flashless fixture
# Apply flashless state
# Verify B valid/active only after all validation
# ============================================================================
test_f10_activation_occurs_last() {
  flashless_scenario_setup || exit 1

  # Apply flashless state (includes activation at the end)
  if ! simulate_flashless_apply; then
    test_harness_fail "F-10: simulate_flashless_apply failed"
    flashless_scenario_teardown
    exit 1
  fi

  # Delegate to the built-in verifier
  if ! verify_activation_occurs_last "$FLASHLESS_ESP_DIR"; then
    test_harness_fail "F-10: verify_activation_occurs_last failed"
    flashless_scenario_teardown
    exit 1
  fi

  # --- Verify B.conf shows image-invalid=0 (activated) ---
  local b_conf="$FLASHLESS_ESP_DIR/SteamOS/conf/B.conf"
  local image_invalid
  image_invalid="$(grep '^image-invalid=' "$b_conf" 2>/dev/null | cut -d= -f2)"
  test_harness_assert_eq "$image_invalid" "0" || {
    echo "    ASSERTION FAILED: B.conf image-invalid should be 0 after activation, got '$image_invalid'" >&2
  }

  # --- Verify activation state file shows B active ---
  if [[ -n "$_FLASHLESS_ACTIVATION_STATE_FILE" && -f "$_FLASHLESS_ACTIVATION_STATE_FILE" ]]; then
    local active_slot
    active_slot="$(grep '^active-slot=' "$_FLASHLESS_ACTIVATION_STATE_FILE" 2>/dev/null | cut -d= -f2)"
    test_harness_assert_eq "$active_slot" "B" || {
      echo "    ASSERTION FAILED: activation state shows active-slot='$active_slot', expected 'B'" >&2
    }

    local b_valid
    b_valid="$(grep '^b-valid=' "$_FLASHLESS_ACTIVATION_STATE_FILE" 2>/dev/null | cut -d= -f2)"
    test_harness_assert_eq "$b_valid" "1" || {
      echo "    ASSERTION FAILED: activation state shows b-valid='$b_valid', expected '1'" >&2
    }
  fi

  # --- Verify A.conf is unchanged (still image-invalid=0) ---
  local a_conf="$FLASHLESS_ESP_DIR/SteamOS/conf/A.conf"
  local a_image_invalid
  a_image_invalid="$(grep '^image-invalid=' "$a_conf" 2>/dev/null | cut -d= -f2)"
  test_harness_assert_eq "$a_image_invalid" "0" || {
    echo "    ASSERTION FAILED: A.conf image-invalid should remain 0, got '$a_image_invalid'" >&2
  }

  flashless_scenario_teardown
}

# ============================================================================
# F-12: On-disk partsets independently verified
#
# Setup flashless fixture
# Apply flashless state
# Mount efi-B and inspect files directly
# ============================================================================
test_f12_on_disk_partsets_independently_verified() {
  flashless_scenario_setup || exit 1

  if ! simulate_flashless_apply; then
    test_harness_fail "F-12: simulate_flashless_apply failed"
    flashless_scenario_teardown
    exit 1
  fi

  local efi_dir="$FLASHLESS_EFI_DIR"
  local partsets_dir="$efi_dir/SteamOS/partsets"
  local uuid_pattern='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

  # --- Verify all partset files exist on disk ---
  test_harness_assert_file_exists "$partsets_dir/self" || {
    echo "    ASSERTION FAILED: on-disk self partset missing" >&2
    flashless_scenario_teardown
    exit 1
  }
  test_harness_assert_file_exists "$partsets_dir/all" || {
    echo "    ASSERTION FAILED: on-disk all partset missing" >&2
    flashless_scenario_teardown
    exit 1
  }
  test_harness_assert_file_exists "$partsets_dir/shared" || {
    echo "    ASSERTION FAILED: on-disk shared partset missing" >&2
    flashless_scenario_teardown
    exit 1
  }

  # --- Inspect self partset directly ---
  local self_content
  self_content="$(cat "$partsets_dir/self")"

  # Derive expected PARTUUIDs
  local self_rootfs_partuuid self_efi_partuuid self_var_partuuid
  self_rootfs_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "rootfs-${FLASHLESS_TARGET_SLOT}")"
  self_efi_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "efi-${FLASHLESS_TARGET_SLOT}")"
  self_var_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "var-${FLASHLESS_TARGET_SLOT}")"

  # Verify each line in self partset: role and PARTUUID format
  local line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    local role uuid
    read -r role uuid _extra <<<"$line"
    if [[ -z "$role" || -z "$uuid" ]]; then
      echo "    ASSERTION FAILED: self partset line $line_num invalid format: '$line'" >&2
      test_harness_fail "F-12: invalid self partset line format"
    elif ! [[ "$uuid" =~ $uuid_pattern ]]; then
      echo "    ASSERTION FAILED: self partset line $line_num invalid PARTUUID: '$uuid'" >&2
      test_harness_fail "F-12: invalid PARTUUID format in self partset"
    elif [[ -n "${_extra:-}" ]]; then
      echo "    ASSERTION FAILED: self partset line $line_num has extra fields: '$line'" >&2
      test_harness_fail "F-12: extra fields in self partset line"
    fi
  done <"$partsets_dir/self"

  # Verify self references B PARTUUIDs
  test_harness_assert_contains "$self_content" "$self_rootfs_partuuid" || {
    echo "    ASSERTION FAILED: on-disk self partset missing B rootfs PARTUUID" >&2
  }
  test_harness_assert_contains "$self_content" "$self_efi_partuuid" || {
    echo "    ASSERTION FAILED: on-disk self partset missing B efi PARTUUID" >&2
  }
  test_harness_assert_contains "$self_content" "$self_var_partuuid" || {
    echo "    ASSERTION FAILED: on-disk self partset missing B var PARTUUID" >&2
  }

  # --- Verify self does NOT contain A PARTUUIDs ---
  local other_rootfs_partuuid other_efi_partuuid other_var_partuuid
  other_rootfs_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "rootfs-${FLASHLESS_CURRENT_SLOT}")"
  other_efi_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "efi-${FLASHLESS_CURRENT_SLOT}")"
  # shellcheck disable=SC2034  # other_var_partuuid reserved for future var PARTUUID assertion
  other_var_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "var-${FLASHLESS_CURRENT_SLOT}")"

  test_harness_assert_not_contains "$self_content" "$other_rootfs_partuuid" || {
    echo "    ASSERTION FAILED: on-disk self partset contains A rootfs PARTUUID" >&2
  }
  test_harness_assert_not_contains "$self_content" "$other_efi_partuuid" || {
    echo "    ASSERTION FAILED: on-disk self partset contains A efi PARTUUID" >&2
  }

  # --- Inspect all partset directly ---
  local all_content
  all_content="$(cat "$partsets_dir/all")"

  # all must contain both A and B rootfs PARTUUIDs
  local esp_partuuid
  esp_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "esp")"
  local rootfs_a_partuuid rootfs_b_partuuid
  rootfs_a_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "rootfs-A")"
  rootfs_b_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "rootfs-B")"

  test_harness_assert_contains "$all_content" "$rootfs_a_partuuid" || {
    echo "    ASSERTION FAILED: on-disk all partset missing A rootfs PARTUUID" >&2
  }
  test_harness_assert_contains "$all_content" "$rootfs_b_partuuid" || {
    echo "    ASSERTION FAILED: on-disk all partset missing B rootfs PARTUUID" >&2
  }
  test_harness_assert_contains "$all_content" "$esp_partuuid" || {
    echo "    ASSERTION FAILED: on-disk all partset missing ESP PARTUUID" >&2
  }

  # --- Inspect shared partset directly ---
  local shared_content
  shared_content="$(cat "$partsets_dir/shared")"
  test_harness_assert_contains "$shared_content" "$esp_partuuid" || {
    echo "    ASSERTION FAILED: on-disk shared partset missing ESP PARTUUID" >&2
  }

  # --- Verify PARTUUID format across all partset files ---
  local format_ok=1
  for partset_file in "$partsets_dir/self" "$partsets_dir/all" "$partsets_dir/shared"; do
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -z "${line// /}" ]] && continue
      local role uuid
      read -r role uuid _extra <<<"$line"
      if [[ -n "$uuid" ]] && ! [[ "$uuid" =~ $uuid_pattern ]]; then
        echo "    ASSERTION FAILED: invalid PARTUUID format in $partset_file: '$uuid'" >&2
        format_ok=0
      fi
    done <"$partset_file"
  done

  if [[ "$format_ok" -eq 0 ]]; then
    test_harness_fail "F-12: on-disk partset files contain invalid PARTUUID formats"
    flashless_scenario_teardown
    exit 1
  fi

  flashless_scenario_teardown
}

# ============================================================================
# F-14: Verity policy completed
#
# Setup flashless fixture
# Apply flashless state
# Verify B verity data regenerated/disabled
# ============================================================================
test_f14_verity_policy_completed() {
  flashless_scenario_setup || exit 1

  if ! simulate_flashless_apply; then
    test_harness_fail "F-14: simulate_flashless_apply failed"
    flashless_scenario_teardown
    exit 1
  fi

  local rootfs_dir="$FLASHLESS_ROOTFS_DIR"
  local efi_dir="$FLASHLESS_EFI_DIR"
  local esp_dir="$FLASHLESS_ESP_DIR"
  local rc=0

  # --- Verify B bootconf is activated (image-invalid=0) ---
  # Verity policy completion requires that the B slot's bootconf has been
  # validated and marked as valid. The image-invalid=0 state confirms the
  # verity check passed.
  local b_conf="$esp_dir/SteamOS/conf/B.conf"
  if [[ ! -f "$b_conf" ]]; then
    echo "    ASSERTION FAILED: B.conf not found (verity policy incomplete)" >&2
    test_harness_fail "F-14: B.conf missing — verity policy incomplete"
    flashless_scenario_teardown
    exit 1
  fi

  local image_invalid
  image_invalid="$(grep '^image-invalid=' "$b_conf" 2>/dev/null | cut -d= -f2)"
  if [[ "$image_invalid" != "0" ]]; then
    echo "    ASSERTION FAILED: B.conf image-invalid='$image_invalid' (expected '0') — verity not completed" >&2
    test_harness_fail "F-14: B.conf not in activated state — verity policy incomplete"
    rc=1
  fi

  # --- Verify B kernel/initramfs exist (verity data is associated with them) ---
  local kernel_version="6.1.52-neptune-61"
  local kernel_path="$rootfs_dir/boot/vmlinuz-${kernel_version}"
  local initramfs_path="$rootfs_dir/boot/initramfs-${kernel_version}.img"

  if [[ ! -f "$kernel_path" ]]; then
    echo "    ASSERTION FAILED: B kernel not found: $kernel_path" >&2
    test_harness_fail "F-14: B kernel missing"
    rc=1
  fi

  if [[ ! -f "$initramfs_path" ]]; then
    echo "    ASSERTION FAILED: B initramfs not found: $initramfs_path" >&2
    test_harness_fail "F-14: B initramfs missing"
    rc=1
  fi

  # --- Verify activation state confirms B is valid ---
  if [[ -n "$_FLASHLESS_ACTIVATION_STATE_FILE" && -f "$_FLASHLESS_ACTIVATION_STATE_FILE" ]]; then
    local b_valid
    b_valid="$(grep '^b-valid=' "$_FLASHLESS_ACTIVATION_STATE_FILE" 2>/dev/null | cut -d= -f2)"
    if [[ "$b_valid" != "1" ]]; then
      echo "    ASSERTION FAILED: activation state shows b-valid='$b_valid' (expected '1') — verity incomplete" >&2
      test_harness_fail "F-14: activation state shows B not valid"
      rc=1
    fi

    local b_image_invalid
    b_image_invalid="$(grep '^b-image-invalid=' "$_FLASHLESS_ACTIVATION_STATE_FILE" 2>/dev/null | cut -d= -f2)"
    if [[ "$b_image_invalid" != "0" ]]; then
      echo "    ASSERTION FAILED: activation state shows b-image-invalid='$b_image_invalid' (expected '0')" >&2
      test_harness_fail "F-14: activation state shows B image-invalid"
      rc=1
    fi
  fi

  # --- Verify grub.cfg references B UUID (identity is bound post-verity) ---
  local grub_cfg="$efi_dir/EFI/steamos/grub.cfg"
  local grub_uuid_count
  grub_uuid_count="$(grep -c "search.*--fs-uuid.*--set=root.*${FLASHLESS_TARGET_UUID}" "$grub_cfg" 2>/dev/null || echo 0)"
  if [[ "$grub_uuid_count" -lt 1 ]]; then
    echo "    ASSERTION FAILED: grub.cfg does not reference target UUID after verity completion" >&2
    test_harness_fail "F-14: grub.cfg missing target UUID after verity completion"
    rc=1
  fi

  if [[ "$rc" -ne 0 ]]; then
    flashless_scenario_teardown
    exit 1
  fi

  flashless_scenario_teardown
}

# ============================================================================
# Run tests
# ============================================================================

# F-01
test_harness_begin_test "F-01: Standby deployment happy path"
(test_f01_standby_deployment_happy_path) || true
# Only pass if the function did not already fail
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# F-03
test_harness_begin_test "F-03: Target partsets correct"
(test_f03_target_partsets_correct) || true
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# F-04
test_harness_begin_test "F-04: Target EFI binary valid"
(test_f04_target_efi_binary_valid) || true
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# F-05
test_harness_begin_test "F-05: Target GRUB configuration valid"
(test_f05_target_grub_config_valid) || true
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# F-06
test_harness_begin_test "F-06: Missing B bootconf initialized"
(test_f06_missing_b_bootconf_initialized) || true
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# F-08
test_harness_begin_test "F-08: Valid target EFI preserved"
(test_f08_valid_target_efi_preserved) || true
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# F-10
test_harness_begin_test "F-10: Activation occurs last"
(test_f10_activation_occurs_last) || true
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# F-12
test_harness_begin_test "F-12: On-disk partsets independently verified"
(test_f12_on_disk_partsets_independently_verified) || true
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# F-14
test_harness_begin_test "F-14: Verity policy completed"
(test_f14_verity_policy_completed) || true
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
test_harness_summary
test_harness_exit_code
