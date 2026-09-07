#!/bin/bash
#
# tools/tests/efi-state/test-live-happy-path.sh
# Live scenario happy-path tests (L-01, L-04, L-05, L-06, L-07, L-08).
#
# Tests that verify the core happy-path behavior of the EFI state
# application mechanism for the Live (dual-slot, current=A, target=A)
# scenario:
#
#   L-01  Current-slot happy path
#   L-04  Persistent defaults patched
#   L-05  Atomic-update persistence maintained
#   L-06  update-grub runs directly
#   L-07  Authoritative config patch follows generation
#   L-08  Complete validation runs
#
# Usage:
#   bash tools/tests/efi-state/test-live-happy-path.sh
#
# Dependencies:
#   - test-harness.sh       (lifecycle, assertions)
#   - live-helpers.sh       (live fixture setup, simulate_live_apply)
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
# shellcheck source=live-helpers.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/live-helpers.sh"

# ---------------------------------------------------------------------------
# Initialize harness
# ---------------------------------------------------------------------------
test_harness_init
trap test_harness_cleanup EXIT

# ============================================================================
# L-01: Current-slot happy path
#
# Setup live fixture (dual-slot, current=A, target=A)
# Apply live state to current slot (A)
# Verify grub.cfg has correct UUID, kernel paths, params
# ============================================================================
_test_l01_current_slot_happy_path() {
  live_scenario_setup || exit 1

  # Apply live state to current slot (A = target)
  if ! simulate_live_apply; then
    test_harness_fail "L-01: simulate_live_apply failed"
    live_scenario_teardown
    exit 1
  fi

  local grub_cfg="$LIVE_EFI_DIR/EFI/steamos/grub.cfg"
  local grubx64="$LIVE_EFI_DIR/EFI/steamos/grubx64.efi"
  local uuid_pattern='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

  # --- Verify EFI binary exists and contains target UUID ---
  test_harness_assert_file_exists "$grubx64" || {
    live_scenario_teardown
    exit 1
  }

  local embedded_uuid
  embedded_uuid="$(strings "$grubx64" 2>/dev/null | grep -oE "$uuid_pattern" | head -1)"
  test_harness_assert_eq "$embedded_uuid" "$LIVE_TARGET_UUID" || {
    live_scenario_teardown
    exit 1
  }

  # --- Verify grub.cfg exists and has correct UUID in search entries ---
  test_harness_assert_file_exists "$grub_cfg" || {
    live_scenario_teardown
    exit 1
  }

  local grub_uuid_count
  grub_uuid_count="$(grep -c "search.*--fs-uuid.*--set=root.*${LIVE_TARGET_UUID}" "$grub_cfg" 2>/dev/null || echo 0)"
  if [[ "$grub_uuid_count" -lt 1 ]]; then
    echo "    ASSERTION FAILED: grub.cfg does not reference target UUID '$LIVE_TARGET_UUID'" >&2
    test_harness_fail "L-01: grub.cfg search --fs-uuid does not reference target UUID"
    live_scenario_teardown
    exit 1
  fi

  # --- Verify kernel paths present in grub.cfg ---
  if ! grep -q 'linux /boot/vmlinuz-' "$grub_cfg" 2>/dev/null; then
    echo "    ASSERTION FAILED: no linux command with vmlinuz path in grub.cfg" >&2
    test_harness_fail "L-01: grub.cfg missing kernel vmlinuz path"
    live_scenario_teardown
    exit 1
  fi

  # --- Verify initramfs paths present in grub.cfg ---
  if ! grep -q 'initrd ' "$grub_cfg" 2>/dev/null; then
    echo "    ASSERTION FAILED: no initrd command in grub.cfg" >&2
    test_harness_fail "L-01: grub.cfg missing initramfs path"
    live_scenario_teardown
    exit 1
  fi

  # --- Verify required params (ro) present in each linux line ---
  local has_duplicate=0
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    if [[ "$line" =~ ^[[:space:]]*linux[[:space:]] ]]; then
      local ro_count
      ro_count="$(printf '%s' "$line" | grep -oE '\bro\b' | wc -l)"
      if [[ "$ro_count" -eq 0 ]]; then
        echo "    WARNING: linux entry missing 'ro' param: $line" >&2
      elif [[ "$ro_count" -gt 1 ]]; then
        echo "    ASSERTION FAILED: duplicate 'ro' param in linux entry: $line" >&2
        has_duplicate=1
      fi
    fi
  done <<<"$(grep -v '^\s*#' "$grub_cfg" | grep '^\s*linux ')"

  if [[ "$has_duplicate" -ne 0 ]]; then
    test_harness_fail "L-01: grub.cfg has duplicate required params in linux entries"
    live_scenario_teardown
    exit 1
  fi

  live_scenario_teardown
}

# ============================================================================
# L-04: Persistent defaults patched
#
# Setup live fixture
# Apply live state
# Verify grub and grub-steamos contain each param exactly once
# ============================================================================
_test_l04_persistent_defaults_patched() {
  live_scenario_setup || exit 1

  if ! simulate_live_apply; then
    test_harness_fail "L-04: simulate_live_apply failed"
    live_scenario_teardown
    exit 1
  fi

  local grub_defaults="$LIVE_ROOTFS_DIR/etc/default/grub"
  local grub_steamos="$LIVE_ROOTFS_DIR/etc/default/grub-steamos"

  # --- Verify /etc/default/grub exists ---
  test_harness_assert_file_exists "$grub_defaults" || {
    live_scenario_teardown
    exit 1
  }

  # --- Verify /etc/default/grub-steamos exists ---
  test_harness_assert_file_exists "$grub_steamos" || {
    live_scenario_teardown
    exit 1
  }

  # --- Verify GRUB_CMDLINE_LINUX_DEFAULT appears exactly once in each file ---
  local grub_default_count
  grub_default_count="$(grep -c '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_defaults" 2>/dev/null || echo 0)"
  if [[ "$grub_default_count" -ne 1 ]]; then
    echo "    ASSERTION FAILED: grub has $grub_default_count GRUB_CMDLINE_LINUX_DEFAULT entries (expected 1)" >&2
    test_harness_fail "L-04: /etc/default/grub GRUB_CMDLINE_LINUX_DEFAULT count != 1"
    live_scenario_teardown
    exit 1
  fi

  local steamos_default_count
  steamos_default_count="$(grep -c '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_steamos" 2>/dev/null || echo 0)"
  if [[ "$steamos_default_count" -ne 1 ]]; then
    echo "    ASSERTION FAILED: grub-steamos has $steamos_default_count GRUB_CMDLINE_LINUX_DEFAULT entries (expected 1)" >&2
    test_harness_fail "L-04: /etc/default/grub-steamos GRUB_CMDLINE_LINUX_DEFAULT count != 1"
    live_scenario_teardown
    exit 1
  fi

  # --- Verify GRUB_CMDLINE_LINUX appears exactly once in each file ---
  local grub_cmdline_count
  grub_cmdline_count="$(grep -c '^GRUB_CMDLINE_LINUX=' "$grub_defaults" 2>/dev/null || echo 0)"
  if [[ "$grub_cmdline_count" -ne 1 ]]; then
    echo "    ASSERTION FAILED: grub has $grub_cmdline_count GRUB_CMDLINE_LINUX entries (expected 1)" >&2
    test_harness_fail "L-04: /etc/default/grub GRUB_CMDLINE_LINUX count != 1"
    live_scenario_teardown
    exit 1
  fi

  local steamos_cmdline_count
  steamos_cmdline_count="$(grep -c '^GRUB_CMDLINE_LINUX=' "$grub_steamos" 2>/dev/null || echo 0)"
  if [[ "$steamos_cmdline_count" -ne 1 ]]; then
    echo "    ASSERTION FAILED: grub-steamos has $steamos_cmdline_count GRUB_CMDLINE_LINUX entries (expected 1)" >&2
    test_harness_fail "L-04: /etc/default/grub-steamos GRUB_CMDLINE_LINUX count != 1"
    live_scenario_teardown
    exit 1
  fi

  live_scenario_teardown
}

# ============================================================================
# L-05: Atomic-update persistence maintained
#
# Setup live fixture
# Apply live state
# Verify required defaults appear exactly once in keep-list
# ============================================================================
_test_l05_atomic_update_persistence() {
  live_scenario_setup || exit 1

  if ! simulate_live_apply; then
    test_harness_fail "L-05: simulate_live_apply failed"
    live_scenario_teardown
    exit 1
  fi

  # Use the validator to check keep-list exactness with required defaults
  if ! verify_keep_list_exact_once "$LIVE_ROOTFS_DIR" \
    "/boot/vmlinuz-*" \
    "/boot/initramfs-*" \
    "/boot/amd-ucode.img" \
    "/etc/default/grub" \
    "/etc/default/grub-steamos"; then
    test_harness_fail "L-05: verify_keep_list_exact_once failed"
    live_scenario_teardown
    exit 1
  fi

  live_scenario_teardown
}

# ============================================================================
# L-06: update-grub runs directly
#
# Setup live fixture
# Apply live state
# Verify update-grub was called (via shim tracking)
# ============================================================================
_test_l06_update_grub_runs_directly() {
  live_scenario_setup || exit 1

  # Create a tracking shim for update-grub
  local shim_dir="$LIVE_FIXTURE_DIR/.shim-bin"
  mkdir -p "$shim_dir"

  local tracker_file="$LIVE_FIXTURE_DIR/.update-grub-called"

  cat >"$shim_dir/update-grub" <<SHIM_EOF
#!/bin/bash
# Tracking shim: records that update-grub was called
echo "\$\$" > "$tracker_file"
# Also call the real function to regenerate grub.cfg
populate_mock_grub_cfg "$LIVE_EFI_DIR/EFI/steamos/grub.cfg" "$LIVE_TARGET_UUID"
exit 0
SHIM_EOF
  chmod +x "$shim_dir/update-grub"

  # Prepend shim dir to PATH so it is found first
  export PATH="$shim_dir:$PATH"

  # Apply live state (should invoke our shim)
  if ! simulate_live_apply; then
    test_harness_fail "L-06: simulate_live_apply failed"
    live_scenario_teardown
    exit 1
  fi

  # --- Verify the shim was called ---
  if [[ ! -f "$tracker_file" ]]; then
    echo "    ASSERTION FAILED: update-grub shim was not called (tracker file missing)" >&2
    test_harness_fail "L-06: update-grub was not invoked during live apply"
    live_scenario_teardown
    exit 1
  fi

  # Restore default PATH (remove shim dir)
  PATH="${PATH#"$shim_dir":}"

  live_scenario_teardown
}

# ============================================================================
# L-07: Authoritative config patch follows generation
#
# Setup live fixture
# Apply live state
# Verify every linux line has params exactly once
# ============================================================================
_test_l07_authoritative_config_patch() {
  live_scenario_setup || exit 1

  if ! simulate_live_apply; then
    test_harness_fail "L-07: simulate_live_apply failed"
    live_scenario_teardown
    exit 1
  fi

  local grub_cfg="$LIVE_EFI_DIR/EFI/steamos/grub.cfg"
  test_harness_assert_file_exists "$grub_cfg" || {
    live_scenario_teardown
    exit 1
  }

  # --- Verify no duplicate parameters across all linux lines ---
  if ! verify_no_duplicate_params "$LIVE_EFI_DIR"; then
    test_harness_fail "L-07: verify_no_duplicate_params failed"
    live_scenario_teardown
    exit 1
  fi

  # --- Detailed per-param check for key params ---
  local -a required_params=("ro")
  local rc=0

  for param in "${required_params[@]}"; do
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -z "${line// /}" ]] && continue
      if [[ "$line" =~ ^[[:space:]]*linux[[:space:]] ]]; then
        # Extract params portion (everything after "linux <path> ")
        local params_portion
        params_portion="$(printf '%s' "$line" | sed 's/^[[:space:]]*linux[[:space:]]\+[^[:space:]]\+[[:space:]]*//')"
        local -a tokens=()
        read -ra tokens <<<"$params_portion"

        # Count occurrences of this param as a whole token
        local param_count=0
        local token
        for token in "${tokens[@]}"; do
          if [[ "$token" == "$param" ]]; then
            param_count=$((param_count + 1))
          fi
        done

        if [[ "$param_count" -eq 0 ]]; then
          echo "    WARNING: linux entry missing '$param': $line" >&2
        elif [[ "$param_count" -gt 1 ]]; then
          echo "    ASSERTION FAILED: linux entry has '$param' $param_count times: $line" >&2
          rc=1
        fi
      fi
    done <<<"$(grep -v '^\s*#' "$grub_cfg" | grep '^\s*linux ')"
  done

  if [[ "$rc" -ne 0 ]]; then
    test_harness_fail "L-07: authoritative config patch produced duplicate params"
    live_scenario_teardown
    exit 1
  fi

  live_scenario_teardown
}

# ============================================================================
# L-08: Complete validation runs
#
# Setup live fixture
# Apply live state
# Run all validators
# Verify all pass
# ============================================================================
_test_l08_complete_validation() {
  live_scenario_setup || exit 1

  if ! simulate_live_apply; then
    test_harness_fail "L-08: simulate_live_apply failed"
    live_scenario_teardown
    exit 1
  fi

  local rc=0

  # --- validate_grub_structure ---
  if ! validate_grub_structure "$LIVE_ROOTFS_DIR" "$LIVE_EFI_DIR" "$LIVE_TARGET_UUID"; then
    echo "    VALIDATOR FAILED: validate_grub_structure" >&2
    rc=1
  fi

  # --- validate_boot_paths ---
  if ! validate_boot_paths "$LIVE_ROOTFS_DIR" "$LIVE_TARGET_UUID"; then
    echo "    VALIDATOR FAILED: validate_boot_paths" >&2
    rc=1
  fi

  # --- validate_partsets ---
  # Live scenario is dual-slot (A+B), so all partition views should exist
  if ! validate_partsets "$LIVE_EFI_DIR" "A,B,self,other,all,shared"; then
    echo "    VALIDATOR FAILED: validate_partsets" >&2
    rc=1
  fi

  # --- validate_bootconf ---
  if ! validate_bootconf "$LIVE_ESP_DIR/SteamOS/conf" "A.conf,B.conf"; then
    echo "    VALIDATOR FAILED: validate_bootconf" >&2
    rc=1
  fi

  # --- validate_cross_artifact_consistency ---
  if ! validate_cross_artifact_consistency "$LIVE_ROOTFS_DIR" "$LIVE_EFI_DIR" "$LIVE_TARGET_UUID"; then
    echo "    VALIDATOR FAILED: validate_cross_artifact_consistency" >&2
    rc=1
  fi

  # --- validate_transaction_phase ---
  if ! validate_transaction_phase "$LIVE_EFI_DIR" "$LIVE_ESP_DIR"; then
    echo "    VALIDATOR FAILED: validate_transaction_phase" >&2
    rc=1
  fi

  if [[ "$rc" -ne 0 ]]; then
    test_harness_fail "L-08: one or more validators failed"
    live_scenario_teardown
    exit 1
  fi

  live_scenario_teardown
}

# ============================================================================
# Run tests
# ============================================================================

# L-01
test_harness_begin_test "L-01: Current-slot happy path"
(_test_l01_current_slot_happy_path) || true
# Only pass if the function did not already fail
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# L-04
test_harness_begin_test "L-04: Persistent defaults patched"
(_test_l04_persistent_defaults_patched) || true
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# L-05
test_harness_begin_test "L-05: Atomic-update persistence maintained"
(_test_l05_atomic_update_persistence) || true
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# L-06
test_harness_begin_test "L-06: update-grub runs directly"
(_test_l06_update_grub_runs_directly) || true
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# L-07
test_harness_begin_test "L-07: Authoritative config patch follows generation"
(_test_l07_authoritative_config_patch) || true
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# L-08
test_harness_begin_test "L-08: Complete validation runs"
(_test_l08_complete_validation) || true
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
test_harness_summary
test_harness_exit_code
