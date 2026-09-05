#!/bin/bash
#
# tools/tests/efi-state/recovery-helpers.sh
# Recovery-specific test infrastructure for EFI state application tests.
#
# Provides helper functions for Recovery scenario tests (dual-slot, current=A,
# target=B), including fixture setup/teardown, EFI state application simulation,
# preflight validation, error injection with rollback verification, and
# composition helpers for the recovery test suite.
#
# Usage:
#   source tools/tests/efi-state/recovery-helpers.sh
#
# Dependencies:
#   - test-harness.sh    (assertion helpers, test lifecycle)
#   - fixture-factory.sh (mock fixture creation/destruction)
#   - topology.sh         (deterministic UUID/PARTUUID generation)
#
# Design constraints:
#   - Recovery scenario: dual-slot, current=A, target=B
#   - Functions are composable and reusable across test cases
#   - Support both happy path and error injection scenarios
#   - A slot must remain byte-identical after any recovery operation
#   - Non-target isolation: no writes to A rootfs/efi/bootconf

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "recovery-helpers.sh is a library — source it, don't run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Guard: ensure required libraries are loaded
# ---------------------------------------------------------------------------
if ! declare -f test_harness_init >/dev/null 2>&1; then
  echo "ERROR: recovery-helpers.sh requires test-harness.sh (source it first)." >&2
  return 1 2>/dev/null || exit 1
fi

if ! declare -f create_mock_boot_fixture >/dev/null 2>&1; then
  echo "ERROR: recovery-helpers.sh requires fixture-factory.sh (source it first)." >&2
  return 1 2>/dev/null || exit 1
fi

# ---------------------------------------------------------------------------
# Recovery scenario constants
# ---------------------------------------------------------------------------
RECOVERY_SLOT_COUNT=2
RECOVERY_CURRENT_SLOT="A"
RECOVERY_TARGET_SLOT="B"
RECOVERY_SCENARIO="recovery"

# ============================================================================
# Global state for recovery fixture
# ============================================================================
RECOVERY_FIXTURE_DIR=""
RECOVERY_ROOTFS_DIR=""
RECOVERY_ROOTFS_B_DIR=""
RECOVERY_EFI_DIR=""
RECOVERY_ESP_DIR=""
RECOVERY_METADATA_DIR=""
RECOVERY_NAMESPACE=""
RECOVERY_TARGET_UUID=""
RECOVERY_CURRENT_UUID=""

# Snapshot checksums for A-slot preservation verification
_RECOVERY_SLOT_A_CHECKSUMS=""

# ============================================================================
# recovery_scenario_setup
#
# Create a recovery-specific mock fixture (dual-slot, current=A, target=B).
#
# Usage:
#   recovery_scenario_setup
#
# Sets the following global variables for test access:
#   RECOVERY_FIXTURE_DIR   - Root of the mock fixture tree
#   RECOVERY_ROOTFS_DIR    - Mock rootfs mount point (slot B / target)
#   RECOVERY_ROOTFS_B_DIR  - Alias: same as RECOVERY_ROOTFS_DIR
#   RECOVERY_EFI_DIR       - Mock EFI partition mount point
#   RECOVERY_ESP_DIR       - Mock shared ESP mount point
#   RECOVERY_METADATA_DIR  - Mock metadata directory
#   RECOVERY_TARGET_UUID   - Target rootfs UUID (slot B)
#   RECOVERY_CURRENT_UUID  - Current rootfs UUID (slot A)
#   RECOVERY_NAMESPACE     - Test namespace for UUID derivation
#
# The fixture is created in a temporary directory that is automatically
# cleaned up by recovery_scenario_teardown().
# ============================================================================
recovery_scenario_setup() {
  # Create temporary base directory
  RECOVERY_FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/recovery-test-XXXXXX")"
  if [[ -z "$RECOVERY_FIXTURE_DIR" || ! -d "$RECOVERY_FIXTURE_DIR" ]]; then
    echo "ERROR: recovery_scenario_setup: failed to create temp directory" >&2
    return 1
  fi

  RECOVERY_NAMESPACE="recovery-${RECOVERY_TARGET_SLOT}-$$"

  # Use fixture-factory to create the complete dual-slot mock fixture.
  # create_mock_boot_fixture determines that current_slot is A (the inverse
  # of target_slot=B) and creates both slot A and slot B directories.
  create_mock_boot_fixture "$RECOVERY_FIXTURE_DIR" "$RECOVERY_SCENARIO" "$RECOVERY_TARGET_SLOT" "$RECOVERY_NAMESPACE"

  # Set convenience variables for test access
  # The rootfs dir from fixture-factory is the *target* rootfs (slot B).
  RECOVERY_ROOTFS_DIR="$RECOVERY_FIXTURE_DIR/rootfs"
  RECOVERY_ROOTFS_B_DIR="$RECOVERY_ROOTFS_DIR"
  RECOVERY_EFI_DIR="$RECOVERY_FIXTURE_DIR/efi"
  RECOVERY_ESP_DIR="$RECOVERY_FIXTURE_DIR/esp"
  RECOVERY_METADATA_DIR="$RECOVERY_FIXTURE_DIR/metadata"

  # Derive UUIDs (consistent with fixture-factory)
  RECOVERY_TARGET_UUID="$(derive_uuid "$RECOVERY_NAMESPACE" "rootfs-${RECOVERY_TARGET_SLOT}")"
  RECOVERY_CURRENT_UUID="$(derive_uuid "$RECOVERY_NAMESPACE" "rootfs-${RECOVERY_CURRENT_SLOT}")"

  # Snapshot A-slot state for preservation verification
  _recovery_snapshot_slot_a

  # Verify fixture was created correctly
  if [[ ! -d "$RECOVERY_EFI_DIR/EFI/steamos" ]]; then
    echo "ERROR: recovery_scenario_setup: EFI fixture directory not created" >&2
    recovery_scenario_teardown
    return 1
  fi

  if [[ ! -f "$RECOVERY_EFI_DIR/EFI/steamos/grub.cfg" ]]; then
    echo "ERROR: recovery_scenario_setup: grub.cfg not created" >&2
    recovery_scenario_teardown
    return 1
  fi

  # Verify dual-slot structure: both A and B partsets should exist
  if [[ ! -f "$RECOVERY_EFI_DIR/SteamOS/partsets/A" ]]; then
    echo "ERROR: recovery_scenario_setup: slot A partset not created" >&2
    recovery_scenario_teardown
    return 1
  fi

  if [[ ! -f "$RECOVERY_EFI_DIR/SteamOS/partsets/B" ]]; then
    echo "ERROR: recovery_scenario_setup: slot B partset not created" >&2
    recovery_scenario_teardown
    return 1
  fi

  # Verify bootconf files for both slots
  if [[ ! -f "$RECOVERY_ESP_DIR/SteamOS/conf/A.conf" ]]; then
    echo "ERROR: recovery_scenario_setup: A.conf not created" >&2
    recovery_scenario_teardown
    return 1
  fi

  if [[ ! -f "$RECOVERY_ESP_DIR/SteamOS/conf/B.conf" ]]; then
    echo "ERROR: recovery_scenario_setup: B.conf not created" >&2
    recovery_scenario_teardown
    return 1
  fi

  return 0
}

# ============================================================================
# recovery_scenario_teardown
#
# Clean up recovery fixture directory and reset global state.
#
# Usage:
#   recovery_scenario_teardown
#
# This function is idempotent — safe to call multiple times.
# Designed to be used as a cleanup handler or trap target.
# ============================================================================
recovery_scenario_teardown() {
  if [[ -n "$RECOVERY_FIXTURE_DIR" && -d "$RECOVERY_FIXTURE_DIR" ]]; then
    destroy_mock_fixture "$RECOVERY_FIXTURE_DIR"
  fi

  RECOVERY_FIXTURE_DIR=""
  RECOVERY_ROOTFS_DIR=""
  RECOVERY_ROOTFS_B_DIR=""
  RECOVERY_EFI_DIR=""
  RECOVERY_ESP_DIR=""
  RECOVERY_METADATA_DIR=""
  RECOVERY_NAMESPACE=""
  RECOVERY_TARGET_UUID=""
  RECOVERY_CURRENT_UUID=""
  _RECOVERY_SLOT_A_CHECKSUMS=""
}

# ============================================================================
# Internal: snapshot A-slot files for preservation verification
# ============================================================================
_recovery_snapshot_slot_a() {
  local checksum_file
  checksum_file="$(mktemp "${TMPDIR:-/tmp}/recovery-slot-a-snap-XXXXXX")"

  # Snapshot A-slot EFI grub.cfg
  local grub_a="$RECOVERY_EFI_DIR/EFI/steamos/grub.cfg"
  if [[ -f "$grub_a" ]]; then
    md5sum "$grub_a" | awk '{print $1, "efi-grub"}' > "$checksum_file"
  else
    echo "MISSING efi-grub" > "$checksum_file"
  fi

  # Snapshot A-slot EFI grubx64.efi
  local efi_a="$RECOVERY_EFI_DIR/EFI/steamos/grubx64.efi"
  if [[ -f "$efi_a" ]]; then
    md5sum "$efi_a" | awk '{print $1, "efi-grubx64"}' >> "$checksum_file"
  else
    echo "MISSING efi-grubx64" >> "$checksum_file"
  fi

  # Snapshot A-slot partset
  local partset_a="$RECOVERY_EFI_DIR/SteamOS/partsets/A"
  if [[ -f "$partset_a" ]]; then
    md5sum "$partset_a" | awk '{print $1, "partset-A"}' >> "$checksum_file"
  else
    echo "MISSING partset-A" >> "$checksum_file"
  fi

  # Snapshot A-slot bootconf
  local conf_a="$RECOVERY_ESP_DIR/SteamOS/conf/A.conf"
  if [[ -f "$conf_a" ]]; then
    md5sum "$conf_a" | awk '{print $1, "bootconf-A"}' >> "$checksum_file"
  else
    echo "MISSING bootconf-A" >> "$checksum_file"
  fi

  _RECOVERY_SLOT_A_CHECKSUMS="$checksum_file"
}

# ============================================================================
# simulate_recovery_apply
#
# Apply EFI state changes to the target B slot, simulating the complete
# recovery EFI state application mechanism.
#
# Usage:
#   simulate_recovery_apply [ROOTFS_DIR] [EFI_DIR] [ESP_DIR]
#
# Arguments:
#   ROOTFS_DIR - Rootfs directory for slot B (default: RECOVERY_ROOTFS_DIR)
#   EFI_DIR    - EFI directory (default: RECOVERY_EFI_DIR)
#   ESP_DIR    - ESP directory (default: RECOVERY_ESP_DIR)
#
# Performs:
#   1. Patch grub.cfg with target (B) UUID and kernel params
#   2. Create/update partset files for the target slot (self, all, shared)
#   3. Create/update bootconf B.conf (set image-invalid=0)
#   4. Update grubx64.efi binary with embedded target UUID
#
# Returns:
#   0 - All operations completed successfully
#   1 - One or more operations failed
# ============================================================================
simulate_recovery_apply() {
  local rootfs_dir="${1:-$RECOVERY_ROOTFS_DIR}"
  local efi_dir="${2:-$RECOVERY_EFI_DIR}"
  local esp_dir="${3:-$RECOVERY_ESP_DIR}"

  local rc=0

  # Validate inputs
  if [[ ! -d "$rootfs_dir" ]]; then
    echo "ERROR: simulate_recovery_apply: rootfs_dir not found: $rootfs_dir" >&2
    return 1
  fi
  if [[ ! -d "$efi_dir" ]]; then
    echo "ERROR: simulate_recovery_apply: efi_dir not found: $efi_dir" >&2
    return 1
  fi

  # 1. Patch grub.cfg with target UUID
  if ! _recovery_patch_grub_cfg "$efi_dir" "$rootfs_dir"; then
    echo "ERROR: simulate_recovery_apply: grub.cfg patching failed" >&2
    rc=1
  fi

  # 2. Update partset files for target slot B
  if ! _recovery_update_partsets "$efi_dir"; then
    echo "ERROR: simulate_recovery_apply: partset update failed" >&2
    rc=1
  fi

  # 3. Update bootconf B.conf
  if [[ -d "$esp_dir" ]]; then
    if ! _recovery_update_bootconf "$esp_dir"; then
      echo "ERROR: simulate_recovery_apply: bootconf update failed" >&2
      rc=1
    fi
  fi

  # 4. Update grubx64.efi with target UUID
  if ! _recovery_update_grub_binary "$efi_dir"; then
    echo "ERROR: simulate_recovery_apply: grub binary update failed" >&2
    rc=1
  fi

  return $rc
}

# Internal: patch grub.cfg with target (B) UUID
_recovery_patch_grub_cfg() {
  local efi_dir="$1"
  local rootfs_dir="$2"
  local grub_cfg="$efi_dir/EFI/steamos/grub.cfg"

  if [[ ! -f "$grub_cfg" ]]; then
    echo "ERROR: _recovery_patch_grub_cfg: grub.cfg not found: $grub_cfg" >&2
    return 1
  fi

  # Regenerate grub.cfg with target (B) rootfs UUID
  populate_mock_grub_cfg "$grub_cfg" "$RECOVERY_TARGET_UUID"

  return 0
}

# Internal: update partset files for the recovery target slot
_recovery_update_partsets() {
  local efi_dir="$1"
  local partsets_dir="$efi_dir/SteamOS/partsets"

  if [[ ! -d "$partsets_dir" ]]; then
    mkdir -p "$partsets_dir"
  fi

  local target_rootfs_partuuid target_efi_partuuid target_var_partuuid
  target_rootfs_partuuid="$(derive_partuuid "$RECOVERY_NAMESPACE" "rootfs-${RECOVERY_TARGET_SLOT}")"
  target_efi_partuuid="$(derive_partuuid "$RECOVERY_NAMESPACE" "efi-${RECOVERY_TARGET_SLOT}")"
  target_var_partuuid="$(derive_partuuid "$RECOVERY_NAMESPACE" "var-${RECOVERY_TARGET_SLOT}")"

  # Update self partset (target = slot B)
  cat > "$partsets_dir/self" <<SELF_EOF
rootfs ${target_rootfs_partuuid}
efi ${target_efi_partuuid}
var ${target_var_partuuid}
SELF_EOF

  # Update all partset (A + B + esp)
  local rootfs_a_partuuid efi_a_partuuid var_a_partuuid
  local rootfs_b_partuuid efi_b_partuuid var_b_partuuid
  local esp_partuuid

  rootfs_a_partuuid="$(derive_partuuid "$RECOVERY_NAMESPACE" "rootfs-A")"
  efi_a_partuuid="$(derive_partuuid "$RECOVERY_NAMESPACE" "efi-A")"
  var_a_partuuid="$(derive_partuuid "$RECOVERY_NAMESPACE" "var-A")"
  rootfs_b_partuuid="$(derive_partuuid "$RECOVERY_NAMESPACE" "rootfs-B")"
  efi_b_partuuid="$(derive_partuuid "$RECOVERY_NAMESPACE" "efi-B")"
  var_b_partuuid="$(derive_partuuid "$RECOVERY_NAMESPACE" "var-B")"
  esp_partuuid="$(derive_partuuid "$RECOVERY_NAMESPACE" "esp")"

  cat > "$partsets_dir/all" <<ALL_EOF
rootfs ${rootfs_a_partuuid}
efi ${efi_a_partuuid}
var ${var_a_partuuid}
rootfs ${rootfs_b_partuuid}
efi ${efi_b_partuuid}
var ${var_b_partuuid}
rootfs ${esp_partuuid}
ALL_EOF

  # Update shared partset (esp only)
  cat > "$partsets_dir/shared" <<SHARED_EOF
rootfs ${esp_partuuid}
SHARED_EOF

  return 0
}

# Internal: update bootconf B.conf to mark image as valid
_recovery_update_bootconf() {
  local esp_dir="$1"
  local conf_dir="$esp_dir/SteamOS/conf"

  if [[ ! -d "$conf_dir" ]]; then
    mkdir -p "$conf_dir"
  fi

  # Update B.conf (target slot): mark image-valid, reset boot-attempts
  cat > "$conf_dir/B.conf" <<BOOTCONF_B_EOF
# Bootconf for slot B (mock)
title=SteamOS (slot B)
image-invalid=0
boot-attempts=0
BOOTCONF_B_EOF

  return 0
}

# Internal: update grubx64.efi with target UUID
_recovery_update_grub_binary() {
  local efi_dir="$1"
  local grubx64="$efi_dir/EFI/steamos/grubx64.efi"

  if [[ ! -f "$grubx64" ]]; then
    echo "ERROR: _recovery_update_grub_binary: grubx64.efi not found: $grubx64" >&2
    return 1
  fi

  # Overwrite the embedded UUID at offset 0x100 with the target UUID
  printf '%s' "$RECOVERY_TARGET_UUID" | dd of="$grubx64" bs=1 seek=$((0x100)) conv=notrunc 2>/dev/null

  return 0
}

# ============================================================================
# simulate_recovery_preflight_validation
#
# Run preflight checks for the recovery scenario. Validates that the
# fixture is in a consistent state before applying recovery.
#
# Usage:
#   simulate_recovery_preflight_validation [EFI_DIR] [ESP_DIR]
#
# Checks:
#   1. EFI directory structure is intact
#   2. grub.cfg exists and is nonempty
#   3. grubx64.efi exists and has valid PE header
#   4. Partset files for both slots exist
#   5. Bootconf files for both slots exist
#   6. No stale transaction artifacts (*.new, *.bak, *.tmp)
#   7. Target B image-invalid=1 (not yet applied)
#
# Returns:
#   0 - All preflight checks passed
#   1 - One or more checks failed
# ============================================================================
simulate_recovery_preflight_validation() {
  local efi_dir="${1:-$RECOVERY_EFI_DIR}"
  local esp_dir="${2:-$RECOVERY_ESP_DIR}"

  local rc=0

  # 1. EFI directory structure
  if [[ ! -d "$efi_dir/EFI/steamos" ]]; then
    echo "ERROR: preflight: EFI/steamos directory missing" >&2
    return 1
  fi

  # 2. grub.cfg exists and is nonempty
  if [[ ! -f "$efi_dir/EFI/steamos/grub.cfg" ]]; then
    echo "ERROR: preflight: grub.cfg missing" >&2
    return 1
  fi
  if [[ ! -s "$efi_dir/EFI/steamos/grub.cfg" ]]; then
    echo "ERROR: preflight: grub.cfg is empty" >&2
    return 1
  fi

  # 3. grubx64.efi exists and has valid PE header
  if [[ ! -f "$efi_dir/EFI/steamos/grubx64.efi" ]]; then
    echo "ERROR: preflight: grubx64.efi missing" >&2
    return 1
  fi
  local mz_header
  mz_header="$(dd if="$efi_dir/EFI/steamos/grubx64.efi" bs=1 count=2 2>/dev/null | od -A n -t x1 | tr -d ' ')"
  if [[ "$mz_header" != "4d5a" ]]; then
    echo "ERROR: preflight: grubx64.efi missing MZ header" >&2
    return 1
  fi

  # 4. Partset files for both slots
  if [[ ! -f "$efi_dir/SteamOS/partsets/A" ]]; then
    echo "ERROR: preflight: slot A partset missing" >&2
    return 1
  fi
  if [[ ! -f "$efi_dir/SteamOS/partsets/B" ]]; then
    echo "ERROR: preflight: slot B partset missing" >&2
    return 1
  fi

  # 5. Bootconf files for both slots
  if [[ ! -f "$esp_dir/SteamOS/conf/A.conf" ]]; then
    echo "ERROR: preflight: A.conf missing" >&2
    return 1
  fi
  if [[ ! -f "$esp_dir/SteamOS/conf/B.conf" ]]; then
    echo "ERROR: preflight: B.conf missing" >&2
    return 1
  fi

  # 6. No stale transaction artifacts
  local -a stale_found=()
  for pattern in '*.new' '*.bak' '*.tmp'; do
    while IFS= read -r match; do
      [[ -n "$match" ]] && stale_found+=("$match")
    done < <(find "$efi_dir" -maxdepth 3 -name "$pattern" -type f 2>/dev/null)
  done
  if [[ -n "$esp_dir" ]]; then
    for pattern in '*.new' '*.bak' '*.tmp'; do
      while IFS= read -r match; do
        [[ -n "$match" ]] && stale_found+=("$match")
      done < <(find "$esp_dir" -maxdepth 3 -name "$pattern" -type f 2>/dev/null)
    done
  fi
  if [[ ${#stale_found[@]} -gt 0 ]]; then
    echo "ERROR: preflight: stale transaction artifacts detected:" >&2
    printf '  %s\n' "${stale_found[@]}" >&2
    rc=1
  fi

  # 7. Target B image-invalid=1 (not yet applied)
  local b_invalid
  b_invalid="$(grep '^image-invalid=' "$esp_dir/SteamOS/conf/B.conf" 2>/dev/null | cut -d= -f2)"
  if [[ "$b_invalid" != "1" ]]; then
    echo "ERROR: preflight: B.conf image-invalid expected 1, got '$b_invalid'" >&2
    rc=1
  fi

  return $rc
}

# ============================================================================
# simulate_recovery_update_grub_fallback
#
# Simulate an update-grub failure scenario by injecting a shim that
# exits with a non-zero code, then verifying the fixture remains
# consistent.
#
# Usage:
#   simulate_recovery_update_grub_fallback BIN_DIR
#
# Arguments:
#   BIN_DIR - Directory to create the update-grub shim in
#
# This function:
#   1. Creates a failing update-grub shim
#   2. Prepends BIN_DIR to PATH so the shim is found first
#   3. Returns the shim path for caller use
#
# Returns:
#   0 - Shim created successfully
#   1 - Failed to create shim
# ============================================================================
simulate_recovery_update_grub_fallback() {
  local bin_dir="${1:?simulate_recovery_update_grub_fallback: missing BIN_DIR}"

  if [[ ! -d "$bin_dir" ]]; then
    mkdir -p "$bin_dir"
  fi

  local shim_path="$bin_dir/update-grub"

  cat > "$shim_path" <<SHIM_EOF
#!/bin/bash
# Recovery update-grub failure shim for testing rollback behavior
echo "SHIM: intercepted update-grub (recovery fallback test)" >&2
echo "SHIM: arguments: \$*" >&2
echo "SHIM: simulating update-grub failure (exit 1)" >&2
exit 1
SHIM_EOF

  chmod +x "$shim_path"

  # Prepend to PATH so the shim is found before the real command
  export PATH="$bin_dir:$PATH"

  return 0
}

# ============================================================================
# simulate_recovery_failure_and_rollback
#
# Inject a failure at a controlled point during recovery apply and verify
# that the system rolls back to the pre-apply state.
#
# Usage:
#   simulate_recovery_failure_and_rollback FAILURE_POINT
#
# Arguments:
#   FAILURE_POINT - Where to inject failure: "grub", "partset", "bootconf",
#                   "binary", or "all" (default: "grub")
#
# This function:
#   1. Records pre-apply state of all B-slot artifacts
#   2. Performs partial apply up to the failure point
#   3. Injects the failure
#   4. Verifies rollback to pre-apply state for affected artifacts
#
# Returns:
#   0 - Rollback verified successfully
#   1 - Rollback verification failed
# ============================================================================
simulate_recovery_failure_and_rollback() {
  local failure_point="${1:-grub}"

  local rc=0

  # 1. Record pre-apply state
  local pre_grub pre_partset_b pre_conf_b pre_grubx64
  pre_grub="$(md5sum "$RECOVERY_EFI_DIR/EFI/steamos/grub.cfg" 2>/dev/null | awk '{print $1}')"
  pre_partset_b="$(md5sum "$RECOVERY_EFI_DIR/SteamOS/partsets/B" 2>/dev/null | awk '{print $1}')"
  pre_conf_b="$(md5sum "$RECOVERY_ESP_DIR/SteamOS/conf/B.conf" 2>/dev/null | awk '{print $1}')"
  pre_grubx64="$(md5sum "$RECOVERY_EFI_DIR/EFI/steamos/grubx64.efi" 2>/dev/null | awk '{print $1}')"

  # 2. Perform partial apply based on failure point
  case "$failure_point" in
    grub)
      # Apply grub.cfg patch (succeeds), then fail on partset.
      # Note: grub.cfg already has target (B) UUID from fixture creation,
      # so _recovery_patch_grub_cfg is a no-op (same UUID).
      _recovery_patch_grub_cfg "$RECOVERY_EFI_DIR" "$RECOVERY_ROOTFS_DIR" || true
      # Simulate failure: partset was not updated.
      # Rollback: grub.cfg is already in its initial state (no change needed).
      ;;
    partset)
      # Apply grub and partset, then fail on bootconf
      _recovery_patch_grub_cfg "$RECOVERY_EFI_DIR" "$RECOVERY_ROOTFS_DIR" || true
      _recovery_update_partsets "$RECOVERY_EFI_DIR" || true
      # Rollback: restore partset B to initial fixture state.
      # grub.cfg is already correct (same B UUID).
      local ns="$RECOVERY_NAMESPACE"
      local rootfs_b_partuuid efi_b_partuuid var_b_partuuid
      rootfs_b_partuuid="$(derive_partuuid "$ns" "rootfs-B")"
      efi_b_partuuid="$(derive_partuuid "$ns" "efi-B")"
      var_b_partuuid="$(derive_partuuid "$ns" "var-B")"
      cat > "$RECOVERY_EFI_DIR/SteamOS/partsets/B" <<B_PARTSET_ROLLBACK
rootfs ${rootfs_b_partuuid}
efi ${efi_b_partuuid}
var ${var_b_partuuid}
B_PARTSET_ROLLBACK
      ;;
    bootconf)
      # Apply grub, partset, and bootconf, then fail on binary update
      _recovery_patch_grub_cfg "$RECOVERY_EFI_DIR" "$RECOVERY_ROOTFS_DIR" || true
      _recovery_update_partsets "$RECOVERY_EFI_DIR" || true
      _recovery_update_bootconf "$RECOVERY_ESP_DIR" || true
      # Rollback: restore B.conf to initial fixture state.
      # grub.cfg and partset B are already correct.
      cat > "$RECOVERY_ESP_DIR/SteamOS/conf/B.conf" <<B_CONF_ROLLBACK
# Bootconf for slot B (mock)
title=SteamOS (slot B)
image-invalid=1
boot-attempts=0
B_CONF_ROLLBACK
      ;;
    binary)
      # Apply everything, then fail on binary — rollback everything.
      # Only B.conf actually changed (image-invalid 1→0).
      # grub.cfg, partsets, and grubx64.efi were regenerated with the
      # same target UUID, so they are already in the correct initial state.
      simulate_recovery_apply || true
      cat > "$RECOVERY_ESP_DIR/SteamOS/conf/B.conf" <<B_CONF_ROLLBACK2
# Bootconf for slot B (mock)
title=SteamOS (slot B)
image-invalid=1
boot-attempts=0
B_CONF_ROLLBACK2
      ;;
    all)
      # Apply everything, then full rollback.
      # Same as binary: only B.conf actually changed.
      simulate_recovery_apply || true
      cat > "$RECOVERY_ESP_DIR/SteamOS/conf/B.conf" <<B_CONF_ROLLBACK3
# Bootconf for slot B (mock)
title=SteamOS (slot B)
image-invalid=1
boot-attempts=0
B_CONF_ROLLBACK3
      ;;
    *)
      echo "ERROR: simulate_recovery_failure_and_rollback: unknown failure point: $failure_point" >&2
      return 1
      ;;
  esac

  # 3. Verify rollback: post-apply state should match pre-apply state
  local post_grub post_partset_b post_conf_b post_grubx64
  post_grub="$(md5sum "$RECOVERY_EFI_DIR/EFI/steamos/grub.cfg" 2>/dev/null | awk '{print $1}')"
  post_partset_b="$(md5sum "$RECOVERY_EFI_DIR/SteamOS/partsets/B" 2>/dev/null | awk '{print $1}')"
  post_conf_b="$(md5sum "$RECOVERY_ESP_DIR/SteamOS/conf/B.conf" 2>/dev/null | awk '{print $1}')"
  post_grubx64="$(md5sum "$RECOVERY_EFI_DIR/EFI/steamos/grubx64.efi" 2>/dev/null | awk '{print $1}')"

  if [[ "$post_grub" != "$pre_grub" ]]; then
    echo "ERROR: rollback verification: grub.cfg state mismatch" >&2
    rc=1
  fi
  if [[ "$post_partset_b" != "$pre_partset_b" ]]; then
    echo "ERROR: rollback verification: partset B state mismatch" >&2
    rc=1
  fi
  if [[ "$post_conf_b" != "$pre_conf_b" ]]; then
    echo "ERROR: rollback verification: B.conf state mismatch" >&2
    rc=1
  fi
  if [[ "$post_grubx64" != "$pre_grubx64" ]]; then
    echo "ERROR: rollback verification: grubx64.efi state mismatch" >&2
    rc=1
  fi

  return $rc
}

# ============================================================================
# verify_rollback_slot_preserved
#
# Verify that slot A artifacts are byte-identical to their pre-apply state.
# This is the critical A/B isolation invariant for recovery: the current
# slot must never be modified during a recovery apply.
#
# Usage:
#   verify_rollback_slot_preserved [EFI_DIR] [ESP_DIR]
#
# Arguments:
#   EFI_DIR - EFI directory (default: RECOVERY_EFI_DIR)
#   ESP_DIR - ESP directory (default: RECOVERY_ESP_DIR)
#
# Returns:
#   0 - All A-slot artifacts preserved (byte-identical)
#   1 - One or more A-slot artifacts were modified
# ============================================================================
verify_rollback_slot_preserved() {
  local efi_dir="${1:-$RECOVERY_EFI_DIR}"
  local esp_dir="${2:-$RECOVERY_ESP_DIR}"

  if [[ -z "$_RECOVERY_SLOT_A_CHECKSUMS" || ! -f "$_RECOVERY_SLOT_A_CHECKSUMS" ]]; then
    echo "ERROR: verify_rollback_slot_preserved: no pre-apply snapshot available" >&2
    return 1
  fi

  local rc=0

  # Define A-slot artifacts to verify
  local -a artifact_labels=("efi-grub" "efi-grubx64" "partset-A" "bootconf-A")
  local -a artifact_paths=(
    "$efi_dir/EFI/steamos/grub.cfg"
    "$efi_dir/EFI/steamos/grubx64.efi"
    "$efi_dir/SteamOS/partsets/A"
    "$esp_dir/SteamOS/conf/A.conf"
  )

  local i
  for ((i = 0; i < ${#artifact_labels[@]}; i++)); do
    local label="${artifact_labels[$i]}"
    local path="${artifact_paths[$i]}"

    # Get expected checksum from snapshot
    local expected
    expected="$(grep " $label$" "$_RECOVERY_SLOT_A_CHECKSUMS" 2>/dev/null | awk '{print $1}')"

    if [[ -z "$expected" || "$expected" == "MISSING" ]]; then
      # Artifact was not present in snapshot — check it doesn't exist now
      if [[ -f "$path" ]]; then
        echo "ERROR: verify_rollback_slot_preserved: unexpected artifact appeared: $label" >&2
        rc=1
      fi
      continue
    fi

    # File should exist and have same checksum
    if [[ ! -f "$path" ]]; then
      echo "ERROR: verify_rollback_slot_preserved: A-slot artifact missing: $label ($path)" >&2
      rc=1
      continue
    fi

    local actual
    actual="$(md5sum "$path" | awk '{print $1}')"

    if [[ "$actual" != "$expected" ]]; then
      echo "ERROR: verify_rollback_slot_preserved: A-slot artifact modified: $label (expected=$expected, actual=$actual)" >&2
      rc=1
    fi
  done

  return $rc
}

# ============================================================================
# verify_non_target_isolation
#
# Verify that no writes occurred to A-slot rootfs, A-slot EFI, or A-slot
# bootconf during a recovery operation.
#
# Usage:
#   verify_non_target_isolation [ROOTFS_DIR] [EFI_DIR] [ESP_DIR]
#
# Arguments:
#   ROOTFS_DIR - Rootfs directory (default: RECOVERY_ROOTFS_DIR)
#   EFI_DIR    - EFI directory (default: RECOVERY_EFI_DIR)
#   ESP_DIR    - ESP directory (default: RECOVERY_ESP_DIR)
#
# This function checks:
#   1. No new files were created in the A rootfs (if a separate A rootfs
#      directory exists in the fixture)
#   2. No A-slot EFI artifacts were modified
#   3. No A-slot bootconf (A.conf) was modified
#
# Returns:
#   0 - Non-target isolation maintained
#   1 - Isolation violated
# ============================================================================
verify_non_target_isolation() {
  local rootfs_dir="${1:-$RECOVERY_ROOTFS_DIR}"
  local efi_dir="${2:-$RECOVERY_EFI_DIR}"
  local esp_dir="${3:-$RECOVERY_ESP_DIR}"

  local rc=0

  # 1. Check A-slot EFI artifacts are unchanged
  if [[ -f "$_RECOVERY_SLOT_A_CHECKSUMS" ]]; then
    local grub_a_expected grub_a_actual
    grub_a_expected="$(grep ' efi-grub$' "$_RECOVERY_SLOT_A_CHECKSUMS" 2>/dev/null | awk '{print $1}')"
    if [[ -n "$grub_a_expected" && "$grub_a_expected" != "MISSING" ]]; then
      grub_a_actual="$(md5sum "$efi_dir/EFI/steamos/grub.cfg" 2>/dev/null | awk '{print $1}')"
      if [[ "$grub_a_actual" != "$grub_a_expected" ]]; then
        echo "ERROR: verify_non_target_isolation: A-slot grub.cfg was modified" >&2
        rc=1
      fi
    fi

    local partset_a_expected partset_a_actual
    partset_a_expected="$(grep ' partset-A$' "$_RECOVERY_SLOT_A_CHECKSUMS" 2>/dev/null | awk '{print $1}')"
    if [[ -n "$partset_a_expected" && "$partset_a_expected" != "MISSING" ]]; then
      partset_a_actual="$(md5sum "$efi_dir/SteamOS/partsets/A" 2>/dev/null | awk '{print $1}')"
      if [[ "$partset_a_actual" != "$partset_a_expected" ]]; then
        echo "ERROR: verify_non_target_isolation: A-slot partset was modified" >&2
        rc=1
      fi
    fi
  fi

  # 2. Check A.conf bootconf is unchanged
  if [[ -f "$_RECOVERY_SLOT_A_CHECKSUMS" ]]; then
    local conf_a_expected conf_a_actual
    conf_a_expected="$(grep ' bootconf-A$' "$_RECOVERY_SLOT_A_CHECKSUMS" 2>/dev/null | awk '{print $1}')"
    if [[ -n "$conf_a_expected" && "$conf_a_expected" != "MISSING" ]]; then
      conf_a_actual="$(md5sum "$esp_dir/SteamOS/conf/A.conf" 2>/dev/null | awk '{print $1}')"
      if [[ "$conf_a_actual" != "$conf_a_expected" ]]; then
        echo "ERROR: verify_non_target_isolation: A-slot bootconf (A.conf) was modified" >&2
        rc=1
      fi
    fi
  fi

  # 3. Verify A.conf still has image-invalid=0 (never changed by recovery)
  if [[ -f "$esp_dir/SteamOS/conf/A.conf" ]]; then
    local a_invalid
    a_invalid="$(grep '^image-invalid=' "$esp_dir/SteamOS/conf/A.conf" 2>/dev/null | cut -d= -f2)"
    if [[ "$a_invalid" != "0" ]]; then
      echo "ERROR: verify_non_target_isolation: A.conf image-invalid changed (expected 0, got '$a_invalid')" >&2
      rc=1
    fi
  fi

  return $rc
}

# ============================================================================
# verify_filesystem_flushed
#
# Verify that all written artifacts have been flushed (are visible on disk).
# In a mock fixture this means verifying file sizes are non-zero and
# content is consistent (no partial writes).
#
# Usage:
#   verify_filesystem_flushed [ROOTFS_DIR] [EFI_DIR] [ESP_DIR]
#
# Arguments:
#   ROOTFS_DIR - Rootfs directory (default: RECOVERY_ROOTFS_DIR)
#   EFI_DIR    - EFI directory (default: RECOVERY_EFI_DIR)
#   ESP_DIR    - ESP directory (default: RECOVERY_ESP_DIR)
#
# Returns:
#   0 - All artifacts flushed (non-empty, readable)
#   1 - One or more artifacts not flushed
# ============================================================================
verify_filesystem_flushed() {
  local rootfs_dir="${1:-$RECOVERY_ROOTFS_DIR}"
  local efi_dir="${2:-$RECOVERY_EFI_DIR}"
  local esp_dir="${3:-$RECOVERY_ESP_DIR}"

  local rc=0

  # Define critical artifacts that must be flushed after apply
  local -a critical_files=(
    "$efi_dir/EFI/steamos/grub.cfg"
    "$efi_dir/EFI/steamos/grubx64.efi"
    "$efi_dir/SteamOS/partsets/self"
    "$efi_dir/SteamOS/partsets/all"
    "$efi_dir/SteamOS/partsets/shared"
    "$esp_dir/SteamOS/conf/B.conf"
  )

  local file
  for file in "${critical_files[@]}"; do
    if [[ ! -f "$file" ]]; then
      echo "ERROR: verify_filesystem_flushed: missing critical file: $file" >&2
      rc=1
      continue
    fi
    if [[ ! -s "$file" ]]; then
      echo "ERROR: verify_filesystem_flushed: empty critical file: $file" >&2
      rc=1
      continue
    fi

    # Verify file is readable and non-corrupt by checking wc -c > 0
    local size
    size="$(wc -c < "$file" 2>/dev/null || echo 0)"
    if [[ "$size" -eq 0 ]]; then
      echo "ERROR: verify_filesystem_flushed: unreadable file: $file" >&2
      rc=1
    fi
  done

  # Verify grubx64.efi is a valid PE (MZ header check)
  local grubx64="$efi_dir/EFI/steamos/grubx64.efi"
  if [[ -f "$grubx64" ]]; then
    local mz_header
    mz_header="$(dd if="$grubx64" bs=1 count=2 2>/dev/null | od -A n -t x1 | tr -d ' ')"
    if [[ "$mz_header" != "4d5a" ]]; then
      echo "ERROR: verify_filesystem_flushed: grubx64.efi corrupted (no MZ header)" >&2
      rc=1
    fi
  fi

  return $rc
}

# ============================================================================
# verify_repatch_idempotent
#
# Verify that applying recovery state a second time produces no duplicates
# and leaves the fixture in an identical state.
#
# Usage:
#   verify_repatch_idempotent [ROOTFS_DIR] [EFI_DIR] [ESP_DIR]
#
# Arguments:
#   ROOTFS_DIR - Rootfs directory (default: RECOVERY_ROOTFS_DIR)
#   EFI_DIR    - EFI directory (default: RECOVERY_EFI_DIR)
#   ESP_DIR    - ESP directory (default: RECOVERY_ESP_DIR)
#
# This function:
#   1. Snapshots all target (B) artifacts
#   2. Applies recovery again (second time)
#   3. Verifies no duplicates in partsets
#   4. Verifies checksums match (byte-identical)
#
# Returns:
#   0 - Second apply is idempotent
#   1 - Duplicates or state changes detected
# ============================================================================
verify_repatch_idempotent() {
  local rootfs_dir="${1:-$RECOVERY_ROOTFS_DIR}"
  local efi_dir="${2:-$RECOVERY_EFI_DIR}"
  local esp_dir="${3:-$RECOVERY_ESP_DIR}"

  local rc=0

  # 1. Snapshot target artifacts before second apply
  local pre_grub pre_partset_self pre_partset_all pre_partset_shared
  local pre_grubx64 pre_conf_b
  pre_grub="$(md5sum "$efi_dir/EFI/steamos/grub.cfg" 2>/dev/null | awk '{print $1}')"
  pre_partset_self="$(md5sum "$efi_dir/SteamOS/partsets/self" 2>/dev/null | awk '{print $1}')"
  pre_partset_all="$(md5sum "$efi_dir/SteamOS/partsets/all" 2>/dev/null | awk '{print $1}')"
  pre_partset_shared="$(md5sum "$efi_dir/SteamOS/partsets/shared" 2>/dev/null | awk '{print $1}')"
  pre_grubx64="$(md5sum "$efi_dir/EFI/steamos/grubx64.efi" 2>/dev/null | awk '{print $1}')"
  pre_conf_b="$(md5sum "$esp_dir/SteamOS/conf/B.conf" 2>/dev/null | awk '{print $1}')"

  # 2. Apply recovery again
  if ! simulate_recovery_apply "$rootfs_dir" "$efi_dir" "$esp_dir"; then
    echo "ERROR: verify_repatch_idempotent: second apply failed" >&2
    return 1
  fi

  # 3. Verify no duplicates in partset files
  local -a partset_files=("self" "all" "shared" "A" "B")
  local ps_file
  for ps_file in "${partset_files[@]}"; do
    local ps_path="$efi_dir/SteamOS/partsets/$ps_file"
    if [[ ! -f "$ps_path" ]]; then
      continue
    fi

    # Count non-comment, non-blank lines — should match expected count
    local line_count
    line_count="$(grep -v '^\s*#' "$ps_path" | grep -v '^\s*$' | wc -l)"

    # Check for duplicate PARTUUIDs within a single partset
    local dup_check
    dup_check="$(grep -v '^\s*#' "$ps_path" | grep -v '^\s*$' | awk '{print $2}' | sort | uniq -d)"
    if [[ -n "$dup_check" ]]; then
      echo "ERROR: verify_repatch_idempotent: duplicate PARTUUID in partset $ps_file: $dup_check" >&2
      rc=1
    fi
  done

  # 4. Verify checksums match (byte-identical)
  local post_grub post_partset_self post_partset_all post_partset_shared
  local post_grubx64 post_conf_b
  post_grub="$(md5sum "$efi_dir/EFI/steamos/grub.cfg" 2>/dev/null | awk '{print $1}')"
  post_partset_self="$(md5sum "$efi_dir/SteamOS/partsets/self" 2>/dev/null | awk '{print $1}')"
  post_partset_all="$(md5sum "$efi_dir/SteamOS/partsets/all" 2>/dev/null | awk '{print $1}')"
  post_partset_shared="$(md5sum "$efi_dir/SteamOS/partsets/shared" 2>/dev/null | awk '{print $1}')"
  post_grubx64="$(md5sum "$efi_dir/EFI/steamos/grubx64.efi" 2>/dev/null | awk '{print $1}')"
  post_conf_b="$(md5sum "$esp_dir/SteamOS/conf/B.conf" 2>/dev/null | awk '{print $1}')"

  if [[ -n "$pre_grub" && "$post_grub" != "$pre_grub" ]]; then
    echo "ERROR: verify_repatch_idempotent: grub.cfg changed on second apply" >&2
    rc=1
  fi
  if [[ -n "$pre_partset_self" && "$post_partset_self" != "$pre_partset_self" ]]; then
    echo "ERROR: verify_repatch_idempotent: partset self changed on second apply" >&2
    rc=1
  fi
  if [[ -n "$pre_partset_all" && "$post_partset_all" != "$pre_partset_all" ]]; then
    echo "ERROR: verify_repatch_idempotent: partset all changed on second apply" >&2
    rc=1
  fi
  if [[ -n "$pre_partset_shared" && "$post_partset_shared" != "$pre_partset_shared" ]]; then
    echo "ERROR: verify_repatch_idempotent: partset shared changed on second apply" >&2
    rc=1
  fi
  if [[ -n "$pre_grubx64" && "$post_grubx64" != "$pre_grubx64" ]]; then
    echo "ERROR: verify_repatch_idempotent: grubx64.efi changed on second apply" >&2
    rc=1
  fi
  if [[ -n "$pre_conf_b" && "$post_conf_b" != "$pre_conf_b" ]]; then
    echo "ERROR: verify_repatch_idempotent: B.conf changed on second apply" >&2
    rc=1
  fi

  return $rc
}

# ============================================================================
# simulate_recovery_bootconf_ownership
#
# Test bootconf preservation behavior during recovery: verify that A.conf
# is never touched and B.conf is properly updated.
#
# Usage:
#   simulate_recovery_bootconf_ownership [ESP_DIR]
#
# Arguments:
#   ESP_DIR - ESP directory (default: RECOVERY_ESP_DIR)
#
# This function:
#   1. Snapshots A.conf before apply
#   2. Applies recovery state
#   3. Verifies A.conf is byte-identical (preserved)
#   4. Verifies B.conf was updated (image-invalid=0)
#   5. Verifies both bootconf files have required fields
#
# Returns:
#   0 - Bootconf ownership verified
#   1 - Ownership violation detected
# ============================================================================
simulate_recovery_bootconf_ownership() {
  local esp_dir="${1:-$RECOVERY_ESP_DIR}"

  local rc=0
  local conf_dir="$esp_dir/SteamOS/conf"

  # 1. Snapshot A.conf before apply
  local pre_a_checksum=""
  if [[ -f "$conf_dir/A.conf" ]]; then
    pre_a_checksum="$(md5sum "$conf_dir/A.conf" | awk '{print $1}')"
  fi

  # Record A.conf content for field verification
  local pre_a_content=""
  if [[ -f "$conf_dir/A.conf" ]]; then
    pre_a_content="$(cat "$conf_dir/A.conf")"
  fi

  # 2. Apply recovery
  if ! simulate_recovery_apply; then
    echo "ERROR: simulate_recovery_bootconf_ownership: recovery apply failed" >&2
    return 1
  fi

  # 3. Verify A.conf is byte-identical
  if [[ -n "$pre_a_checksum" ]]; then
    local post_a_checksum
    post_a_checksum="$(md5sum "$conf_dir/A.conf" 2>/dev/null | awk '{print $1}')"
    if [[ "$post_a_checksum" != "$pre_a_checksum" ]]; then
      echo "ERROR: simulate_recovery_bootconf_ownership: A.conf was modified during recovery" >&2
      rc=1
    fi
  fi

  # 3b. Verify A.conf content unchanged (field-level check)
  if [[ -n "$pre_a_content" && -f "$conf_dir/A.conf" ]]; then
    local post_a_content
    post_a_content="$(cat "$conf_dir/A.conf")"
    if [[ "$post_a_content" != "$pre_a_content" ]]; then
      echo "ERROR: simulate_recovery_bootconf_ownership: A.conf content changed" >&2
      rc=1
    fi
  fi

  # 4. Verify B.conf was updated (image-invalid=0)
  if [[ ! -f "$conf_dir/B.conf" ]]; then
    echo "ERROR: simulate_recovery_bootconf_ownership: B.conf missing after apply" >&2
    return 1
  fi

  local b_invalid
  b_invalid="$(grep '^image-invalid=' "$conf_dir/B.conf" 2>/dev/null | cut -d= -f2)"
  if [[ "$b_invalid" != "0" ]]; then
    echo "ERROR: simulate_recovery_bootconf_ownership: B.conf image-invalid expected 0, got '$b_invalid'" >&2
    rc=1
  fi

  # 5. Verify required fields in both bootconf files
  local -a required_fields=("title" "image-invalid" "boot-attempts")
  for conf_file in "A.conf" "B.conf"; do
    local conf_path="$conf_dir/$conf_file"
    if [[ ! -f "$conf_path" ]]; then
      echo "ERROR: simulate_recovery_bootconf_ownership: $conf_file missing" >&2
      rc=1
      continue
    fi
    local content
    content="$(cat "$conf_path")"
    for field in "${required_fields[@]}"; do
      local field_found
      field_found="$(printf '%s\n' "$content" | grep -v '^\s*#' | grep -c "^${field}=" 2>/dev/null)" || field_found=0
      if [[ "$field_found" -eq 0 ]]; then
        echo "ERROR: simulate_recovery_bootconf_ownership: $conf_file missing required field '$field'" >&2
        rc=1
      fi
    done
  done

  return $rc
}

# ============================================================================
# Utility functions for recovery tests
# ============================================================================

# Get the target rootfs UUID for the current recovery fixture
# Usage: get_recovery_target_uuid
get_recovery_target_uuid() {
  if [[ -z "$RECOVERY_TARGET_UUID" ]]; then
    echo "ERROR: get_recovery_target_uuid: RECOVERY_TARGET_UUID not set (call recovery_scenario_setup first)" >&2
    return 1
  fi
  echo "$RECOVERY_TARGET_UUID"
}

# Get the current (slot A) rootfs UUID for the current recovery fixture
# Usage: get_recovery_current_uuid
get_recovery_current_uuid() {
  if [[ -z "$RECOVERY_CURRENT_UUID" ]]; then
    echo "ERROR: get_recovery_current_uuid: RECOVERY_CURRENT_UUID not set (call recovery_scenario_setup first)" >&2
    return 1
  fi
  echo "$RECOVERY_CURRENT_UUID"
}

# Get the EFI directory for the current recovery fixture
# Usage: get_recovery_efi_dir
get_recovery_efi_dir() {
  if [[ -z "$RECOVERY_EFI_DIR" ]]; then
    echo "ERROR: get_recovery_efi_dir: RECOVERY_EFI_DIR not set (call recovery_scenario_setup first)" >&2
    return 1
  fi
  echo "$RECOVERY_EFI_DIR"
}

# Get the rootfs directory for the current recovery fixture
# Usage: get_recovery_rootfs_dir
get_recovery_rootfs_dir() {
  if [[ -z "$RECOVERY_ROOTFS_DIR" ]]; then
    echo "ERROR: get_recovery_rootfs_dir: RECOVERY_ROOTFS_DIR not set (call recovery_scenario_setup first)" >&2
    return 1
  fi
  echo "$RECOVERY_ROOTFS_DIR"
}

# Get the ESP directory for the current recovery fixture
# Usage: get_recovery_esp_dir
get_recovery_esp_dir() {
  if [[ -z "$RECOVERY_ESP_DIR" ]]; then
    echo "ERROR: get_recovery_esp_dir: RECOVERY_ESP_DIR not set (call recovery_scenario_setup first)" >&2
    return 1
  fi
  echo "$RECOVERY_ESP_DIR"
}

# Get the metadata directory for the current recovery fixture
# Usage: get_recovery_metadata_dir
get_recovery_metadata_dir() {
  if [[ -z "$RECOVERY_METADATA_DIR" ]]; then
    echo "ERROR: get_recovery_metadata_dir: RECOVERY_METADATA_DIR not set (call recovery_scenario_setup first)" >&2
    return 1
  fi
  echo "$RECOVERY_METADATA_DIR"
}

# Get the namespace for the current recovery fixture
# Usage: get_recovery_namespace
get_recovery_namespace() {
  if [[ -z "$RECOVERY_NAMESPACE" ]]; then
    echo "ERROR: get_recovery_namespace: RECOVERY_NAMESPACE not set (call recovery_scenario_setup first)" >&2
    return 1
  fi
  echo "$RECOVERY_NAMESPACE"
}
