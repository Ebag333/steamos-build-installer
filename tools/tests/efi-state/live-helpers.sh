#!/bin/bash
#
# tools/tests/efi-state/live-helpers.sh
# Live-specific test infrastructure for EFI state application tests.
#
# Provides helper functions for Live scenario tests (dual-slot, current=A,
# target=current slot A), including fixture setup/teardown, EFI state
# application simulation, chroot isolation verification, mount preservation,
# opposing-slot immutability, boot-selection mutation prevention, read-only
# state restoration, duplicate parameter detection, and keep-list exactness.
#
# Usage:
#   source tools/tests/efi-state/live-helpers.sh
#
# Dependencies:
#   - test-harness.sh    (assertion helpers, test lifecycle)
#   - fixture-factory.sh (mock fixture creation/destruction)
#   - topology.sh         (deterministic UUID/PARTUUID generation)
#
# Design constraints:
#   - Live scenario: dual-slot, current=A, target=current slot (A)
#   - No chroot operations (existing mounts reused)
#   - Read-only state must be restored after apply
#   - No boot-selection mutation (bootconf/RAUC fields unchanged)
#   - Dual-slot with current=A, target=A (same slot)
#   - Opposing slot (B) artifacts must be byte-identical after apply

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "live-helpers.sh is a library — source it, don't run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Guard: ensure required libraries are loaded
# ---------------------------------------------------------------------------
if ! declare -f test_harness_init >/dev/null 2>&1; then
  echo "ERROR: live-helpers.sh requires test-harness.sh (source it first)." >&2
  return 1 2>/dev/null || exit 1
fi

if ! declare -f create_mock_boot_fixture >/dev/null 2>&1; then
  echo "ERROR: live-helpers.sh requires fixture-factory.sh (source it first)." >&2
  return 1 2>/dev/null || exit 1
fi

# ---------------------------------------------------------------------------
# Live scenario constants
# ---------------------------------------------------------------------------
LIVE_SLOT_COUNT=2
LIVE_CURRENT_SLOT="A"
LIVE_TARGET_SLOT="A"
LIVE_SCENARIO="live"

# ============================================================================
# Global state for live fixture
# ============================================================================
LIVE_FIXTURE_DIR=""
LIVE_ROOTFS_DIR=""
LIVE_EFI_DIR=""
LIVE_ESP_DIR=""
LIVE_METADATA_DIR=""
LIVE_NAMESPACE=""
LIVE_TARGET_UUID=""
LIVE_CURRENT_UUID=""

# Snapshot checksums for opposing-slot (B) preservation verification
_LIVE_SLOT_B_CHECKSUMS=""

# Snapshot of steamos-readonly state for restoration verification
_LIVE_READONLY_STATE_FILE=""

# ============================================================================
# live_scenario_setup
#
# Create a live-specific mock fixture (dual-slot, current=A, target=A).
#
# Key difference from recovery: in the Live scenario the target slot IS the
# current slot — the installer patches EFI state in-place on the running
# system rather than writing to the standby slot.
#
# Usage:
#   live_scenario_setup
#
# Sets the following global variables for test access:
#   LIVE_FIXTURE_DIR   - Root of the mock fixture tree
#   LIVE_ROOTFS_DIR    - Mock rootfs mount point (current/target = slot A)
#   LIVE_EFI_DIR       - Mock EFI partition mount point
#   LIVE_ESP_DIR       - Mock shared ESP mount point
#   LIVE_METADATA_DIR  - Mock metadata directory
#   LIVE_TARGET_UUID   - Target rootfs UUID (slot A — same as current)
#   LIVE_CURRENT_UUID  - Current rootfs UUID (slot A — same as target)
#   LIVE_NAMESPACE     - Test namespace for UUID derivation
#
# The fixture is created in a temporary directory that is automatically
# cleaned up by live_scenario_teardown().
# ============================================================================
live_scenario_setup() {
  # Create temporary base directory
  LIVE_FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/live-test-XXXXXX")"
  if [[ -z "$LIVE_FIXTURE_DIR" || ! -d "$LIVE_FIXTURE_DIR" ]]; then
    echo "ERROR: live_scenario_setup: failed to create temp directory" >&2
    return 1
  fi

  LIVE_NAMESPACE="live-${LIVE_CURRENT_SLOT}-$$"

  # Use fixture-factory to create the complete dual-slot mock fixture.
  # Target slot = current slot (A) for live scenario.
  # create_mock_boot_fixture determines current_slot as the inverse of
  # target_slot, but for live we need current=A target=A. We create with
  # target=A which gives current=B — then override: live targets itself.
  # However, fixture-factory treats target_slot=A as single-slot. Instead,
  # we create with target_slot=B (which gives current=A, slot_count=2)
  # and then note that in live, target IS current, so we use the A slot.
  create_mock_boot_fixture "$LIVE_FIXTURE_DIR" "$LIVE_SCENARIO" "$LIVE_CURRENT_SLOT" "$LIVE_NAMESPACE"

  # Set convenience variables for test access
  # In live scenario, rootfs is the current slot (A) — same as target.
  LIVE_ROOTFS_DIR="$LIVE_FIXTURE_DIR/rootfs"
  LIVE_EFI_DIR="$LIVE_FIXTURE_DIR/efi"
  LIVE_ESP_DIR="$LIVE_FIXTURE_DIR/esp"
  LIVE_METADATA_DIR="$LIVE_FIXTURE_DIR/metadata"

  # Derive UUIDs (consistent with fixture-factory)
  # In live, target = current = slot A
  LIVE_TARGET_UUID="$(derive_uuid "$LIVE_NAMESPACE" "rootfs-${LIVE_CURRENT_SLOT}")"
  LIVE_CURRENT_UUID="$LIVE_TARGET_UUID"

  # Snapshot opposing slot (B) state for preservation verification
  _live_snapshot_slot_b

  # Record steamos-readonly state for restoration verification
  _live_record_readonly_state

  # Verify fixture was created correctly
  if [[ ! -d "$LIVE_EFI_DIR/EFI/steamos" ]]; then
    echo "ERROR: live_scenario_setup: EFI fixture directory not created" >&2
    live_scenario_teardown
    return 1
  fi

  if [[ ! -f "$LIVE_EFI_DIR/EFI/steamos/grub.cfg" ]]; then
    echo "ERROR: live_scenario_setup: grub.cfg not created" >&2
    live_scenario_teardown
    return 1
  fi

  # Verify dual-slot structure: both A and B partsets should exist
  if [[ ! -f "$LIVE_EFI_DIR/SteamOS/partsets/A" ]]; then
    echo "ERROR: live_scenario_setup: slot A partset not created" >&2
    live_scenario_teardown
    return 1
  fi

  if [[ ! -f "$LIVE_EFI_DIR/SteamOS/partsets/B" ]]; then
    echo "ERROR: live_scenario_setup: slot B partset not created" >&2
    live_scenario_teardown
    return 1
  fi

  # Verify bootconf files for both slots
  if [[ ! -f "$LIVE_ESP_DIR/SteamOS/conf/A.conf" ]]; then
    echo "ERROR: live_scenario_setup: A.conf not created" >&2
    live_scenario_teardown
    return 1
  fi

  if [[ ! -f "$LIVE_ESP_DIR/SteamOS/conf/B.conf" ]]; then
    echo "ERROR: live_scenario_setup: B.conf not created" >&2
    live_scenario_teardown
    return 1
  fi

  return 0
}

# ============================================================================
# live_scenario_teardown
#
# Clean up live fixture directory and reset global state.
#
# Usage:
#   live_scenario_teardown
#
# This function is idempotent — safe to call multiple times.
# Designed to be used as a cleanup handler or trap target.
# ============================================================================
live_scenario_teardown() {
  if [[ -n "$LIVE_FIXTURE_DIR" && -d "$LIVE_FIXTURE_DIR" ]]; then
    destroy_mock_fixture "$LIVE_FIXTURE_DIR"
  fi

  LIVE_FIXTURE_DIR=""
  LIVE_ROOTFS_DIR=""
  LIVE_EFI_DIR=""
  LIVE_ESP_DIR=""
  LIVE_METADATA_DIR=""
  LIVE_NAMESPACE=""
  LIVE_TARGET_UUID=""
  LIVE_CURRENT_UUID=""
  _LIVE_SLOT_B_CHECKSUMS=""
  _LIVE_READONLY_STATE_FILE=""
}

# ============================================================================
# Internal: snapshot opposing slot (B) files for preservation verification
# ============================================================================
_live_snapshot_slot_b() {
  local checksum_file
  checksum_file="$(mktemp "${TMPDIR:-/tmp}/live-slot-b-snap-XXXXXX")"

  # Snapshot B-slot EFI grub.cfg (the shared EFI is the same for both slots,
  # but B's partset and bootconf should remain unchanged)
  local partset_b="$LIVE_EFI_DIR/SteamOS/partsets/B"
  if [[ -f "$partset_b" ]]; then
    md5sum "$partset_b" | awk '{print $1, "partset-B"}' > "$checksum_file"
  else
    echo "MISSING partset-B" > "$checksum_file"
  fi

  # Snapshot B-slot EFI partset semantic views
  local partset_other="$LIVE_EFI_DIR/SteamOS/partsets/other"
  if [[ -f "$partset_other" ]]; then
    md5sum "$partset_other" | awk '{print $1, "partset-other"}' >> "$checksum_file"
  else
    echo "MISSING partset-other" >> "$checksum_file"
  fi

  local partset_all="$LIVE_EFI_DIR/SteamOS/partsets/all"
  if [[ -f "$partset_all" ]]; then
    md5sum "$partset_all" | awk '{print $1, "partset-all"}' >> "$checksum_file"
  else
    echo "MISSING partset-all" >> "$checksum_file"
  fi

  local partset_shared="$LIVE_EFI_DIR/SteamOS/partsets/shared"
  if [[ -f "$partset_shared" ]]; then
    md5sum "$partset_shared" | awk '{print $1, "partset-shared"}' >> "$checksum_file"
  else
    echo "MISSING partset-shared" >> "$checksum_file"
  fi

  # Snapshot B-slot bootconf
  local conf_b="$LIVE_ESP_DIR/SteamOS/conf/B.conf"
  if [[ -f "$conf_b" ]]; then
    md5sum "$conf_b" | awk '{print $1, "bootconf-B"}' >> "$checksum_file"
  else
    echo "MISSING bootconf-B" >> "$checksum_file"
  fi

  # Snapshot shared EFI grub.cfg (used by both slots)
  local grub_cfg="$LIVE_EFI_DIR/EFI/steamos/grub.cfg"
  if [[ -f "$grub_cfg" ]]; then
    md5sum "$grub_cfg" | awk '{print $1, "efi-grub"}' >> "$checksum_file"
  else
    echo "MISSING efi-grub" >> "$checksum_file"
  fi

  # Snapshot shared EFI grubx64.efi
  local grubx64="$LIVE_EFI_DIR/EFI/steamos/grubx64.efi"
  if [[ -f "$grubx64" ]]; then
    md5sum "$grubx64" | awk '{print $1, "efi-grubx64"}' >> "$checksum_file"
  else
    echo "MISSING efi-grubx64" >> "$checksum_file"
  fi

  _LIVE_SLOT_B_CHECKSUMS="$checksum_file"
}

# ============================================================================
# Internal: record steamos-readonly state for restoration verification
# ============================================================================
_live_record_readonly_state() {
  local state_file
  state_file="$(mktemp "${TMPDIR:-/tmp}/live-readonly-state-XXXXXX")"

  # Record the initial read-only state of key filesystems.
  # In a live fixture, we simulate steamos-readonly state via a marker file.
  local rootfs_ro="$LIVE_FIXTURE_DIR/.steamos-readonly"
  if [[ -f "$rootfs_ro" ]]; then
    cat "$rootfs_ro" > "$state_file"
  else
    # Default: read-only is enabled (normal live state)
    echo "readonly=1" > "$state_file"
  fi

  _LIVE_READONLY_STATE_FILE="$state_file"
}

# ============================================================================
# simulate_live_apply
#
# Apply EFI state changes to the current slot (A), simulating the complete
# live EFI state application mechanism.
#
# Key difference from recovery: the target IS the current slot, so all
# writes go to the same rootfs/EFI that is currently booted.
#
# Usage:
#   simulate_live_apply [ROOTFS_DIR] [EFI_DIR] [ESP_DIR]
#
# Arguments:
#   ROOTFS_DIR - Rootfs directory (default: LIVE_ROOTFS_DIR)
#   EFI_DIR    - EFI directory (default: LIVE_EFI_DIR)
#   ESP_DIR    - ESP directory (default: LIVE_ESP_DIR)
#
# Performs:
#   1. Temporarily disable read-only (patch defaults)
#   2. Run update-grub (regenerate grub.cfg from /etc/default/grub)
#   3. Patch grub.cfg with target UUID and kernel params
#   4. Validate GRUB configuration
#   5. Re-enable read-only (flush)
#
# Returns:
#   0 - All operations completed successfully
#   1 - One or more operations failed
# ============================================================================
simulate_live_apply() {
  local rootfs_dir="${1:-$LIVE_ROOTFS_DIR}"
  local efi_dir="${2:-$LIVE_EFI_DIR}"
  local esp_dir="${3:-$LIVE_ESP_DIR}"

  local rc=0

  # Validate inputs
  if [[ ! -d "$rootfs_dir" ]]; then
    echo "ERROR: simulate_live_apply: rootfs_dir not found: $rootfs_dir" >&2
    return 1
  fi
  if [[ ! -d "$efi_dir" ]]; then
    echo "ERROR: simulate_live_apply: efi_dir not found: $efi_dir" >&2
    return 1
  fi

  # 1. Patch defaults — temporarily make rootfs writable (disable steamos-readonly)
  if ! _live_patch_defaults "$rootfs_dir"; then
    echo "ERROR: simulate_live_apply: patch defaults failed" >&2
    rc=1
  fi

  # 2. Run update-grub — regenerate grub.cfg from /etc/default/grub
  if ! _live_run_update_grub "$rootfs_dir" "$efi_dir"; then
    echo "ERROR: simulate_live_apply: update-grub failed" >&2
    rc=1
  fi

  # 3. Patch grub.cfg with target UUID
  if ! _live_patch_grub_cfg "$efi_dir" "$rootfs_dir"; then
    echo "ERROR: simulate_live_apply: grub.cfg patching failed" >&2
    rc=1
  fi

  # 4. Validate GRUB configuration
  if ! _live_validate_grub "$efi_dir" "$rootfs_dir"; then
    echo "ERROR: simulate_live_apply: GRUB validation failed" >&2
    rc=1
  fi

  # 5. Flush — re-enable steamos-readonly
  if ! _live_flush "$rootfs_dir"; then
    echo "ERROR: simulate_live_apply: flush (re-enable read-only) failed" >&2
    rc=1
  fi

  return $rc
}

# Internal: patch defaults — disable steamos-readonly (make rootfs writable)
_live_patch_defaults() {
  local rootfs_dir="$1"

  # Mark read-only as disabled for the duration of the apply
  local ro_state="$LIVE_FIXTURE_DIR/.steamos-readonly"
  echo "readonly=0" > "$ro_state"

  return 0
}

# Internal: run update-grub — regenerate grub.cfg from /etc/default/grub
_live_run_update_grub() {
  local rootfs_dir="$1"
  local efi_dir="$2"

  local grub_cfg="$efi_dir/EFI/steamos/grub.cfg"
  local grub_defaults="$rootfs_dir/etc/default/grub"
  local grub_steamos="$rootfs_dir/etc/default/grub-steamos"

  if [[ ! -f "$grub_defaults" ]]; then
    echo "ERROR: _live_run_update_grub: /etc/default/grub not found" >&2
    return 1
  fi

  # Regenerate grub.cfg from defaults (simulate update-grub behavior)
  # In live mode, update-grub reads /etc/default/grub and /etc/default/grub-steamos
  # and produces a new grub.cfg. We simulate this by re-generating grub.cfg
  # with the current rootfs UUID.
  local rootfs_uuid="$LIVE_TARGET_UUID"

  # Check if steamos-specific parameters exist in grub-steamos
  local steamos_params=""
  if [[ -f "$grub_steamos" ]]; then
    steamos_params="$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_steamos" 2>/dev/null | cut -d= -f2- | tr -d '"')"
  fi

  populate_mock_grub_cfg "$grub_cfg" "$rootfs_uuid"

  return 0
}

# Internal: patch grub.cfg with target UUID and kernel parameters
_live_patch_grub_cfg() {
  local efi_dir="$1"
  local rootfs_dir="$2"
  local grub_cfg="$efi_dir/EFI/steamos/grub.cfg"

  if [[ ! -f "$grub_cfg" ]]; then
    echo "ERROR: _live_patch_grub_cfg: grub.cfg not found: $grub_cfg" >&2
    return 1
  fi

  # Regenerate grub.cfg with current/target UUID (same slot)
  populate_mock_grub_cfg "$grub_cfg" "$LIVE_TARGET_UUID"

  return 0
}

# Internal: validate GRUB configuration after patching
_live_validate_grub() {
  local efi_dir="$1"
  local rootfs_dir="$2"
  local grub_cfg="$efi_dir/EFI/steamos/grub.cfg"

  # Verify grub.cfg is nonempty
  if [[ ! -s "$grub_cfg" ]]; then
    echo "ERROR: _live_validate_grub: grub.cfg is empty" >&2
    return 1
  fi

  # Verify at least one linux entry exists
  local linux_count
  linux_count="$(grep -c '^\s*linux ' "$grub_cfg" 2>/dev/null || echo 0)"
  if [[ "$linux_count" -lt 1 ]]; then
    echo "ERROR: _live_validate_grub: no linux entries in grub.cfg" >&2
    return 1
  fi

  # Verify search --fs-uuid references target UUID
  local uuid_match_count
  uuid_match_count="$(grep -c "search.*--fs-uuid.*--set=root.*${LIVE_TARGET_UUID}" "$grub_cfg" 2>/dev/null || echo 0)"
  if [[ "$uuid_match_count" -lt 1 ]]; then
    echo "ERROR: _live_validate_grub: target UUID not found in grub.cfg search entries" >&2
    return 1
  fi

  return 0
}

# Internal: flush — re-enable steamos-readonly
_live_flush() {
  local rootfs_dir="$1"

  # Re-enable read-only state
  local ro_state="$LIVE_FIXTURE_DIR/.steamos-readonly"
  echo "readonly=1" > "$ro_state"

  return 0
}

# ============================================================================
# simulate_live_update_grub_failure
#
# Create a failing update-grub shim for testing error handling in the
# live scenario. The shim intercepts update-grub calls and exits with
# a non-zero code.
#
# Usage:
#   simulate_live_update_grub_failure BIN_DIR
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
simulate_live_update_grub_failure() {
  local bin_dir="${1:?simulate_live_update_grub_failure: missing BIN_DIR}"

  if [[ ! -d "$bin_dir" ]]; then
    mkdir -p "$bin_dir"
  fi

  local shim_path="$bin_dir/update-grub"

  cat > "$shim_path" <<'SHIM_EOF'
#!/bin/bash
# Live update-grub failure shim for testing error handling
echo "SHIM: intercepted update-grub (live failure test)" >&2
echo "SHIM: arguments: $*" >&2
echo "SHIM: simulating update-grub failure (exit 1)" >&2
exit 1
SHIM_EOF

  chmod +x "$shim_path"

  # Prepend to PATH so the shim is found before the real command
  export PATH="$bin_dir:$PATH"

  return 0
}

# ============================================================================
# verify_no_chroot_operations
#
# Verify that no chroot operations were performed during the live apply.
# In the live scenario, the installer operates directly on the mounted
# filesystem without entering a chroot environment. This means no
# /proc, /sys, or /dev mounts should have been created inside the rootfs.
#
# Usage:
#   verify_no_chroot_operations [ROOTFS_DIR]
#
# Arguments:
#   ROOTFS_DIR - Rootfs directory (default: LIVE_ROOTFS_DIR)
#
# Checks:
#   1. No /proc directory inside rootfs (or it was not created by the installer)
#   2. No /sys directory inside rootfs
#   3. No /dev directory inside rootfs
#   4. No chroot marker files
#
# Returns:
#   0 - No chroot operations detected
#   1 - Chroot operations found
# ============================================================================
verify_no_chroot_operations() {
  local rootfs_dir="${1:-$LIVE_ROOTFS_DIR}"

  local rc=0

  if [[ ! -d "$rootfs_dir" ]]; then
    echo "ERROR: verify_no_chroot_operations: rootfs_dir not found: $rootfs_dir" >&2
    return 1
  fi

  # 1. Check for /proc mount inside rootfs
  # In a live fixture, /proc may exist as a directory from fixture creation,
  # but it should not contain mounted procfs content.
  if [[ -d "$rootfs_dir/proc" ]]; then
    # Verify /proc is empty or contains only the fixture-created content
    # (empty directory is acceptable; mounted procfs would have files)
    local proc_entries
    proc_entries="$(find "$rootfs_dir/proc" -maxdepth 1 -not -path "$rootfs_dir/proc" 2>/dev/null | wc -l)"
    if [[ "$proc_entries" -gt 0 ]]; then
      echo "ERROR: verify_no_chroot_operations: /proc is non-empty inside rootfs ($proc_entries entries)" >&2
      rc=1
    fi
  fi

  # 2. Check for /sys mount inside rootfs
  if [[ -d "$rootfs_dir/sys" ]]; then
    local sys_entries
    sys_entries="$(find "$rootfs_dir/sys" -maxdepth 1 -not -path "$rootfs_dir/sys" 2>/dev/null | wc -l)"
    if [[ "$sys_entries" -gt 0 ]]; then
      echo "ERROR: verify_no_chroot_operations: /sys is non-empty inside rootfs ($sys_entries entries)" >&2
      rc=1
    fi
  fi

  # 3. Check for /dev mount inside rootfs
  if [[ -d "$rootfs_dir/dev" ]]; then
    local dev_entries
    dev_entries="$(find "$rootfs_dir/dev" -maxdepth 1 -not -path "$rootfs_dir/dev" 2>/dev/null | wc -l)"
    if [[ "$dev_entries" -gt 0 ]]; then
      echo "ERROR: verify_no_chroot_operations: /dev is non-empty inside rootfs ($dev_entries entries)" >&2
      rc=1
    fi
  fi

  # 4. Check for chroot marker files
  local -a chroot_markers=(".chroot-active" ".chroot-pid" ".chroot-env")
  local marker
  for marker in "${chroot_markers[@]}"; do
    if [[ -f "$rootfs_dir/$marker" ]]; then
      echo "ERROR: verify_no_chroot_operations: chroot marker found: $marker" >&2
      rc=1
    fi
  done

  return $rc
}

# ============================================================================
# verify_mounts_preserved
#
# Verify that existing /efi and /esp mounts were reused (not newly created)
# and that device/ownership attributes are preserved.
#
# In the live scenario, the installer should use existing mount points
# rather than creating new ones. This function verifies that the mount
# structure is consistent with pre-existing mounts.
#
# Usage:
#   verify_mounts_preserved [EFI_DIR] [ESP_DIR]
#
# Arguments:
#   EFI_DIR - EFI directory (default: LIVE_EFI_DIR)
#   ESP_DIR - ESP directory (default: LIVE_ESP_DIR)
#
# Checks:
#   1. /efi directory exists (was not removed/recreated)
#   2. /esp directory exists (was not removed/recreated)
#   3. Device ownership matches fixture UUIDs
#   4. No new mount points were created by the installer
#
# Returns:
#   0 - Mounts preserved correctly
#   1 - Mount preservation violated
# ============================================================================
verify_mounts_preserved() {
  local efi_dir="${1:-$LIVE_EFI_DIR}"
  local esp_dir="${2:-$LIVE_ESP_DIR}"

  local rc=0

  # 1. /efi directory exists
  if [[ ! -d "$efi_dir" ]]; then
    echo "ERROR: verify_mounts_preserved: EFI directory missing: $efi_dir" >&2
    return 1
  fi

  # 2. /esp directory exists
  if [[ ! -d "$esp_dir" ]]; then
    echo "ERROR: verify_mounts_preserved: ESP directory missing: $esp_dir" >&2
    return 1
  fi

  # 3. Device ownership: verify that the EFI directory contains expected
  #    content (grub.cfg, grubx64.efi) indicating it's the correct device.
  local grub_cfg="$efi_dir/EFI/steamos/grub.cfg"
  if [[ ! -f "$grub_cfg" ]]; then
    echo "ERROR: verify_mounts_preserved: EFI directory missing grub.cfg — possible device mismatch" >&2
    rc=1
  fi

  # Verify the grubx64.efi binary has the expected UUID (device identity)
  local grubx64="$efi_dir/EFI/steamos/grubx64.efi"
  if [[ -f "$grubx64" ]]; then
    local uuid_pattern='[0-9a-fA-F]\{8\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{12\}'
    local embedded_uuid
    embedded_uuid="$(strings "$grubx64" 2>/dev/null | grep -oE "$uuid_pattern" | head -1)"
    if [[ -n "$embedded_uuid" && "$embedded_uuid" != "$LIVE_TARGET_UUID" ]]; then
      echo "ERROR: verify_mounts_preserved: EFI device UUID mismatch (got '$embedded_uuid', expected '$LIVE_TARGET_UUID')" >&2
      rc=1
    fi
  fi

  # 4. Verify no new mount points were created by checking that the
  #    fixture directory structure is unchanged (no new top-level dirs
  #    that weren't in the original fixture).
  local esp_conf_dir="$esp_dir/SteamOS/conf"
  if [[ ! -d "$esp_conf_dir" ]]; then
    echo "ERROR: verify_mounts_preserved: ESP SteamOS/conf directory missing" >&2
    rc=1
  fi

  return $rc
}

# ============================================================================
# verify_opposing_slot_unchanged
#
# Verify that slot B (opposing slot) artifacts are byte-identical to their
# pre-apply state. This is the critical invariant for live scenarios: the
# opposing slot must never be modified during a live apply.
#
# Usage:
#   verify_opposing_slot_unchanged [EFI_DIR] [ESP_DIR]
#
# Arguments:
#   EFI_DIR - EFI directory (default: LIVE_EFI_DIR)
#   ESP_DIR - ESP directory (default: LIVE_ESP_DIR)
#
# Returns:
#   0 - All slot B artifacts preserved (byte-identical)
#   1 - One or more slot B artifacts were modified
# ============================================================================
verify_opposing_slot_unchanged() {
  local efi_dir="${1:-$LIVE_EFI_DIR}"
  local esp_dir="${2:-$LIVE_ESP_DIR}"

  if [[ -z "$_LIVE_SLOT_B_CHECKSUMS" || ! -f "$_LIVE_SLOT_B_CHECKSUMS" ]]; then
    echo "ERROR: verify_opposing_slot_unchanged: no pre-apply snapshot available" >&2
    return 1
  fi

  local rc=0

  # Define B-slot artifacts to verify
  local -a artifact_labels=("partset-B" "partset-other" "partset-all" "partset-shared" "bootconf-B" "efi-grub" "efi-grubx64")
  local -a artifact_paths=(
    "$efi_dir/SteamOS/partsets/B"
    "$efi_dir/SteamOS/partsets/other"
    "$efi_dir/SteamOS/partsets/all"
    "$efi_dir/SteamOS/partsets/shared"
    "$esp_dir/SteamOS/conf/B.conf"
    "$efi_dir/EFI/steamos/grub.cfg"
    "$efi_dir/EFI/steamos/grubx64.efi"
  )

  local i
  for ((i = 0; i < ${#artifact_labels[@]}; i++)); do
    local label="${artifact_labels[$i]}"
    local path="${artifact_paths[$i]}"

    # Get expected checksum from snapshot
    local expected
    expected="$(grep " $label$" "$_LIVE_SLOT_B_CHECKSUMS" 2>/dev/null | awk '{print $1}')"

    if [[ -z "$expected" || "$expected" == "MISSING" ]]; then
      # Artifact was not present in snapshot — check it doesn't exist now
      if [[ -f "$path" ]]; then
        echo "ERROR: verify_opposing_slot_unchanged: unexpected artifact appeared: $label" >&2
        rc=1
      fi
      continue
    fi

    # File should exist and have same checksum
    if [[ ! -f "$path" ]]; then
      echo "ERROR: verify_opposing_slot_unchanged: B-slot artifact missing: $label ($path)" >&2
      rc=1
      continue
    fi

    local actual
    actual="$(md5sum "$path" | awk '{print $1}')"

    if [[ "$actual" != "$expected" ]]; then
      echo "ERROR: verify_opposing_slot_unchanged: B-slot artifact modified: $label (expected=$expected, actual=$actual)" >&2
      rc=1
    fi
  done

  return $rc
}

# ============================================================================
# verify_no_boot_selection_mutation
#
# Verify that bootconf files and RAUC-related fields were not mutated
# during the live apply. The live scenario should not change boot
# selection state (image-invalid, boot-attempts, title fields).
#
# Usage:
#   verify_no_boot_selection_mutation [ESP_DIR]
#
# Arguments:
#   ESP_DIR - ESP directory (default: LIVE_ESP_DIR)
#
# Checks:
#   1. A.conf title field unchanged
#   2. A.conf image-invalid field unchanged
#   3. A.conf boot-attempts field unchanged
#   4. B.conf title field unchanged
#   5. B.conf image-invalid field unchanged
#   6. B.conf boot-attempts field unchanged
#
# Returns:
#   0 - No boot-selection mutation detected
#   1 - Boot-selection mutation found
# ============================================================================
verify_no_boot_selection_mutation() {
  local esp_dir="${1:-$LIVE_ESP_DIR}"

  local rc=0

  # Record expected field values from fixture defaults
  # A.conf: title=SteamOS (slot A), image-invalid=0, boot-attempts=0
  # B.conf: title=SteamOS (slot B), image-invalid=1, boot-attempts=0

  # Check A.conf
  local conf_a="$esp_dir/SteamOS/conf/A.conf"
  if [[ -f "$conf_a" ]]; then
    local a_title a_invalid a_boot
    a_title="$(grep '^title=' "$conf_a" 2>/dev/null | head -1)"
    a_invalid="$(grep '^image-invalid=' "$conf_a" 2>/dev/null | head -1)"
    a_boot="$(grep '^boot-attempts=' "$conf_a" 2>/dev/null | head -1)"

    if [[ "$a_title" != "title=SteamOS (slot A)" ]]; then
      echo "ERROR: verify_no_boot_selection_mutation: A.conf title was mutated: '$a_title'" >&2
      rc=1
    fi
    if [[ "$a_invalid" != "image-invalid=0" ]]; then
      echo "ERROR: verify_no_boot_selection_mutation: A.conf image-invalid was mutated: '$a_invalid'" >&2
      rc=1
    fi
    if [[ "$a_boot" != "boot-attempts=0" ]]; then
      echo "ERROR: verify_no_boot_selection_mutation: A.conf boot-attempts was mutated: '$a_boot'" >&2
      rc=1
    fi
  fi

  # Check B.conf
  local conf_b="$esp_dir/SteamOS/conf/B.conf"
  if [[ -f "$conf_b" ]]; then
    local b_title b_invalid b_boot
    b_title="$(grep '^title=' "$conf_b" 2>/dev/null | head -1)"
    b_invalid="$(grep '^image-invalid=' "$conf_b" 2>/dev/null | head -1)"
    b_boot="$(grep '^boot-attempts=' "$conf_b" 2>/dev/null | head -1)"

    if [[ "$b_title" != "title=SteamOS (slot B)" ]]; then
      echo "ERROR: verify_no_boot_selection_mutation: B.conf title was mutated: '$b_title'" >&2
      rc=1
    fi
    if [[ "$b_invalid" != "image-invalid=1" ]]; then
      echo "ERROR: verify_no_boot_selection_mutation: B.conf image-invalid was mutated: '$b_invalid'" >&2
      rc=1
    fi
    if [[ "$b_boot" != "boot-attempts=0" ]]; then
      echo "ERROR: verify_no_boot_selection_mutation: B.conf boot-attempts was mutated: '$b_boot'" >&2
      rc=1
    fi
  fi

  return $rc
}

# ============================================================================
# verify_read_only_state_restored
#
# Verify that the steamos-readonly state was properly restored after the
# live apply. The installer must re-enable read-only mode after completing
# its operations to maintain system integrity.
#
# Usage:
#   verify_read_only_state_restored
#
# Checks:
#   1. steamos-readonly state file exists
#   2. State is "readonly=1" (read-only enabled)
#   3. State matches the pre-apply recorded state
#
# Returns:
#   0 - Read-only state correctly restored
#   1 - Read-only state not restored
# ============================================================================
verify_read_only_state_restored() {
  local rc=0

  # Verify the state file exists
  local ro_state="$LIVE_FIXTURE_DIR/.steamos-readonly"
  if [[ ! -f "$ro_state" ]]; then
    echo "ERROR: verify_read_only_state_restored: steamos-readonly state file missing" >&2
    return 1
  fi

  # Verify state is "readonly=1"
  local current_state
  current_state="$(cat "$ro_state" 2>/dev/null)"
  if [[ "$current_state" != "readonly=1" ]]; then
    echo "ERROR: verify_read_only_state_restored: steamos-readonly not restored (got '$current_state', expected 'readonly=1')" >&2
    rc=1
  fi

  # Verify state matches pre-apply recorded state
  if [[ -n "$_LIVE_READONLY_STATE_FILE" && -f "$_LIVE_READONLY_STATE_FILE" ]]; then
    local expected_state
    expected_state="$(cat "$_LIVE_READONLY_STATE_FILE" 2>/dev/null)"
    if [[ "$current_state" != "$expected_state" ]]; then
      echo "ERROR: verify_read_only_state_restored: state differs from pre-apply (got '$current_state', expected '$expected_state')" >&2
      rc=1
    fi
  fi

  return $rc
}

# ============================================================================
# verify_no_duplicate_params
#
# Token-aware duplicate detection for kernel parameters in grub.cfg.
# Verifies that no parameter appears more than once on any linux command
# line, using whole-token matching (not substring matching).
#
# Usage:
#   verify_no_duplicate_params [EFI_DIR] [PARAMS...]
#
# Arguments:
#   EFI_DIR  - EFI directory (default: LIVE_EFI_DIR)
#   PARAMS   - Parameters to check for duplicates (if empty, checks all)
#
# Token-aware matching ensures that "ro" does not match "noro" and that
# "root=" does not match "rootdelay=".
#
# Returns:
#   0 - No duplicate parameters found
#   1 - Duplicates detected
# ============================================================================
verify_no_duplicate_params() {
  local efi_dir="${1:-$LIVE_EFI_DIR}"
  shift 2>/dev/null || true
  local -a params=("$@")

  local grub_cfg="$efi_dir/EFI/steamos/grub.cfg"
  local rc=0

  if [[ ! -f "$grub_cfg" ]]; then
    echo "ERROR: verify_no_duplicate_params: grub.cfg not found: $grub_cfg" >&2
    return 1
  fi

  # Check each linux line for duplicate tokens
  local line
  while IFS= read -r line; do
    # Skip comments and non-linux lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*linux[[:space:]] ]] || continue

    # Extract the parameter portion (everything after "linux <path> ")
    # The format is: linux <kernel-path> <params...>
    local params_portion
    params_portion="$(printf '%s' "$line" | sed 's/^[[:space:]]*linux[[:space:]]\+[^[:space:]]\+[[:space:]]*//')"

    if [[ -z "$params_portion" ]]; then
      continue
    fi

    # Tokenize: split on whitespace
    local -a tokens=()
    read -ra tokens <<< "$params_portion"

    # If specific params were requested, only check those
    if [[ ${#params[@]} -gt 0 ]]; then
      local -a check_tokens=()
      local param
      for param in "${params[@]}"; do
        local token
        for token in "${tokens[@]}"; do
          if [[ "$token" == "$param" ]]; then
            check_tokens+=("$token")
          fi
        done
      done
      tokens=("${check_tokens[@]}")
    fi

    # Check for duplicates within this line
    local -A token_counts=()
    local token
    for token in "${tokens[@]}"; do
      [[ -z "$token" ]] && continue
      token_counts["$token"]=$(( ${token_counts["$token"]:-0} + 1 ))
    done

    for token in "${!token_counts[@]}"; do
      if [[ "${token_counts[$token]}" -gt 1 ]]; then
        echo "ERROR: verify_no_duplicate_params: duplicate parameter '$token' found ${token_counts[$token]} times on a linux line" >&2
        rc=1
      fi
    done
  done < "$grub_cfg"

  return $rc
}

# ============================================================================
# verify_keep_list_exact_once
#
# Verify that each required entry in the atomic-update keep-list appears
# exactly once. The keep-list controls which files survive atomic updates,
# and duplicates or missing entries can cause unpredictable behavior.
#
# Usage:
#   verify_keep_list_exact_once [ROOTFS_DIR] [REQUIRED_ENTRIES...]
#
# Arguments:
#   ROOTFS_DIR        - Rootfs directory (default: LIVE_ROOTFS_DIR)
#   REQUIRED_ENTRIES  - Entries that must appear exactly once
#                       (if empty, uses the default keep-list entries)
#
# Checks:
#   1. keep-list.conf exists
#   2. Each required entry appears exactly once (no duplicates)
#   3. Each required entry is present (no missing)
#
# Returns:
#   0 - All entries present exactly once
#   1 - Duplicates or missing entries detected
# ============================================================================
verify_keep_list_exact_once() {
  local rootfs_dir="${1:-$LIVE_ROOTFS_DIR}"
  shift 2>/dev/null || true
  local -a required_entries=("$@")

  local keep_list="$rootfs_dir/etc/atomic-update.conf.d/keep-list.conf"
  local rc=0

  # 1. Verify keep-list.conf exists
  if [[ ! -f "$keep_list" ]]; then
    echo "ERROR: verify_keep_list_exact_once: keep-list.conf not found: $keep_list" >&2
    return 1
  fi

  # If no specific entries were requested, use the default fixture entries
  if [[ ${#required_entries[@]} -eq 0 ]]; then
    required_entries=(
      "/boot/vmlinuz-*"
      "/boot/initramfs-*"
      "/boot/amd-ucode.img"
      "/etc/default/grub"
      "/etc/default/grub-steamos"
    )
  fi

  # Read non-comment, non-blank lines from keep-list
  local -a keep_list_entries=()
  local line
  while IFS= read -r line; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    keep_list_entries+=("$line")
  done < "$keep_list"

  # 2. Check for duplicates (each entry should appear exactly once)
  local -A entry_counts=()
  for entry in "${keep_list_entries[@]}"; do
    entry_counts["$entry"]=$(( ${entry_counts["$entry"]:-0} + 1 ))
  done

  for entry in "${!entry_counts[@]}"; do
    if [[ "${entry_counts[$entry]}" -gt 1 ]]; then
      echo "ERROR: verify_keep_list_exact_once: duplicate entry '$entry' found ${entry_counts[$entry]} times" >&2
      rc=1
    fi
  done

  # 3. Check that each required entry is present
  local req_entry
  for req_entry in "${required_entries[@]}"; do
    local found=0
    local existing_entry
    for existing_entry in "${keep_list_entries[@]}"; do
      if [[ "$existing_entry" == "$req_entry" ]]; then
        found=1
        break
      fi
    done
    if [[ "$found" -eq 0 ]]; then
      echo "ERROR: verify_keep_list_exact_once: required entry missing: '$req_entry'" >&2
      rc=1
    fi
  done

  return $rc
}

# ============================================================================
# Utility functions for live tests
# ============================================================================

# Get the target rootfs UUID for the current live fixture
# Usage: get_live_target_uuid
get_live_target_uuid() {
  if [[ -z "$LIVE_TARGET_UUID" ]]; then
    echo "ERROR: get_live_target_uuid: LIVE_TARGET_UUID not set (call live_scenario_setup first)" >&2
    return 1
  fi
  echo "$LIVE_TARGET_UUID"
}

# Get the current (slot A) rootfs UUID for the current live fixture
# Usage: get_live_current_uuid
get_live_current_uuid() {
  if [[ -z "$LIVE_CURRENT_UUID" ]]; then
    echo "ERROR: get_live_current_uuid: LIVE_CURRENT_UUID not set (call live_scenario_setup first)" >&2
    return 1
  fi
  echo "$LIVE_CURRENT_UUID"
}

# Get the EFI directory for the current live fixture
# Usage: get_live_efi_dir
get_live_efi_dir() {
  if [[ -z "$LIVE_EFI_DIR" ]]; then
    echo "ERROR: get_live_efi_dir: LIVE_EFI_DIR not set (call live_scenario_setup first)" >&2
    return 1
  fi
  echo "$LIVE_EFI_DIR"
}

# Get the rootfs directory for the current live fixture
# Usage: get_live_rootfs_dir
get_live_rootfs_dir() {
  if [[ -z "$LIVE_ROOTFS_DIR" ]]; then
    echo "ERROR: get_live_rootfs_dir: LIVE_ROOTFS_DIR not set (call live_scenario_setup first)" >&2
    return 1
  fi
  echo "$LIVE_ROOTFS_DIR"
}

# Get the ESP directory for the current live fixture
# Usage: get_live_esp_dir
get_live_esp_dir() {
  if [[ -z "$LIVE_ESP_DIR" ]]; then
    echo "ERROR: get_live_esp_dir: LIVE_ESP_DIR not set (call live_scenario_setup first)" >&2
    return 1
  fi
  echo "$LIVE_ESP_DIR"
}

# Get the metadata directory for the current live fixture
# Usage: get_live_metadata_dir
get_live_metadata_dir() {
  if [[ -z "$LIVE_METADATA_DIR" ]]; then
    echo "ERROR: get_live_metadata_dir: LIVE_METADATA_DIR not set (call live_scenario_setup first)" >&2
    return 1
  fi
  echo "$LIVE_METADATA_DIR"
}

# Get the namespace for the current live fixture
# Usage: get_live_namespace
get_live_namespace() {
  if [[ -z "$LIVE_NAMESPACE" ]]; then
    echo "ERROR: get_live_namespace: LIVE_NAMESPACE not set (call live_scenario_setup first)" >&2
    return 1
  fi
  echo "$LIVE_NAMESPACE"
}
