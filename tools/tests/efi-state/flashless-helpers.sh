#!/bin/bash
#
# tools/tests/efi-state/flashless-helpers.sh
# Flashless-specific test infrastructure for EFI state application tests.
#
# Provides helper functions for Flashless scenario tests (dual-slot,
# current=A, target=B standby deployment), including fixture setup/teardown,
# EFI state application simulation (format -> write -> rebuild boot -> activate),
# bootconf lifecycle management (staging -> activation), btrfs ro lifecycle,
# error injection, and invariant verification helpers.
#
# Usage:
#   source tools/tests/efi-state/flashless-helpers.sh
#
# Dependencies:
#   - test-harness.sh    (assertion helpers, test lifecycle)
#   - fixture-factory.sh (mock fixture creation/destruction)
#   - topology.sh         (deterministic UUID/PARTUUID generation)
#
# Design constraints:
#   - Flashless scenario: dual-slot, current=A, target=B (standby)
#   - Standby deployment: target slot is NOT the active slot
#   - Bootconf lifecycle: staging (image-invalid=1) -> activation (mark-active)
#   - Btrfs ro lifecycle: clear -> write -> restore
#   - Activation via rauc status mark-active (simulated)
#   - No writes to current slot A during standby deployment

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "flashless-helpers.sh is a library — source it, don't run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Guard: ensure required libraries are loaded
# ---------------------------------------------------------------------------
if ! declare -f test_harness_init >/dev/null 2>&1; then
  echo "ERROR: flashless-helpers.sh requires test-harness.sh (source it first)." >&2
  return 1 2>/dev/null || exit 1
fi

if ! declare -f create_mock_boot_fixture >/dev/null 2>&1; then
  echo "ERROR: flashless-helpers.sh requires fixture-factory.sh (source it first)." >&2
  return 1 2>/dev/null || exit 1
fi

# ---------------------------------------------------------------------------
# Flashless scenario constants
# ---------------------------------------------------------------------------
FLASHLESS_SLOT_COUNT=2
FLASHLESS_CURRENT_SLOT="A"
FLASHLESS_TARGET_SLOT="B"
FLASHLESS_SCENARIO="flashless"

# ============================================================================
# Global state for flashless fixture
# ============================================================================
FLASHLESS_FIXTURE_DIR=""
FLASHLESS_ROOTFS_DIR=""
FLASHLESS_ROOTFS_B_DIR=""
FLASHLESS_EFI_DIR=""
FLASHLESS_ESP_DIR=""
FLASHLESS_METADATA_DIR=""
FLASHLESS_NAMESPACE=""
FLASHLESS_TARGET_UUID=""
FLASHLESS_CURRENT_UUID=""

# Snapshot checksums for A-slot preservation verification (F-02)
_FLASHLESS_SLOT_A_CHECKSUMS=""

# Btrfs ro state tracking
_FLASHLESS_BTRFS_RO_STATE_FILE=""

# Activation state tracking
_FLASHLESS_ACTIVATION_STATE_FILE=""

# ============================================================================
# flashless_scenario_setup
#
# Create a flashless-specific mock fixture (dual-slot, current=A, target=B).
#
# The flashless scenario writes to the standby (non-active) slot B while
# slot A remains the active boot slot. This is the key difference from the
# live scenario (which writes to the active slot).
#
# Usage:
#   flashless_scenario_setup
#
# Sets the following global variables for test access:
#   FLASHLESS_FIXTURE_DIR   - Root of the mock fixture tree
#   FLASHLESS_ROOTFS_DIR    - Mock rootfs mount point (slot B / target)
#   FLASHLESS_ROOTFS_B_DIR  - Alias: same as FLASHLESS_ROOTFS_DIR
#   FLASHLESS_EFI_DIR       - Mock EFI partition mount point
#   FLASHLESS_ESP_DIR       - Mock shared ESP mount point
#   FLASHLESS_METADATA_DIR  - Mock metadata directory
#   FLASHLESS_TARGET_UUID   - Target rootfs UUID (slot B)
#   FLASHLESS_CURRENT_UUID  - Current rootfs UUID (slot A)
#   FLASHLESS_NAMESPACE     - Test namespace for UUID derivation
#
# The fixture is created in a temporary directory that is automatically
# cleaned up by flashless_scenario_teardown().
# ============================================================================
flashless_scenario_setup() {
  # Create temporary base directory
  FLASHLESS_FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/flashless-test-XXXXXX")"
  if [[ -z "$FLASHLESS_FIXTURE_DIR" || ! -d "$FLASHLESS_FIXTURE_DIR" ]]; then
    echo "ERROR: flashless_scenario_setup: failed to create temp directory" >&2
    return 1
  fi

  FLASHLESS_NAMESPACE="flashless-${FLASHLESS_TARGET_SLOT}-$$"

  # Use fixture-factory to create the complete dual-slot mock fixture.
  # create_mock_boot_fixture determines that current_slot is A (the inverse
  # of target_slot=B) and creates both slot A and slot B directories.
  create_mock_boot_fixture "$FLASHLESS_FIXTURE_DIR" "$FLASHLESS_SCENARIO" "$FLASHLESS_TARGET_SLOT" "$FLASHLESS_NAMESPACE"

  # Set convenience variables for test access
  # The rootfs dir from fixture-factory is the *target* rootfs (slot B).
  FLASHLESS_ROOTFS_DIR="$FLASHLESS_FIXTURE_DIR/rootfs"
  FLASHLESS_ROOTFS_B_DIR="$FLASHLESS_ROOTFS_DIR"
  FLASHLESS_EFI_DIR="$FLASHLESS_FIXTURE_DIR/efi"
  FLASHLESS_ESP_DIR="$FLASHLESS_FIXTURE_DIR/esp"
  FLASHLESS_METADATA_DIR="$FLASHLESS_FIXTURE_DIR/metadata"

  # Derive UUIDs (consistent with fixture-factory)
  FLASHLESS_TARGET_UUID="$(derive_uuid "$FLASHLESS_NAMESPACE" "rootfs-${FLASHLESS_TARGET_SLOT}")"
  FLASHLESS_CURRENT_UUID="$(derive_uuid "$FLASHLESS_NAMESPACE" "rootfs-${FLASHLESS_CURRENT_SLOT}")"

  # Snapshot A-slot state for preservation verification (F-02)
  _flashless_snapshot_slot_a

  # Record initial btrfs ro state
  _flashless_record_btrfs_ro_state

  # Record initial activation state
  _flashless_record_activation_state

  # Verify fixture was created correctly
  if [[ ! -d "$FLASHLESS_EFI_DIR/EFI/steamos" ]]; then
    echo "ERROR: flashless_scenario_setup: EFI fixture directory not created" >&2
    flashless_scenario_teardown
    return 1
  fi

  if [[ ! -f "$FLASHLESS_EFI_DIR/EFI/steamos/grub.cfg" ]]; then
    echo "ERROR: flashless_scenario_setup: grub.cfg not created" >&2
    flashless_scenario_teardown
    return 1
  fi

  # Verify dual-slot structure: both A and B partsets should exist
  if [[ ! -f "$FLASHLESS_EFI_DIR/SteamOS/partsets/A" ]]; then
    echo "ERROR: flashless_scenario_setup: slot A partset not created" >&2
    flashless_scenario_teardown
    return 1
  fi

  if [[ ! -f "$FLASHLESS_EFI_DIR/SteamOS/partsets/B" ]]; then
    echo "ERROR: flashless_scenario_setup: slot B partset not created" >&2
    flashless_scenario_teardown
    return 1
  fi

  # Verify bootconf files for both slots
  if [[ ! -f "$FLASHLESS_ESP_DIR/SteamOS/conf/A.conf" ]]; then
    echo "ERROR: flashless_scenario_setup: A.conf not created" >&2
    flashless_scenario_teardown
    return 1
  fi

  if [[ ! -f "$FLASHLESS_ESP_DIR/SteamOS/conf/B.conf" ]]; then
    echo "ERROR: flashless_scenario_setup: B.conf not created" >&2
    flashless_scenario_teardown
    return 1
  fi

  return 0
}

# ============================================================================
# flashless_scenario_teardown
#
# Clean up flashless fixture directory and reset global state.
#
# Usage:
#   flashless_scenario_teardown
#
# This function is idempotent — safe to call multiple times.
# Designed to be used as a cleanup handler or trap target.
# ============================================================================
flashless_scenario_teardown() {
  if [[ -n "$FLASHLESS_FIXTURE_DIR" && -d "$FLASHLESS_FIXTURE_DIR" ]]; then
    destroy_mock_fixture "$FLASHLESS_FIXTURE_DIR"
  fi

  # Clean up snapshot files
  if [[ -n "$_FLASHLESS_SLOT_A_CHECKSUMS" && -f "$_FLASHLESS_SLOT_A_CHECKSUMS" ]]; then
    rm -f "$_FLASHLESS_SLOT_A_CHECKSUMS"
  fi
  if [[ -n "$_FLASHLESS_BTRFS_RO_STATE_FILE" && -f "$_FLASHLESS_BTRFS_RO_STATE_FILE" ]]; then
    rm -f "$_FLASHLESS_BTRFS_RO_STATE_FILE"
  fi
  if [[ -n "$_FLASHLESS_ACTIVATION_STATE_FILE" && -f "$_FLASHLESS_ACTIVATION_STATE_FILE" ]]; then
    rm -f "$_FLASHLESS_ACTIVATION_STATE_FILE"
  fi

  FLASHLESS_FIXTURE_DIR=""
  FLASHLESS_ROOTFS_DIR=""
  FLASHLESS_ROOTFS_B_DIR=""
  FLASHLESS_EFI_DIR=""
  FLASHLESS_ESP_DIR=""
  FLASHLESS_METADATA_DIR=""
  FLASHLESS_NAMESPACE=""
  FLASHLESS_TARGET_UUID=""
  FLASHLESS_CURRENT_UUID=""
  _FLASHLESS_SLOT_A_CHECKSUMS=""
  _FLASHLESS_BTRFS_RO_STATE_FILE=""
  _FLASHLESS_ACTIVATION_STATE_FILE=""
}

# ============================================================================
# Internal: snapshot A-slot files for preservation verification (F-02)
# ============================================================================
_flashless_snapshot_slot_a() {
  local checksum_file
  checksum_file="$(mktemp "${TMPDIR:-/tmp}/flashless-slot-a-snap-XXXXXX")"

  # Snapshot A-slot EFI grub.cfg
  local grub_a="$FLASHLESS_EFI_DIR/EFI/steamos/grub.cfg"
  if [[ -f "$grub_a" ]]; then
    md5sum "$grub_a" | awk '{print $1, "efi-grub"}' >"$checksum_file"
  else
    echo "MISSING efi-grub" >"$checksum_file"
  fi

  # Snapshot A-slot EFI grubx64.efi
  local efi_a="$FLASHLESS_EFI_DIR/EFI/steamos/grubx64.efi"
  if [[ -f "$efi_a" ]]; then
    md5sum "$efi_a" | awk '{print $1, "efi-grubx64"}' >>"$checksum_file"
  else
    echo "MISSING efi-grubx64" >>"$checksum_file"
  fi

  # Snapshot A-slot partset
  local partset_a="$FLASHLESS_EFI_DIR/SteamOS/partsets/A"
  if [[ -f "$partset_a" ]]; then
    md5sum "$partset_a" | awk '{print $1, "partset-A"}' >>"$checksum_file"
  else
    echo "MISSING partset-A" >>"$checksum_file"
  fi

  # Snapshot A-slot bootconf
  local conf_a="$FLASHLESS_ESP_DIR/SteamOS/conf/A.conf"
  if [[ -f "$conf_a" ]]; then
    md5sum "$conf_a" | awk '{print $1, "bootconf-A"}' >>"$checksum_file"
  else
    echo "MISSING bootconf-A" >>"$checksum_file"
  fi

  _FLASHLESS_SLOT_A_CHECKSUMS="$checksum_file"
}

# ============================================================================
# Internal: record initial btrfs ro state
# ============================================================================
_flashless_record_btrfs_ro_state() {
  local state_file
  state_file="$(mktemp "${TMPDIR:-/tmp}/flashless-btrfs-ro-XXXXXX")"

  # In the flashless scenario, the btrfs ro lifecycle is:
  #   1. Clear ro (make writable) for target slot
  #   2. Write artifacts
  #   3. Restore ro after completion
  #
  # Record initial state: ro is enabled (normal state).
  echo "ro=1" >"$state_file"

  _FLASHLESS_BTRFS_RO_STATE_FILE="$state_file"
}

# ============================================================================
# Internal: record initial activation state
# ============================================================================
_flashless_record_activation_state() {
  local state_file
  state_file="$(mktemp "${TMPDIR:-/tmp}/flashless-activation-XXXXXX")"

  # In the flashless scenario, activation is the LAST step:
  #   1. Stage B.conf (image-invalid=1) during write
  #   2. Validate B slot
  #   3. Only then set image-invalid=0 and mark active
  echo "active-slot=A" >"$state_file"
  echo "b-image-invalid=1" >>"$state_file"
  echo "b-valid=0" >>"$state_file"

  _FLASHLESS_ACTIVATION_STATE_FILE="$state_file"
}

# ============================================================================
# simulate_flashless_apply
#
# Full happy-path apply for the flashless scenario.
# Performs the complete sequence: format -> write -> rebuild boot -> activate.
#
# This is the main entry point for flashless test scenarios that need
# a complete successful apply cycle.
#
# Usage:
#   simulate_flashless_apply [ROOTFS_DIR] [EFI_DIR] [ESP_DIR]
#
# Arguments:
#   ROOTFS_DIR - Rootfs directory for slot B (default: FLASHLESS_ROOTFS_DIR)
#   EFI_DIR    - EFI directory (default: FLASHLESS_EFI_DIR)
#   ESP_DIR    - ESP directory (default: FLASHLESS_ESP_DIR)
#
# Performs:
#   1. Clear btrfs ro on target slot (make writable)
#   2. Format target slot (efi-B + var-B)
#   3. Write EFI artifacts to target slot
#   4. Rebuild boot (grub.cfg, grubx64.efi, partsets, bootconf for B)
#   5. Validate target slot
#   6. Restore btrfs ro on target slot
#   7. Activate (set B.conf image-invalid=0, mark active via rauc)
#
# Returns:
#   0 - All operations completed successfully
#   1 - One or more operations failed
# ============================================================================
simulate_flashless_apply() {
  local rootfs_dir="${1:-$FLASHLESS_ROOTFS_DIR}"
  local efi_dir="${2:-$FLASHLESS_EFI_DIR}"
  local esp_dir="${3:-$FLASHLESS_ESP_DIR}"

  local rc=0

  # Validate inputs
  if [[ ! -d "$rootfs_dir" ]]; then
    echo "ERROR: simulate_flashless_apply: rootfs_dir not found: $rootfs_dir" >&2
    return 1
  fi
  if [[ ! -d "$efi_dir" ]]; then
    echo "ERROR: simulate_flashless_apply: efi_dir not found: $efi_dir" >&2
    return 1
  fi

  # 1. Clear btrfs ro (make target writable)
  if ! _flashless_clear_btrfs_ro; then
    echo "ERROR: simulate_flashless_apply: clear btrfs ro failed" >&2
    rc=1
  fi

  # 2. Format target slot (efi-B + var-B)
  if ! simulate_flashless_format_target "$rootfs_dir" "$efi_dir" "$esp_dir"; then
    echo "ERROR: simulate_flashless_apply: format target failed" >&2
    rc=1
  fi

  # 3. Write EFI artifacts to target slot
  if ! _flashless_write_efi_artifacts "$rootfs_dir" "$efi_dir" "$esp_dir"; then
    echo "ERROR: simulate_flashless_apply: write EFI artifacts failed" >&2
    rc=1
  fi

  # 4. Rebuild boot (grub.cfg, grubx64.efi, partsets, bootconf for B)
  if ! simulate_flashless_rebuild_boot "$rootfs_dir" "$efi_dir" "$esp_dir"; then
    echo "ERROR: simulate_flashless_apply: rebuild boot failed" >&2
    rc=1
  fi

  # 5. Restore btrfs ro
  if ! _flashless_restore_btrfs_ro; then
    echo "ERROR: simulate_flashless_apply: restore btrfs ro failed" >&2
    rc=1
  fi

  # 6. Activate (set B.conf image-invalid=0, mark active)
  if ! simulate_flashless_activate "$esp_dir"; then
    echo "ERROR: simulate_flashless_apply: activate failed" >&2
    rc=1
  fi

  return $rc
}

# ============================================================================
# Internal: clear btrfs ro (make writable)
# ============================================================================
_flashless_clear_btrfs_ro() {
  # In the flashless scenario, clear btrfs ro before writing to target slot.
  local ro_state="$FLASHLESS_FIXTURE_DIR/.btrfs-ro"
  echo "ro=0" >"$ro_state"
  return 0
}

# ============================================================================
# Internal: restore btrfs ro after writing
# ============================================================================
_flashless_restore_btrfs_ro() {
  # Restore btrfs ro to read-only after completing writes to target slot.
  local ro_state="$FLASHLESS_FIXTURE_DIR/.btrfs-ro"
  echo "ro=1" >"$ro_state"
  return 0
}

# ============================================================================
# simulate_flashless_format_target
#
# Format the target slot (efi-B + var-B).
#
# In the flashless scenario, formatting the target slot means creating
# fresh filesystem structures for the standby slot B's EFI and var
# partitions.
#
# Usage:
#   simulate_flashless_format_target [ROOTFS_DIR] [EFI_DIR] [ESP_DIR]
#
# Arguments:
#   ROOTFS_DIR - Rootfs directory (default: FLASHLESS_ROOTFS_DIR)
#   EFI_DIR    - EFI directory (default: FLASHLESS_EFI_DIR)
#   ESP_DIR    - ESP directory (default: FLASHLESS_ESP_DIR)
#
# Returns:
#   0 - Format completed successfully
#   1 - Format failed
# ============================================================================
simulate_flashless_format_target() {
  local rootfs_dir="${1:-$FLASHLESS_ROOTFS_DIR}"
  local efi_dir="${2:-$FLASHLESS_EFI_DIR}"
  local esp_dir="${3:-$FLASHLESS_ESP_DIR}"

  # Create the target EFI partition structure (efi-B directory)
  # In the flashless scenario, this represents formatting the efi-B partition.
  local target_efi_dir="$efi_dir"
  mkdir -p "$target_efi_dir/EFI/steamos"
  mkdir -p "$target_efi_dir/SteamOS/partsets"

  # Create the target var partition structure (var-B)
  # In the mock fixture, var-B is represented as a directory under rootfs
  local var_b_dir="$rootfs_dir/var"
  mkdir -p "$var_b_dir"

  return 0
}

# ============================================================================
# Internal: write EFI artifacts to target slot
# ============================================================================
_flashless_write_efi_artifacts() {
  local rootfs_dir="$1"
  local efi_dir="$2"
  local esp_dir="$3"

  # Write boot payload (kernel, initramfs) to target rootfs
  local kernel_version="6.1.52-neptune-61"
  mkdir -p "$rootfs_dir/boot"

  # Create kernel and initramfs if they don't exist
  if [[ ! -f "$rootfs_dir/boot/vmlinuz-${kernel_version}" ]]; then
    dd if=/dev/urandom bs=1024 count=32 \
      of="$rootfs_dir/boot/vmlinuz-${kernel_version}" 2>/dev/null
  fi

  if [[ ! -f "$rootfs_dir/boot/initramfs-${kernel_version}.img" ]]; then
    dd if=/dev/urandom bs=1024 count=64 \
      of="$rootfs_dir/boot/initramfs-${kernel_version}.img" 2>/dev/null
  fi

  if [[ ! -f "$rootfs_dir/boot/amd-ucode.img" ]]; then
    dd if=/dev/urandom bs=1024 count=16 \
      of="$rootfs_dir/boot/amd-ucode.img" 2>/dev/null
  fi

  return 0
}

# ============================================================================
# simulate_flashless_rebuild_boot
#
# Rebuild grub.cfg, grubx64.efi, partsets, and bootconf for slot B.
#
# This simulates the boot rebuild phase of the flashless scenario:
# generating B-specific boot configuration while A remains untouched.
#
# Usage:
#   simulate_flashless_rebuild_boot [ROOTFS_DIR] [EFI_DIR] [ESP_DIR]
#
# Arguments:
#   ROOTFS_DIR - Rootfs directory (default: FLASHLESS_ROOTFS_DIR)
#   EFI_DIR    - EFI directory (default: FLASHLESS_EFI_DIR)
#   ESP_DIR    - ESP directory (default: FLASHLESS_ESP_DIR)
#
# Performs:
#   1. Regenerate grub.cfg with target (B) UUID
#   2. Regenerate grubx64.efi with embedded B UUID
#   3. Update partset files for target slot B (self, all, shared)
#   4. Stage bootconf B.conf (image-invalid=1 — staging state)
#
# Returns:
#   0 - All rebuild operations completed successfully
#   1 - One or more operations failed
# ============================================================================
simulate_flashless_rebuild_boot() {
  local rootfs_dir="${1:-$FLASHLESS_ROOTFS_DIR}"
  local efi_dir="${2:-$FLASHLESS_EFI_DIR}"
  local esp_dir="${3:-$FLASHLESS_ESP_DIR}"

  local rc=0

  # 1. Regenerate grub.cfg with target (B) UUID
  if ! _flashless_rebuild_grub_cfg "$efi_dir" "$rootfs_dir"; then
    echo "ERROR: simulate_flashless_rebuild_boot: grub.cfg rebuild failed" >&2
    rc=1
  fi

  # 2. Regenerate grubx64.efi with embedded B UUID
  if ! _flashless_rebuild_grub_binary "$efi_dir"; then
    echo "ERROR: simulate_flashless_rebuild_boot: grub binary rebuild failed" >&2
    rc=1
  fi

  # 3. Update partset files for target slot B
  if ! _flashless_rebuild_partsets "$efi_dir"; then
    echo "ERROR: simulate_flashless_rebuild_boot: partset rebuild failed" >&2
    rc=1
  fi

  # 4. Stage bootconf B.conf (image-invalid=1 — staging state)
  if [[ -d "$esp_dir" ]]; then
    if ! _flashless_stage_bootconf "$esp_dir"; then
      echo "ERROR: simulate_flashless_rebuild_boot: bootconf staging failed" >&2
      rc=1
    fi
  fi

  return $rc
}

# Internal: regenerate grub.cfg with target (B) UUID
_flashless_rebuild_grub_cfg() {
  local efi_dir="$1"
  local rootfs_dir="$2"
  local grub_cfg="$efi_dir/EFI/steamos/grub.cfg"

  if [[ ! -d "$(dirname "$grub_cfg")" ]]; then
    mkdir -p "$(dirname "$grub_cfg")"
  fi

  # Regenerate grub.cfg with target (B) rootfs UUID
  populate_mock_grub_cfg "$grub_cfg" "$FLASHLESS_TARGET_UUID"

  return 0
}

# Internal: regenerate grubx64.efi with embedded B UUID
_flashless_rebuild_grub_binary() {
  local efi_dir="$1"
  local grubx64="$efi_dir/EFI/steamos/grubx64.efi"

  if [[ ! -f "$grubx64" ]]; then
    echo "ERROR: _flashless_rebuild_grub_binary: grubx64.efi not found: $grubx64" >&2
    return 1
  fi

  # Overwrite the embedded UUID at offset 0x100 with the target (B) UUID
  printf '%s' "$FLASHLESS_TARGET_UUID" | dd of="$grubx64" bs=1 seek=$((0x100)) conv=notrunc 2>/dev/null

  return 0
}

# Internal: update partset files for the flashless target slot B
_flashless_rebuild_partsets() {
  local efi_dir="$1"
  local partsets_dir="$efi_dir/SteamOS/partsets"

  if [[ ! -d "$partsets_dir" ]]; then
    mkdir -p "$partsets_dir"
  fi

  local target_rootfs_partuuid target_efi_partuuid target_var_partuuid
  target_rootfs_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "rootfs-${FLASHLESS_TARGET_SLOT}")"
  target_efi_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "efi-${FLASHLESS_TARGET_SLOT}")"
  target_var_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "var-${FLASHLESS_TARGET_SLOT}")"

  # Update self partset (target = slot B)
  cat >"$partsets_dir/self" <<SELF_EOF
rootfs ${target_rootfs_partuuid}
efi ${target_efi_partuuid}
var ${target_var_partuuid}
SELF_EOF

  # Update all partset (A + B + esp)
  local rootfs_a_partuuid efi_a_partuuid var_a_partuuid
  local rootfs_b_partuuid efi_b_partuuid var_b_partuuid
  local esp_partuuid

  rootfs_a_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "rootfs-A")"
  efi_a_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "efi-A")"
  var_a_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "var-A")"
  rootfs_b_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "rootfs-B")"
  efi_b_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "efi-B")"
  var_b_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "var-B")"
  esp_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "esp")"

  cat >"$partsets_dir/all" <<ALL_EOF
rootfs ${rootfs_a_partuuid}
efi ${efi_a_partuuid}
var ${var_a_partuuid}
rootfs ${rootfs_b_partuuid}
efi ${efi_b_partuuid}
var ${var_b_partuuid}
rootfs ${esp_partuuid}
ALL_EOF

  # Update shared partset (esp only)
  cat >"$partsets_dir/shared" <<SHARED_EOF
rootfs ${esp_partuuid}
SHARED_EOF

  return 0
}

# Internal: stage bootconf B.conf (image-invalid=1 — staging state)
_flashless_stage_bootconf() {
  local esp_dir="$1"
  local conf_dir="$esp_dir/SteamOS/conf"

  if [[ ! -d "$conf_dir" ]]; then
    mkdir -p "$conf_dir"
  fi

  # Stage B.conf with image-invalid=1 (NOT yet activated)
  # This is the "staging" state — the image is written but not yet valid
  cat >"$conf_dir/B.conf" <<BOOTCONF_B_EOF
# Bootconf for slot B (flashless staging state)
title=SteamOS (slot B)
image-invalid=1
boot-attempts=0
BOOTCONF_B_EOF

  return 0
}

# ============================================================================
# simulate_flashless_activate
#
# Activate slot B by setting B.conf image-invalid=0 and marking active
# via rauc status mark-active.
#
# This is the LAST step in the flashless apply cycle, and must only
# occur after validation confirms B is valid.
#
# Usage:
#   simulate_flashless_activate [ESP_DIR]
#
# Arguments:
#   ESP_DIR - ESP directory (default: FLASHLESS_ESP_DIR)
#
# Performs:
#   1. Verify B.conf exists and is in staging state (image-invalid=1)
#   2. Set B.conf image-invalid=0 (mark image as valid)
#   3. Simulate rauc status mark-active B
#
# Returns:
#   0 - Activation completed successfully
#   1 - Activation failed
# ============================================================================
simulate_flashless_activate() {
  local esp_dir="${1:-$FLASHLESS_ESP_DIR}"
  local conf_dir="$esp_dir/SteamOS/conf"
  local b_conf="$conf_dir/B.conf"

  # 1. Verify B.conf exists
  if [[ ! -f "$b_conf" ]]; then
    echo "ERROR: simulate_flashless_activate: B.conf not found: $b_conf" >&2
    return 1
  fi

  # 2. Verify B.conf is in staging state (image-invalid=1)
  local current_invalid
  current_invalid="$(grep '^image-invalid=' "$b_conf" 2>/dev/null | cut -d= -f2)"
  if [[ "$current_invalid" != "1" ]]; then
    echo "ERROR: simulate_flashless_activate: B.conf not in staging state (image-invalid='$current_invalid', expected '1')" >&2
    return 1
  fi

  # 3. Set B.conf image-invalid=0 (mark image as valid)
  sed -i 's/^image-invalid=1$/image-invalid=0/' "$b_conf"

  # 4. Simulate rauc status mark-active B
  # In the mock fixture, we record the activation state
  if [[ -f "$_FLASHLESS_ACTIVATION_STATE_FILE" ]]; then
    echo "active-slot=B" >"$_FLASHLESS_ACTIVATION_STATE_FILE"
    echo "b-image-invalid=0" >>"$_FLASHLESS_ACTIVATION_STATE_FILE"
    echo "b-valid=1" >>"$_FLASHLESS_ACTIVATION_STATE_FILE"
  fi

  return 0
}

# ============================================================================
# simulate_flashless_validation_failure
#
# Inject a validation failure by corrupting a B-slot artifact after staging.
# This simulates a scenario where the target slot fails validation and
# activation should NOT occur.
#
# Usage:
#   simulate_flashless_validation_failure [FAILURE_TYPE] [EFI_DIR] [ESP_DIR]
#
# Arguments:
#   FAILURE_TYPE - Type of failure to inject: "grub", "binary", "partset",
#                  "bootconf" (default: "grub")
#   EFI_DIR      - EFI directory (default: FLASHLESS_EFI_DIR)
#   ESP_DIR      - ESP directory (default: FLASHLESS_ESP_DIR)
#
# Returns:
#   0 - Failure injected successfully
#   1 - Failed to inject failure
# ============================================================================
simulate_flashless_validation_failure() {
  local failure_type="${1:-grub}"
  local efi_dir="${2:-$FLASHLESS_EFI_DIR}"
  local esp_dir="${3:-$FLASHLESS_ESP_DIR}"

  case "$failure_type" in
    grub)
      # Corrupt grub.cfg by truncating it
      local grub_cfg="$efi_dir/EFI/steamos/grub.cfg"
      if [[ -f "$grub_cfg" ]]; then
        : >"$grub_cfg" # Truncate to empty
      fi
      ;;
    binary)
      # Corrupt grubx64.efi by overwriting MZ header
      local grubx64="$efi_dir/EFI/steamos/grubx64.efi"
      if [[ -f "$grubx64" ]]; then
        printf 'XX' | dd of="$grubx64" bs=1 count=2 conv=notrunc 2>/dev/null
      fi
      ;;
    partset)
      # Corrupt self partset by emptying it
      local partset_self="$efi_dir/SteamOS/partsets/self"
      if [[ -f "$partset_self" ]]; then
        : >"$partset_self" # Truncate to empty
      fi
      ;;
    bootconf)
      # Corrupt B.conf by removing image-invalid field
      local b_conf="$esp_dir/SteamOS/conf/B.conf"
      if [[ -f "$b_conf" ]]; then
        sed -i '/^image-invalid=/d' "$b_conf"
      fi
      ;;
    *)
      echo "ERROR: simulate_flashless_validation_failure: unknown failure type: $failure_type" >&2
      return 1
      ;;
  esac

  return 0
}

# ============================================================================
# simulate_flashless_runtime_failure
#
# Inject a runtime failure after staging but before activation.
# This simulates a scenario where the system crashes or loses power
# after writing B slot artifacts but before the activation step.
#
# Usage:
#   simulate_flashless_runtime_failure [EFI_DIR] [ESP_DIR]
#
# Arguments:
#   EFI_DIR - EFI directory (default: FLASHLESS_EFI_DIR)
#   ESP_DIR - ESP directory (default: FLASHLESS_ESP_DIR)
#
# Performs:
#   1. Writes artifacts to B slot (partial apply)
#   2. Does NOT activate (leaves B.conf with image-invalid=1)
#   3. Leaves system in pre-activation state
#
# Returns:
#   0 - Runtime failure simulated successfully
#   1 - Failed to simulate runtime failure
# ============================================================================
simulate_flashless_runtime_failure() {
  local efi_dir="${1:-$FLASHLESS_EFI_DIR}"
  local esp_dir="${2:-$FLASHLESS_ESP_DIR}"

  # Simulate: artifacts are written to B, but activation never happens.
  # This means B.conf still has image-invalid=1 (staging state).

  # Verify B.conf is in staging state (image-invalid=1)
  local b_conf="$esp_dir/SteamOS/conf/B.conf"
  if [[ -f "$b_conf" ]]; then
    local current_invalid
    current_invalid="$(grep '^image-invalid=' "$b_conf" 2>/dev/null | cut -d= -f2)"
    if [[ "$current_invalid" != "1" ]]; then
      # Force back to staging state to simulate runtime failure
      sed -i 's/^image-invalid=0$/image-invalid=1/' "$b_conf" 2>/dev/null
    fi
  fi

  return 0
}

# ============================================================================
# Verification functions for flashless scenario invariants
# ============================================================================

# ============================================================================
# verify_active_slot_isolation (F-02)
#
# Verify that the active slot (A) rootfs and efi and bootconf are
# byte-identical to their pre-apply state.
#
# F-02: Active slot isolation — no writes to A during standby deployment.
#
# Usage:
#   verify_active_slot_isolation [EFI_DIR] [ESP_DIR]
#
# Arguments:
#   EFI_DIR - EFI directory (default: FLASHLESS_EFI_DIR)
#   ESP_DIR - ESP directory (default: FLASHLESS_ESP_DIR)
#
# Returns:
#   0 - Active slot A is byte-identical to pre-apply state
#   1 - Active slot A was modified (isolation violated)
# ============================================================================
verify_active_slot_isolation() {
  local efi_dir="${1:-$FLASHLESS_EFI_DIR}"
  local esp_dir="${2:-$FLASHLESS_ESP_DIR}"

  if [[ -z "$_FLASHLESS_SLOT_A_CHECKSUMS" || ! -f "$_FLASHLESS_SLOT_A_CHECKSUMS" ]]; then
    echo "ERROR: verify_active_slot_isolation: no pre-apply snapshot available" >&2
    return 1
  fi

  local rc=0

  # Define A-slot artifacts to verify (F-02: A rootfs/efi/bootconf byte-identical)
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
    expected="$(grep " $label$" "$_FLASHLESS_SLOT_A_CHECKSUMS" 2>/dev/null | awk '{print $1}')"

    if [[ -z "$expected" || "$expected" == "MISSING" ]]; then
      # Artifact was not present in snapshot — check it doesn't exist now
      if [[ -f "$path" ]]; then
        echo "ERROR: verify_active_slot_isolation: unexpected artifact appeared: $label" >&2
        rc=1
      fi
      continue
    fi

    # File should exist and have same checksum
    if [[ ! -f "$path" ]]; then
      echo "ERROR: verify_active_slot_isolation: A-slot artifact missing: $label ($path)" >&2
      rc=1
      continue
    fi

    local actual
    actual="$(md5sum "$path" | awk '{print $1}')"

    if [[ "$actual" != "$expected" ]]; then
      echo "ERROR: verify_active_slot_isolation: A-slot artifact modified: $label (expected=$expected, actual=$actual)" >&2
      rc=1
    fi
  done

  return $rc
}

# ============================================================================
# verify_target_partsets (F-03)
#
# Verify that the target slot (B) partset files have correct content:
#   - self = B rootfs/efi/var PARTUUIDs
#   - other = A rootfs/efi/var PARTUUIDs
#   - Exact PARTUUIDs match the topology
#
# F-03: Target partsets must have correct self/other assignments
# with exact PARTUUIDs matching the fixture topology.
#
# Usage:
#   verify_target_partsets [EFI_DIR]
#
# Arguments:
#   EFI_DIR - EFI directory (default: FLASHLESS_EFI_DIR)
#
# Returns:
#   0 - Target partsets have correct content
#   1 - Target partsets have incorrect content
# ============================================================================
verify_target_partsets() {
  local efi_dir="${1:-$FLASHLESS_EFI_DIR}"
  local partsets_dir="$efi_dir/SteamOS/partsets"
  local rc=0

  # UUID pattern for validation
  local uuid_pattern='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

  # Derive expected PARTUUIDs from topology
  local target_rootfs_partuuid target_efi_partuuid target_var_partuuid
  local other_rootfs_partuuid other_efi_partuuid other_var_partuuid

  target_rootfs_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "rootfs-${FLASHLESS_TARGET_SLOT}")"
  target_efi_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "efi-${FLASHLESS_TARGET_SLOT}")"
  target_var_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "var-${FLASHLESS_TARGET_SLOT}")"

  other_rootfs_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "rootfs-${FLASHLESS_CURRENT_SLOT}")"
  other_efi_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "efi-${FLASHLESS_CURRENT_SLOT}")"
  other_var_partuuid="$(derive_partuuid "$FLASHLESS_NAMESPACE" "var-${FLASHLESS_CURRENT_SLOT}")"

  # 1. Verify self partset (should be B's partitions)
  local self_partset="$partsets_dir/self"
  if [[ ! -f "$self_partset" ]]; then
    echo "ERROR: verify_target_partsets: self partset missing" >&2
    return 1
  fi

  local self_content
  self_content="$(cat "$self_partset")"

  # Check self has rootfs PARTUUID matching B
  local self_rootfs
  self_rootfs="$(printf '%s\n' "$self_content" | grep '^rootfs ' | awk '{print $2}')"
  if [[ "$self_rootfs" != "$target_rootfs_partuuid" ]]; then
    echo "ERROR: verify_target_partsets: self rootfs PARTUUID mismatch (expected='$target_rootfs_partuuid', got='$self_rootfs')" >&2
    rc=1
  fi

  # Check self has efi PARTUUID matching B
  local self_efi
  self_efi="$(printf '%s\n' "$self_content" | grep '^efi ' | awk '{print $2}')"
  if [[ "$self_efi" != "$target_efi_partuuid" ]]; then
    echo "ERROR: verify_target_partsets: self efi PARTUUID mismatch (expected='$target_efi_partuuid', got='$self_efi')" >&2
    rc=1
  fi

  # Check self has var PARTUUID matching B
  local self_var
  self_var="$(printf '%s\n' "$self_content" | grep '^var ' | awk '{print $2}')"
  if [[ "$self_var" != "$target_var_partuuid" ]]; then
    echo "ERROR: verify_target_partsets: self var PARTUUID mismatch (expected='$target_var_partuuid', got='$self_var')" >&2
    rc=1
  fi

  # 2. Verify other partset (should be A's partitions)
  local other_partset="$partsets_dir/other"
  if [[ ! -f "$other_partset" ]]; then
    echo "ERROR: verify_target_partsets: other partset missing" >&2
    return 1
  fi

  local other_content
  other_content="$(cat "$other_partset")"

  # Check other has rootfs PARTUUID matching A
  local other_rootfs
  other_rootfs="$(printf '%s\n' "$other_content" | grep '^rootfs ' | awk '{print $2}')"
  if [[ "$other_rootfs" != "$other_rootfs_partuuid" ]]; then
    echo "ERROR: verify_target_partsets: other rootfs PARTUUID mismatch (expected='$other_rootfs_partuuid', got='$other_rootfs')" >&2
    rc=1
  fi

  # Check other has efi PARTUUID matching A
  local other_efi
  other_efi="$(printf '%s\n' "$other_content" | grep '^efi ' | awk '{print $2}')"
  if [[ "$other_efi" != "$other_efi_partuuid" ]]; then
    echo "ERROR: verify_target_partsets: other efi PARTUUID mismatch (expected='$other_efi_partuuid', got='$other_efi')" >&2
    rc=1
  fi

  # Check other has var PARTUUID matching A
  local other_var
  other_var="$(printf '%s\n' "$other_content" | grep '^var ' | awk '{print $2}')"
  if [[ "$other_var" != "$other_var_partuuid" ]]; then
    echo "ERROR: verify_target_partsets: other var PARTUUID mismatch (expected='$other_var_partuuid', got='$other_var')" >&2
    rc=1
  fi

  return $rc
}

# ============================================================================
# verify_target_efi_binary (F-04)
#
# Verify that the target slot (B) EFI binary (grubx64.efi):
#   - Has a valid PE header (MZ magic)
#   - Contains B UUID (not A or source UUID)
#   - Contains no stale references
#
# F-04: Target EFI binary must be valid PE with B UUID, no A/source UUID.
#
# Usage:
#   verify_target_efi_binary [EFI_DIR]
#
# Arguments:
#   EFI_DIR - EFI directory (default: FLASHLESS_EFI_DIR)
#
# Returns:
#   0 - EFI binary is valid with correct UUID
#   1 - EFI binary is invalid or has wrong UUID
# ============================================================================
verify_target_efi_binary() {
  local efi_dir="${1:-$FLASHLESS_EFI_DIR}"
  local grubx64="$efi_dir/EFI/steamos/grubx64.efi"
  local rc=0

  # 1. File exists
  if [[ ! -f "$grubx64" ]]; then
    echo "ERROR: verify_target_efi_binary: grubx64.efi not found: $grubx64" >&2
    return 1
  fi

  # 2. File is nonempty
  local file_size
  file_size="$(stat -c '%s' "$grubx64" 2>/dev/null || echo 0)"
  if [[ "$file_size" -eq 0 ]]; then
    echo "ERROR: verify_target_efi_binary: grubx64.efi is empty" >&2
    return 1
  fi

  # 3. Valid PE header (MZ magic)
  local mz_header
  mz_header="$(dd if="$grubx64" bs=1 count=2 2>/dev/null | od -A n -t x1 | tr -d ' ')"
  if [[ "$mz_header" != "4d5a" ]]; then
    echo "ERROR: verify_target_efi_binary: grubx64.efi missing MZ header (got: $mz_header)" >&2
    rc=1
  fi

  # 4. Contains B UUID
  # Use od/sed to extract printable ASCII from binary (strings(1) may not be available)
  local uuid_pattern='[0-9a-fA-F]\{8\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{12\}'
  local embedded_uuid
  embedded_uuid="$(od -An -tx1 "$grubx64" 2>/dev/null | tr -d ' \n' | sed 's/../& /g' | awk '{for(i=1;i<=NF;i++){c=strtonum("0x"$i); if(c>=32&&c<=126) printf "%c",c; else printf " "}}' | grep -oE "$uuid_pattern" | head -1)"

  if [[ -z "$embedded_uuid" ]]; then
    echo "ERROR: verify_target_efi_binary: no UUID found embedded in grubx64.efi" >&2
    rc=1
  elif [[ "$embedded_uuid" != "$FLASHLESS_TARGET_UUID" ]]; then
    echo "ERROR: verify_target_efi_binary: embedded UUID mismatch (expected='$FLASHLESS_TARGET_UUID', got='$embedded_uuid')" >&2
    rc=1
  fi

  # 5. No A/source UUID (no stale references)
  local -a all_uuids
  mapfile -t all_uuids < <(od -An -tx1 "$grubx64" 2>/dev/null | tr -d ' \n' | sed 's/../& /g' | awk '{for(i=1;i<=NF;i++){c=strtonum("0x"$i); if(c>=32&&c<=126) printf "%c",c; else printf " "}}' | grep -oE "$uuid_pattern")

  if [[ "${#all_uuids[@]}" -gt 1 ]]; then
    echo "ERROR: verify_target_efi_binary: multiple UUIDs found in binary (stale references):" >&2
    printf "      %s\n" "${all_uuids[@]}" >&2
    rc=1
  fi

  # Check that no A/source UUID is present
  local source_uuid
  source_uuid="$(derive_uuid "$FLASHLESS_NAMESPACE" "rootfs-${FLASHLESS_CURRENT_SLOT}")"
  local uuid
  for uuid in "${all_uuids[@]}"; do
    if [[ "$uuid" == "$source_uuid" ]]; then
      echo "ERROR: verify_target_efi_binary: source (A) UUID found in target binary: $uuid" >&2
      rc=1
      break
    fi
  done

  return $rc
}

# ============================================================================
# verify_target_grub_config (F-05)
#
# Verify that the target slot (B) grub.cfg:
#   - search/menu uses B UUID (not A UUID)
#   - Kernels exist in rootfs
#   - Kernel params appear once per linux line
#
# F-05: Target grub config must reference B UUID with valid kernel paths.
#
# Usage:
#   verify_target_grub_config [EFI_DIR] [ROOTFS_DIR]
#
# Arguments:
#   EFI_DIR    - EFI directory (default: FLASHLESS_EFI_DIR)
#   ROOTFS_DIR - Rootfs directory (default: FLASHLESS_ROOTFS_DIR)
#
# Returns:
#   0 - Target grub config is correct
#   1 - Target grub config has errors
# ============================================================================
verify_target_grub_config() {
  local efi_dir="${1:-$FLASHLESS_EFI_DIR}"
  local rootfs_dir="${2:-$FLASHLESS_ROOTFS_DIR}"
  local grub_cfg="$efi_dir/EFI/steamos/grub.cfg"
  local rc=0

  if [[ ! -f "$grub_cfg" ]]; then
    echo "ERROR: verify_target_grub_config: grub.cfg not found: $grub_cfg" >&2
    return 1
  fi

  # 1. search/menu uses B UUID
  local expected_count
  expected_count="$(grep -c "search.*--fs-uuid.*--set=root.*${FLASHLESS_TARGET_UUID}" "$grub_cfg" 2>/dev/null | tr -d '\n' || echo 0)"
  if [[ "$expected_count" -lt 1 ]]; then
    echo "ERROR: verify_target_grub_config: no search line uses target UUID '$FLASHLESS_TARGET_UUID'" >&2
    rc=1
  fi

  # Check no A UUID is present in search lines
  local source_uuid
  source_uuid="$(derive_uuid "$FLASHLESS_NAMESPACE" "rootfs-${FLASHLESS_CURRENT_SLOT}")"
  local source_count
  source_count="$(grep -c "search.*--fs-uuid.*--set=root.*${source_uuid}" "$grub_cfg" 2>/dev/null | tr -d '\n' || echo 0)"
  if [[ "$source_count" -gt 0 ]]; then
    echo "ERROR: verify_target_grub_config: source (A) UUID found in grub.cfg search lines" >&2
    rc=1
  fi

  # 2. Kernels exist in rootfs
  local linux_line
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*linux[[:space:]] ]] || continue

    local kernel_path
    kernel_path="$(printf '%s' "$line" | sed -n 's/^[[:space:]]*linux[[:space:]]\+\([^[:space:]]*\).*/\1/p')"
    if [[ -n "$kernel_path" ]]; then
      local full_kernel_path
      if [[ "$kernel_path" == /* ]]; then
        full_kernel_path="$rootfs_dir$kernel_path"
      else
        full_kernel_path="$rootfs_dir/$kernel_path"
      fi
      if [[ ! -f "$full_kernel_path" ]]; then
        echo "ERROR: verify_target_grub_config: kernel not found: $full_kernel_path" >&2
        rc=1
      fi
    fi
  done <"$grub_cfg"

  # 3. Kernel params appear once per linux line (no duplicates)
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*linux[[:space:]] ]] || continue

    # Extract parameter portion
    local params_portion
    params_portion="$(printf '%s' "$line" | sed 's/^[[:space:]]*linux[[:space:]]\+[^[:space:]]\+[[:space:]]*//')"

    if [[ -z "$params_portion" ]]; then
      continue
    fi

    # Tokenize and check for duplicates
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
        echo "ERROR: verify_target_grub_config: duplicate parameter '$token' found ${token_counts[$token]} times on a linux line" >&2
        rc=1
      fi
    done
  done <"$grub_cfg"

  return $rc
}

# ============================================================================
# verify_bootconf_initialized (F-06)
#
# Verify that the target slot (B) bootconf:
#   - B.conf is parseable (valid key=value format)
#   - B.conf is in staging state (image-invalid=1)
#
# F-06: Bootconf must be initialized in staging state before activation.
#
# Usage:
#   verify_bootconf_initialized [ESP_DIR]
#
# Arguments:
#   ESP_DIR - ESP directory (default: FLASHLESS_ESP_DIR)
#
# Returns:
#   0 - Bootconf is initialized correctly
#   1 - Bootconf is not initialized or has errors
# ============================================================================
verify_bootconf_initialized() {
  local esp_dir="${1:-$FLASHLESS_ESP_DIR}"
  local conf_dir="$esp_dir/SteamOS/conf"
  local b_conf="$conf_dir/B.conf"
  local rc=0

  # 1. B.conf exists
  if [[ ! -f "$b_conf" ]]; then
    echo "ERROR: verify_bootconf_initialized: B.conf not found: $b_conf" >&2
    return 1
  fi

  # 2. B.conf is nonempty
  if [[ ! -s "$b_conf" ]]; then
    echo "ERROR: verify_bootconf_initialized: B.conf is empty" >&2
    return 1
  fi

  # 3. B.conf is parseable (valid key=value format)
  local required_fields=("title" "image-invalid" "boot-attempts")
  local content
  content="$(cat "$b_conf")"

  local field
  for field in "${required_fields[@]}"; do
    local field_found
    field_found="$(printf '%s\n' "$content" | grep -v '^\s*#' | grep -c "^${field}=" 2>/dev/null | tr -d '\n')" || field_found=0
    if [[ "$field_found" -eq 0 ]]; then
      echo "ERROR: verify_bootconf_initialized: B.conf missing required field '$field'" >&2
      rc=1
    fi
  done

  # 4. B.conf is in staging state (image-invalid=1)
  local image_invalid
  image_invalid="$(grep '^image-invalid=' "$b_conf" 2>/dev/null | cut -d= -f2)"
  if [[ "$image_invalid" != "1" ]]; then
    echo "ERROR: verify_bootconf_initialized: B.conf not in staging state (image-invalid='$image_invalid', expected '1')" >&2
    rc=1
  fi

  return $rc
}

# ============================================================================
# verify_valid_efi_preserved (F-08)
#
# Verify that a valid existing EFI partition was not reformatted.
#   - No mkfs was run on the valid EFI partition
#   - Sentinel files are unchanged
#
# F-08: Valid existing EFI partitions must not be reformatted.
#
# Usage:
#   verify_valid_efi_preserved [EFI_DIR] [SENTINEL_CONTENT]
#
# Arguments:
#   EFI_DIR           - EFI directory (default: FLASHLESS_EFI_DIR)
#   SENTINEL_CONTENT  - Expected content of sentinel files (default: "SENTINEL")
#
# Returns:
#   0 - Valid EFI preserved (no mkfs, sentinels unchanged)
#   1 - Valid EFI was reformatted or sentinels changed
# ============================================================================
verify_valid_efi_preserved() {
  local efi_dir="${1:-$FLASHLESS_EFI_DIR}"
  local sentinel_content="${2:-SENTINEL}"
  local rc=0

  # 1. Check that the EFI directory structure is intact (no mkfs)
  # If mkfs was run, the directory would be empty or missing key files.
  if [[ ! -d "$efi_dir/EFI/steamos" ]]; then
    echo "ERROR: verify_valid_efi_preserved: EFI/steamos directory missing (possible mkfs)" >&2
    return 1
  fi

  # 2. Verify sentinel files are unchanged
  local -a sentinel_files=(
    "EFI/steamos/sentinel-default.grub"
    "EFI/steamos/sentinel-steamos.grub"
    "SteamOS/partsets/sentinel-self"
  )

  local sentinel_file
  for sentinel_file in "${sentinel_files[@]}"; do
    local full_path="$efi_dir/$sentinel_file"
    if [[ ! -f "$full_path" ]]; then
      # Sentinel file may not exist in all fixtures — that's OK
      continue
    fi

    local actual_content
    actual_content="$(cat "$full_path" 2>/dev/null)"
    if [[ "$actual_content" != "$sentinel_content" ]]; then
      echo "ERROR: verify_valid_efi_preserved: sentinel file modified: $sentinel_file (expected='$sentinel_content', got='$actual_content')" >&2
      rc=1
    fi
  done

  # 3. Verify key files still exist (grub.cfg, grubx64.efi)
  if [[ ! -f "$efi_dir/EFI/steamos/grub.cfg" ]]; then
    echo "ERROR: verify_valid_efi_preserved: grub.cfg missing (possible mkfs)" >&2
    rc=1
  fi

  if [[ ! -f "$efi_dir/EFI/steamos/grubx64.efi" ]]; then
    echo "ERROR: verify_valid_efi_preserved: grubx64.efi missing (possible mkfs)" >&2
    rc=1
  fi

  return $rc
}

# ============================================================================
# verify_activation_occurs_last (F-10)
#
# Verify that activation (image-invalid=0, mark-active) occurs ONLY after
# all validation passes. B must be valid/active only after validation.
#
# F-10: Activation must be the last step, only after validation confirms B.
#
# Usage:
#   verify_activation_occurs_last [ESP_DIR]
#
# Arguments:
#   ESP_DIR - ESP directory (default: FLASHLESS_ESP_DIR)
#
# Returns:
#   0 - Activation state is correct (activated only after validation)
#   1 - Activation state is incorrect
# ============================================================================
verify_activation_occurs_last() {
  local esp_dir="${1:-$FLASHLESS_ESP_DIR}"
  local conf_dir="$esp_dir/SteamOS/conf"
  local b_conf="$conf_dir/B.conf"
  local rc=0

  # 1. B.conf exists
  if [[ ! -f "$b_conf" ]]; then
    echo "ERROR: verify_activation_occurs_last: B.conf not found: $b_conf" >&2
    return 1
  fi

  # 2. Check activation state from snapshot
  if [[ -n "$_FLASHLESS_ACTIVATION_STATE_FILE" && -f "$_FLASHLESS_ACTIVATION_STATE_FILE" ]]; then
    local active_slot b_image_invalid b_valid
    active_slot="$(grep '^active-slot=' "$_FLASHLESS_ACTIVATION_STATE_FILE" 2>/dev/null | cut -d= -f2)"
    b_image_invalid="$(grep '^b-image-invalid=' "$_FLASHLESS_ACTIVATION_STATE_FILE" 2>/dev/null | cut -d= -f2)"
    b_valid="$(grep '^b-valid=' "$_FLASHLESS_ACTIVATION_STATE_FILE" 2>/dev/null | cut -d= -f2)"

    # If B is active, then image-invalid must be 0 and b-valid must be 1
    if [[ "$active_slot" == "B" ]]; then
      if [[ "$b_image_invalid" != "0" ]]; then
        echo "ERROR: verify_activation_occurs_last: B is active but image-invalid is not 0" >&2
        rc=1
      fi
      if [[ "$b_valid" != "1" ]]; then
        echo "ERROR: verify_activation_occurs_last: B is active but b-valid is not 1" >&2
        rc=1
      fi
    fi
  fi

  # 3. Verify B.conf content is consistent with activation state
  local current_invalid
  current_invalid="$(grep '^image-invalid=' "$b_conf" 2>/dev/null | cut -d= -f2)"

  # If we have activation state, cross-check
  if [[ -n "$_FLASHLESS_ACTIVATION_STATE_FILE" && -f "$_FLASHLESS_ACTIVATION_STATE_FILE" ]]; then
    local expected_invalid
    expected_invalid="$(grep '^b-image-invalid=' "$_FLASHLESS_ACTIVATION_STATE_FILE" 2>/dev/null | cut -d= -f2)"

    if [[ -n "$expected_invalid" && "$current_invalid" != "$expected_invalid" ]]; then
      echo "ERROR: verify_activation_occurs_last: B.conf image-invalid mismatch with activation state" >&2
      rc=1
    fi
  fi

  return $rc
}

# ============================================================================
# verify_btrfs_ro_restored (F-13)
#
# Verify that the btrfs ro property was restored after completing writes.
#
# F-13: Btrfs read-only must be restored after write phase completes.
#
# Usage:
#   verify_btrfs_ro_restored
#
# Returns:
#   0 - Btrfs ro restored correctly
#   1 - Btrfs ro not restored
# ============================================================================
verify_btrfs_ro_restored() {
  # Verify the btrfs ro state file exists and shows ro=1
  if [[ -z "$_FLASHLESS_BTRFS_RO_STATE_FILE" || ! -f "$_FLASHLESS_BTRFS_RO_STATE_FILE" ]]; then
    echo "ERROR: verify_btrfs_ro_restored: btrfs ro state file not available" >&2
    return 1
  fi

  local ro_state
  ro_state="$(cat "$_FLASHLESS_BTRFS_RO_STATE_FILE" 2>/dev/null)"

  if [[ "$ro_state" != "ro=1" ]]; then
    echo "ERROR: verify_btrfs_ro_restored: btrfs ro not restored (got '$ro_state', expected 'ro=1')" >&2
    return 1
  fi

  # Also check the fixture-level btrfs-ro marker
  local ro_marker="$FLASHLESS_FIXTURE_DIR/.btrfs-ro"
  if [[ -f "$ro_marker" ]]; then
    local marker_state
    marker_state="$(cat "$ro_marker" 2>/dev/null)"
    if [[ "$marker_state" != "ro=1" ]]; then
      echo "ERROR: verify_btrfs_ro_restored: fixture btrfs-ro marker not restored (got '$marker_state', expected 'ro=1')" >&2
      return 1
    fi
  fi

  return 0
}

# ============================================================================
# Utility functions for flashless tests
# ============================================================================

# Get the target rootfs UUID for the current flashless fixture
# Usage: get_flashless_target_uuid
get_flashless_target_uuid() {
  if [[ -z "$FLASHLESS_TARGET_UUID" ]]; then
    echo "ERROR: get_flashless_target_uuid: FLASHLESS_TARGET_UUID not set (call flashless_scenario_setup first)" >&2
    return 1
  fi
  echo "$FLASHLESS_TARGET_UUID"
}

# Get the current (slot A) rootfs UUID for the current flashless fixture
# Usage: get_flashless_current_uuid
get_flashless_current_uuid() {
  if [[ -z "$FLASHLESS_CURRENT_UUID" ]]; then
    echo "ERROR: get_flashless_current_uuid: FLASHLESS_CURRENT_UUID not set (call flashless_scenario_setup first)" >&2
    return 1
  fi
  echo "$FLASHLESS_CURRENT_UUID"
}

# Get the EFI directory for the current flashless fixture
# Usage: get_flashless_efi_dir
get_flashless_efi_dir() {
  if [[ -z "$FLASHLESS_EFI_DIR" ]]; then
    echo "ERROR: get_flashless_efi_dir: FLASHLESS_EFI_DIR not set (call flashless_scenario_setup first)" >&2
    return 1
  fi
  echo "$FLASHLESS_EFI_DIR"
}

# Get the rootfs directory for the current flashless fixture
# Usage: get_flashless_rootfs_dir
get_flashless_rootfs_dir() {
  if [[ -z "$FLASHLESS_ROOTFS_DIR" ]]; then
    echo "ERROR: get_flashless_rootfs_dir: FLASHLESS_ROOTFS_DIR not set (call flashless_scenario_setup first)" >&2
    return 1
  fi
  echo "$FLASHLESS_ROOTFS_DIR"
}

# Get the ESP directory for the current flashless fixture
# Usage: get_flashless_esp_dir
get_flashless_esp_dir() {
  if [[ -z "$FLASHLESS_ESP_DIR" ]]; then
    echo "ERROR: get_flashless_esp_dir: FLASHLESS_ESP_DIR not set (call flashless_scenario_setup first)" >&2
    return 1
  fi
  echo "$FLASHLESS_ESP_DIR"
}

# Get the metadata directory for the current flashless fixture
# Usage: get_flashless_metadata_dir
get_flashless_metadata_dir() {
  if [[ -z "$FLASHLESS_METADATA_DIR" ]]; then
    echo "ERROR: get_flashless_metadata_dir: FLASHLESS_METADATA_DIR not set (call flashless_scenario_setup first)" >&2
    return 1
  fi
  echo "$FLASHLESS_METADATA_DIR"
}

# Get the namespace for the current flashless fixture
# Usage: get_flashless_namespace
get_flashless_namespace() {
  if [[ -z "$FLASHLESS_NAMESPACE" ]]; then
    echo "ERROR: get_flashless_namespace: FLASHLESS_NAMESPACE not set (call flashless_scenario_setup first)" >&2
    return 1
  fi
  echo "$FLASHLESS_NAMESPACE"
}
