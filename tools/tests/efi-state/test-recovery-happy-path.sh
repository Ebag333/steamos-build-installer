#!/bin/bash
#
# tools/tests/efi-state/test-recovery-happy-path.sh
# Recovery scenario happy-path tests (R-01, R-04, R-05, R-06).
#
# Tests that verify the core happy-path behavior of the EFI state
# application mechanism for the Recovery (dual-slot, current=A, target=B)
# scenario:
#
#   R-01  Staged-slot happy path
#   R-04  Target binary regenerated
#   R-05  Target GRUB config regenerated
#   R-06  Target partsets regenerated
#
# Usage:
#   bash tools/tests/efi-state/test-recovery-happy-path.sh
#
# Dependencies:
#   - test-harness.sh       (lifecycle, assertions)
#   - recovery-helpers.sh   (recovery fixture setup, simulate_recovery_apply)
#   - fixture-factory.sh    (mock fixture creation, UUID/PARTUUID derivation)
#   - topology.sh           (deterministic UUID generation)

set -euo pipefail

# ---------------------------------------------------------------------------
# Source libraries
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
# shellcheck source=test-harness.sh
source "$SCRIPT_DIR/test-harness.sh"
# shellcheck disable=SC1091
# shellcheck source=fixture-factory.sh
source "$SCRIPT_DIR/fixture-factory.sh"
# shellcheck disable=SC1091
# shellcheck source=topology.sh
source "$SCRIPT_DIR/topology.sh"
# shellcheck disable=SC1091
# shellcheck source=recovery-helpers.sh
source "$SCRIPT_DIR/recovery-helpers.sh"

# ---------------------------------------------------------------------------
# Initialize harness
# ---------------------------------------------------------------------------
test_harness_init
trap test_harness_cleanup EXIT

# ============================================================================
# R-01: Staged-slot happy path
#
# Setup recovery fixture (dual-slot, current=A, target=B)
# Apply recovery state to B
# Verify B binary/config match B UUID and kernel
# Verify params present
# ============================================================================
_test_r01_staged_slot_happy_path() {
  recovery_scenario_setup || exit 1

  # Apply recovery state to target B
  if ! simulate_recovery_apply; then
    test_harness_fail "R-01: simulate_recovery_apply failed"
    recovery_scenario_teardown
    exit 1
  fi

  local grub_cfg="$RECOVERY_EFI_DIR/EFI/steamos/grub.cfg"
  local grubx64="$RECOVERY_EFI_DIR/EFI/steamos/grubx64.efi"
  local uuid_pattern='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

  # --- Verify B binary matches B UUID ---
  test_harness_assert_file_exists "$grubx64" || {
    recovery_scenario_teardown
    exit 1
  }

  local embedded_uuid
  embedded_uuid="$(strings "$grubx64" 2>/dev/null | grep -oE "$uuid_pattern" | head -1)"
  test_harness_assert_eq "$embedded_uuid" "$RECOVERY_TARGET_UUID" || {
    recovery_scenario_teardown
    exit 1
  }

  # --- Verify B config (grub.cfg) matches B UUID ---
  test_harness_assert_file_exists "$grub_cfg" || {
    recovery_scenario_teardown
    exit 1
  }

  local grub_uuid_count
  grub_uuid_count="$(grep -c "search.*--fs-uuid.*--set=root.*${RECOVERY_TARGET_UUID}" "$grub_cfg" 2>/dev/null || echo 0)"
  if [[ "$grub_uuid_count" -lt 1 ]]; then
    echo "    ASSERTION FAILED: grub.cfg does not reference target UUID '$RECOVERY_TARGET_UUID'" >&2
    test_harness_fail "R-01: grub.cfg search --fs-uuid does not reference target (B) UUID"
    recovery_scenario_teardown
    exit 1
  fi

  # --- Verify kernel paths present in grub.cfg ---
  if ! grep -q 'linux /boot/vmlinuz-' "$grub_cfg" 2>/dev/null; then
    echo "    ASSERTION FAILED: no linux command with vmlinuz path in grub.cfg" >&2
    test_harness_fail "R-01: grub.cfg missing kernel vmlinuz path"
    recovery_scenario_teardown
    exit 1
  fi

  # --- Verify initramfs paths present in grub.cfg ---
  if ! grep -q 'initrd ' "$grub_cfg" 2>/dev/null; then
    echo "    ASSERTION FAILED: no initrd command in grub.cfg" >&2
    test_harness_fail "R-01: grub.cfg missing initramfs path"
    recovery_scenario_teardown
    exit 1
  fi

  # --- Verify A UUID is absent from grub.cfg ---
  local a_uuid_count
  a_uuid_count="$(grep -c "$RECOVERY_CURRENT_UUID" "$grub_cfg" 2>/dev/null || echo 0)"
  if [[ "$a_uuid_count" -gt 0 ]]; then
    echo "    ASSERTION FAILED: grub.cfg still references current (A) UUID '$RECOVERY_CURRENT_UUID'" >&2
    test_harness_fail "R-01: grub.cfg contains stale A UUID"
    recovery_scenario_teardown
    exit 1
  fi

  recovery_scenario_teardown
}

# ============================================================================
# R-04: Target binary regenerated
#
# Setup recovery fixture
# Apply recovery state
# Verify valid EFI binary with B UUID
# Verify A UUID absent from binary
# ============================================================================
_test_r04_target_binary_regenerated() {
  recovery_scenario_setup || exit 1

  # Apply recovery state to target B
  if ! simulate_recovery_apply; then
    test_harness_fail "R-04: simulate_recovery_apply failed"
    recovery_scenario_teardown
    exit 1
  fi

  local grubx64="$RECOVERY_EFI_DIR/EFI/steamos/grubx64.efi"
  local uuid_pattern='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

  # --- Verify valid EFI binary (exists, non-empty, MZ header) ---
  test_harness_assert_file_exists "$grubx64" || {
    recovery_scenario_teardown
    exit 1
  }

  local file_size
  file_size="$(stat -c '%s' "$grubx64" 2>/dev/null || echo 0)"
  if [[ "$file_size" -eq 0 ]]; then
    echo "    ASSERTION FAILED: grubx64.efi is empty" >&2
    test_harness_fail "R-04: grubx64.efi is empty"
    recovery_scenario_teardown
    exit 1
  fi

  local mz_header
  mz_header="$(dd if="$grubx64" bs=1 count=2 2>/dev/null | od -A n -t x1 | tr -d ' ')"
  test_harness_assert_eq "$mz_header" "4d5a" || {
    recovery_scenario_teardown
    exit 1
  }

  # --- Verify binary contains B UUID ---
  local embedded_uuid
  embedded_uuid="$(strings "$grubx64" 2>/dev/null | grep -oE "$uuid_pattern" | head -1)"
  test_harness_assert_eq "$embedded_uuid" "$RECOVERY_TARGET_UUID" || {
    recovery_scenario_teardown
    exit 1
  }

  # --- Verify A UUID absent from binary ---
  if strings "$grubx64" 2>/dev/null | grep -q "$RECOVERY_CURRENT_UUID"; then
    echo "    ASSERTION FAILED: grubx64.efi contains stale current (A) UUID '$RECOVERY_CURRENT_UUID'" >&2
    test_harness_fail "R-04: EFI binary contains stale A UUID"
    recovery_scenario_teardown
    exit 1
  fi

  # --- Verify only one UUID in the binary (no stale references) ---
  local -a all_uuids
  mapfile -t all_uuids < <(strings "$grubx64" 2>/dev/null | grep -oE "$uuid_pattern")
  if [[ "${#all_uuids[@]}" -gt 1 ]]; then
    echo "    ASSERTION FAILED: multiple UUIDs found in EFI binary:" >&2
    printf "      %s\n" "${all_uuids[@]}" >&2
    test_harness_fail "R-04: EFI binary contains ${#all_uuids[@]} UUIDs (expected 1)"
    recovery_scenario_teardown
    exit 1
  fi

  recovery_scenario_teardown
}

# ============================================================================
# R-05: Target GRUB config regenerated
#
# Setup recovery fixture
# Apply recovery state
# Verify B UUID and kernel paths correct
# Verify required params exactly once per entry
# ============================================================================
_test_r05_target_grub_config_regenerated() {
  recovery_scenario_setup || exit 1

  # Apply recovery state to target B
  if ! simulate_recovery_apply; then
    test_harness_fail "R-05: simulate_recovery_apply failed"
    recovery_scenario_teardown
    exit 1
  fi

  local grub_cfg="$RECOVERY_EFI_DIR/EFI/steamos/grub.cfg"
  test_harness_assert_file_exists "$grub_cfg" || {
    recovery_scenario_teardown
    exit 1
  }

  # --- Verify B UUID in grub.cfg ---
  local target_uuid_count
  target_uuid_count="$(grep -c "$RECOVERY_TARGET_UUID" "$grub_cfg" 2>/dev/null || true)"
  target_uuid_count="${target_uuid_count:-0}"
  if [[ "$target_uuid_count" -lt 1 ]]; then
    echo "    ASSERTION FAILED: grub.cfg does not contain target UUID '$RECOVERY_TARGET_UUID'" >&2
    test_harness_fail "R-05: grub.cfg missing target (B) UUID"
    recovery_scenario_teardown
    exit 1
  fi

  # --- Verify A UUID absent from grub.cfg ---
  local current_uuid_count
  current_uuid_count="$(grep -c "$RECOVERY_CURRENT_UUID" "$grub_cfg" 2>/dev/null || true)"
  current_uuid_count="${current_uuid_count:-0}"
  if [[ "$current_uuid_count" -gt 0 ]]; then
    echo "    ASSERTION FAILED: grub.cfg contains stale current (A) UUID '$RECOVERY_CURRENT_UUID'" >&2
    test_harness_fail "R-05: grub.cfg contains stale A UUID"
    recovery_scenario_teardown
    exit 1
  fi

  # --- Verify kernel paths correct (vmlinuz references exist in rootfs) ---
  local kernel_path
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    kernel_path="$(printf '%s' "$line" | sed -n 's/^[[:space:]]*linux[[:space:]]\+\([^[:space:]]*\).*/\1/p')"
    if [[ -n "$kernel_path" ]]; then
      local full_kernel_path
      if [[ "$kernel_path" == /* ]]; then
        full_kernel_path="$RECOVERY_ROOTFS_DIR$kernel_path"
      else
        full_kernel_path="$RECOVERY_ROOTFS_DIR/$kernel_path"
      fi
      test_harness_assert_file_exists "$full_kernel_path" || {
        echo "    ASSERTION FAILED: kernel path referenced in grub.cfg does not exist: $full_kernel_path" >&2
      }
    fi
  done <<<"$(grep -v '^\s*#' "$grub_cfg" | grep '^\s*linux ')"

  # --- Verify required params exactly once per entry ---
  # Required params: ro (and root=UUID=... which is built into the linux line).
  # We check that 'ro' appears exactly once per linux line (not zero, not duplicate).
  local has_duplicate=0
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    # Only check lines that have a linux command
    if [[ "$line" =~ ^[[:space:]]*linux[[:space:]] ]]; then
      # Count occurrences of 'ro' as a standalone token at end of the line
      local ro_count
      ro_count="$(printf '%s' "$line" | grep -oE '\bro\b$' | wc -l)"
      if [[ "$ro_count" -eq 0 ]]; then
        echo "    WARNING: linux entry missing 'ro' param: $line" >&2
      elif [[ "$ro_count" -gt 1 ]]; then
        echo "    ASSERTION FAILED: duplicate 'ro' param in linux entry: $line" >&2
        has_duplicate=1
      fi
    fi
  done <<<"$(grep -v '^\s*#' "$grub_cfg" | grep '^\s*linux ')"

  if [[ "$has_duplicate" -ne 0 ]]; then
    test_harness_fail "R-05: grub.cfg has duplicate required params in linux entries"
    recovery_scenario_teardown
    exit 1
  fi

  # --- Verify search --fs-uuid --set=root present ---
  local search_count
  search_count="$(grep -c 'search.*--fs-uuid.*--set=root' "$grub_cfg" 2>/dev/null || echo 0)"
  if [[ "$search_count" -lt 1 ]]; then
    echo "    ASSERTION FAILED: no 'search --fs-uuid --set=root' found in grub.cfg" >&2
    test_harness_fail "R-05: grub.cfg missing search --fs-uuid --set=root"
    recovery_scenario_teardown
    exit 1
  fi

  recovery_scenario_teardown
}

# ============================================================================
# R-06: Target partsets regenerated
#
# Setup recovery fixture
# Apply recovery state
# Verify self=B, other=A
# Verify PARTUUIDs match
# ============================================================================
_test_r06_target_partsets_regenerated() {
  recovery_scenario_setup || exit 1

  # Apply recovery state to target B
  if ! simulate_recovery_apply; then
    test_harness_fail "R-06: simulate_recovery_apply failed"
    recovery_scenario_teardown
    exit 1
  fi

  local partsets_dir="$RECOVERY_EFI_DIR/SteamOS/partsets"

  # --- Verify self partset exists and references B-partition PARTUUIDs ---
  local self_partset="$partsets_dir/self"
  test_harness_assert_file_exists "$self_partset" || {
    recovery_scenario_teardown
    exit 1
  }

  # Derive expected PARTUUIDs for self (target = B)
  local self_rootfs_partuuid self_efi_partuuid self_var_partuuid
  self_rootfs_partuuid="$(derive_partuuid "$RECOVERY_NAMESPACE" "rootfs-${RECOVERY_TARGET_SLOT}")"
  self_efi_partuuid="$(derive_partuuid "$RECOVERY_NAMESPACE" "efi-${RECOVERY_TARGET_SLOT}")"
  self_var_partuuid="$(derive_partuuid "$RECOVERY_NAMESPACE" "var-${RECOVERY_TARGET_SLOT}")"

  # Verify self references B PARTUUIDs
  local self_content
  self_content="$(cat "$self_partset")"
  test_harness_assert_contains "$self_content" "$self_rootfs_partuuid" || {
    echo "    ASSERTION FAILED: self partset does not contain target rootfs PARTUUID" >&2
  }
  test_harness_assert_contains "$self_content" "$self_efi_partuuid" || {
    echo "    ASSERTION FAILED: self partset does not contain target efi PARTUUID" >&2
  }
  test_harness_assert_contains "$self_content" "$self_var_partuuid" || {
    echo "    ASSERTION FAILED: self partset does not contain target var PARTUUID" >&2
  }

  # --- Verify self does NOT reference A PARTUUIDs ---
  local other_rootfs_partuuid other_efi_partuuid
  other_rootfs_partuuid="$(derive_partuuid "$RECOVERY_NAMESPACE" "rootfs-${RECOVERY_CURRENT_SLOT}")"
  other_efi_partuuid="$(derive_partuuid "$RECOVERY_NAMESPACE" "efi-${RECOVERY_CURRENT_SLOT}")"

  test_harness_assert_not_contains "$self_content" "$other_rootfs_partuuid" || {
    echo "    ASSERTION FAILED: self partset contains A rootfs PARTUUID (should only have B)" >&2
  }
  test_harness_assert_not_contains "$self_content" "$other_efi_partuuid" || {
    echo "    ASSERTION FAILED: self partset contains A efi PARTUUID (should only have B)" >&2
  }

  # --- Verify self has correct roles ---
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
  test_harness_assert_file_exists "$all_partset" || {
    recovery_scenario_teardown
    exit 1
  }

  local all_content
  all_content="$(cat "$all_partset")"
  # all should contain B rootfs PARTUUID
  test_harness_assert_contains "$all_content" "$self_rootfs_partuuid" || {
    echo "    ASSERTION FAILED: all partset does not contain B rootfs PARTUUID" >&2
  }
  # all should contain A rootfs PARTUUID
  test_harness_assert_contains "$all_content" "$other_rootfs_partuuid" || {
    echo "    ASSERTION FAILED: all partset does not contain A rootfs PARTUUID" >&2
  }

  # --- Verify 'shared' partset references ESP PARTUUID ---
  local shared_partset="$partsets_dir/shared"
  test_harness_assert_file_exists "$shared_partset" || {
    recovery_scenario_teardown
    exit 1
  }

  local esp_partuuid
  esp_partuuid="$(derive_partuuid "$RECOVERY_NAMESPACE" "esp")"
  local shared_content
  shared_content="$(cat "$shared_partset")"
  test_harness_assert_contains "$shared_content" "$esp_partuuid" || {
    echo "    ASSERTION FAILED: shared partset does not contain ESP PARTUUID" >&2
  }

  # --- Verify PARTUUID format in all partset files (no stale/corrupt entries) ---
  local uuid_pattern='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  local format_ok=1
  for partset_file in "$self_partset" "$all_partset" "$shared_partset"; do
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -z "${line// /}" ]] && continue
      local uuid
      read -r _ uuid _extra <<<"$line"
      if [[ -n "$uuid" ]] && ! [[ "$uuid" =~ $uuid_pattern ]]; then
        echo "    ASSERTION FAILED: invalid PARTUUID format in $partset_file: '$uuid'" >&2
        format_ok=0
      fi
    done <"$partset_file"
  done

  if [[ "$format_ok" -eq 0 ]]; then
    test_harness_fail "R-06: partset files contain invalid PARTUUID formats"
    recovery_scenario_teardown
    exit 1
  fi

  recovery_scenario_teardown
}

# ============================================================================
# Run tests
# ============================================================================

# R-01
test_harness_begin_test "R-01: Staged-slot happy path"
(_test_r01_staged_slot_happy_path) || true
# Only pass if the function did not already fail
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# R-04
test_harness_begin_test "R-04: Target binary regenerated"
(_test_r04_target_binary_regenerated) || true
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# R-05
test_harness_begin_test "R-05: Target GRUB config regenerated"
(_test_r05_target_grub_config_regenerated) || true
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# R-06
test_harness_begin_test "R-06: Target partsets regenerated"
(_test_r06_target_partsets_regenerated) || true
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
test_harness_summary
test_harness_exit_code
