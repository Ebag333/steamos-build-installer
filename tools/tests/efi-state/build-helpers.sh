#!/bin/bash
#
# tools/tests/efi-state/build-helpers.sh
# Build-specific test infrastructure for EFI state application tests.
#
# Provides helper functions for Build scenario tests (single-slot, target A),
# including fixture setup/teardown, EFI state application simulation,
# GRUB parameter manipulation, error injection, host isolation verification,
# and sentinel file management.
#
# Usage:
#   source tools/tests/efi-state/build-helpers.sh
#
# Dependencies:
#   - test-harness.sh   (assertion helpers, test lifecycle)
#   - fixture-factory.sh (mock fixture creation/destruction)
#   - topology.sh        (deterministic UUID/PARTUUID generation)
#
# Design constraints:
#   - Build scenario: single-slot, target A only
#   - Functions are composable and reusable across test cases
#   - Support both happy path and error injection scenarios

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "build-helpers.sh is a library — source it, don't run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Guard: ensure required libraries are loaded
# ---------------------------------------------------------------------------
if ! declare -f test_harness_init >/dev/null 2>&1; then
  echo "ERROR: build-helpers.sh requires test-harness.sh (source it first)." >&2
  return 1 2>/dev/null || exit 1
fi

if ! declare -f create_mock_boot_fixture >/dev/null 2>&1; then
  echo "ERROR: build-helpers.sh requires fixture-factory.sh (source it first)." >&2
  return 1 2>/dev/null || exit 1
fi

# ---------------------------------------------------------------------------
# Build scenario constants
# ---------------------------------------------------------------------------
BUILD_SLOT_COUNT=1
BUILD_TARGET_SLOT="A"
BUILD_SCENARIO="build"

# ============================================================================
# build_scenario_setup
#
# Create a build-specific mock fixture (single-slot, target A).
#
# Usage:
#   build_scenario_setup
#
# Sets the following global variables for test access:
#   BUILD_FIXTURE_DIR   - Root of the mock fixture tree
#   BUILD_ROOTFS_DIR    - Mock rootfs mount point
#   BUILD_EFI_DIR       - Mock EFI partition mount point
#   BUILD_ESP_DIR       - Mock shared ESP mount point
#   BUILD_METADATA_DIR  - Mock metadata directory
#   BUILD_TARGET_UUID   - Target rootfs UUID
#   BUILD_NAMESPACE     - Test namespace for UUID derivation
#
# The fixture is created in a temporary directory that is automatically
# cleaned up by build_scenario_teardown().
# ============================================================================
BUILD_FIXTURE_DIR=""
BUILD_ROOTFS_DIR=""
BUILD_EFI_DIR=""
BUILD_ESP_DIR=""
BUILD_METADATA_DIR=""
BUILD_TARGET_UUID=""
BUILD_NAMESPACE=""

build_scenario_setup() {
  # Create temporary base directory
  BUILD_FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/build-test-XXXXXX")"
  if [[ -z "$BUILD_FIXTURE_DIR" || ! -d "$BUILD_FIXTURE_DIR" ]]; then
    echo "ERROR: build_scenario_setup: failed to create temp directory" >&2
    return 1
  fi

  BUILD_NAMESPACE="build-${BUILD_TARGET_SLOT}-$$"

  # Use fixture-factory to create the complete mock fixture
  create_mock_boot_fixture "$BUILD_FIXTURE_DIR" "$BUILD_SCENARIO" "$BUILD_TARGET_SLOT" "$BUILD_NAMESPACE"

  # Set convenience variables for test access
  BUILD_ROOTFS_DIR="$BUILD_FIXTURE_DIR/rootfs"
  BUILD_EFI_DIR="$BUILD_FIXTURE_DIR/efi"
  BUILD_ESP_DIR="$BUILD_FIXTURE_DIR/esp"
  BUILD_METADATA_DIR="$BUILD_FIXTURE_DIR/metadata"

  # Derive the target rootfs UUID (consistent with fixture-factory)
  BUILD_TARGET_UUID="$(derive_uuid "$BUILD_NAMESPACE" "rootfs-A")"

  # Verify fixture was created correctly
  if [[ ! -d "$BUILD_EFI_DIR/EFI/steamos" ]]; then
    echo "ERROR: build_scenario_setup: EFI fixture directory not created" >&2
    build_scenario_teardown
    return 1
  fi

  if [[ ! -f "$BUILD_EFI_DIR/EFI/steamos/grub.cfg" ]]; then
    echo "ERROR: build_scenario_setup: grub.cfg not created" >&2
    build_scenario_teardown
    return 1
  fi

  return 0
}

# ============================================================================
# build_scenario_teardown
#
# Clean up build fixture directory and reset global state.
#
# Usage:
#   build_scenario_teardown
#
# This function is idempotent — safe to call multiple times.
# Designed to be used as a cleanup handler or trap target.
# ============================================================================
build_scenario_teardown() {
  if [[ -n "$BUILD_FIXTURE_DIR" && -d "$BUILD_FIXTURE_DIR" ]]; then
    destroy_mock_fixture "$BUILD_FIXTURE_DIR"
  fi

  BUILD_FIXTURE_DIR=""
  BUILD_ROOTFS_DIR=""
  BUILD_EFI_DIR=""
  BUILD_ESP_DIR=""
  BUILD_METADATA_DIR=""
  BUILD_TARGET_UUID=""
  BUILD_NAMESPACE=""
}

# ============================================================================
# simulate_efi_state_apply
#
# Apply EFI state changes to the build fixture, simulating the complete
# EFI state application mechanism.
#
# Usage:
#   simulate_efi_state_apply [ROOTFS_DIR] [EFI_DIR] [ESP_DIR]
#
# Arguments:
#   ROOTFS_DIR - Rootfs directory (default: BUILD_ROOTFS_DIR)
#   EFI_DIR    - EFI directory (default: BUILD_EFI_DIR)
#   ESP_DIR    - ESP directory (default: BUILD_ESP_DIR)
#
# Performs:
#   1. Patch grub.cfg with target UUID and kernel params
#   2. Create/update partset files (self, all, shared)
#   3. Create/update bootconf files (A.conf)
#
# Returns:
#   0 - All operations completed successfully
#   1 - One or more operations failed
# ============================================================================
simulate_efi_state_apply() {
  local rootfs_dir="${1:-$BUILD_ROOTFS_DIR}"
  local efi_dir="${2:-$BUILD_EFI_DIR}"
  local esp_dir="${3:-$BUILD_ESP_DIR}"

  local rc=0

  # Validate inputs
  if [[ ! -d "$rootfs_dir" ]]; then
    echo "ERROR: simulate_efi_state_apply: rootfs_dir not found: $rootfs_dir" >&2
    return 1
  fi
  if [[ ! -d "$efi_dir" ]]; then
    echo "ERROR: simulate_efi_state_apply: efi_dir not found: $efi_dir" >&2
    return 1
  fi

  # 1. Patch grub.cfg
  if ! _simulate_patch_grub_cfg "$efi_dir" "$rootfs_dir"; then
    echo "ERROR: simulate_efi_state_apply: grub.cfg patching failed" >&2
    rc=1
  fi

  # 2. Create/update partset files
  if ! _simulate_create_partsets "$efi_dir"; then
    echo "ERROR: simulate_efi_state_apply: partset creation failed" >&2
    rc=1
  fi

  # 3. Create/update bootconf files
  if [[ -d "$esp_dir" ]]; then
    if ! _simulate_create_bootconf "$esp_dir"; then
      echo "ERROR: simulate_efi_state_apply: bootconf creation failed" >&2
      rc=1
    fi
  fi

  return $rc
}

# Internal: patch grub.cfg with target UUID and kernel parameters
_simulate_patch_grub_cfg() {
  local efi_dir="$1"
  local rootfs_dir="$2"
  local grub_cfg="$efi_dir/EFI/steamos/grub.cfg"

  if [[ ! -f "$grub_cfg" ]]; then
    echo "ERROR: _simulate_patch_grub_cfg: grub.cfg not found: $grub_cfg" >&2
    return 1
  fi

  # Create a backup before patching
  cp "$grub_cfg" "${grub_cfg}.bak"

  # Regenerate grub.cfg with target UUID
  populate_mock_grub_cfg "$grub_cfg" "$BUILD_TARGET_UUID"

  return 0
}

# Internal: create/update partset files
_simulate_create_partsets() {
  local efi_dir="$1"
  local partsets_dir="$efi_dir/SteamOS/partsets"

  if [[ ! -d "$partsets_dir" ]]; then
    mkdir -p "$partsets_dir"
  fi

  # Create/update self partset (always slot A for build scenario)
  local rootfs_a_partuuid efi_a_partuuid var_a_partuuid
  rootfs_a_partuuid="$(derive_partuuid "$BUILD_NAMESPACE" "rootfs-A")"
  efi_a_partuuid="$(derive_partuuid "$BUILD_NAMESPACE" "efi-A")"
  var_a_partuuid="$(derive_partuuid "$BUILD_NAMESPACE" "var-A")"

  cat >"$partsets_dir/self" <<SELF_EOF
rootfs ${rootfs_a_partuuid}
efi ${efi_a_partuuid}
var ${var_a_partuuid}
SELF_EOF

  # Create/update all partset (single-slot: A + esp)
  local esp_partuuid
  esp_partuuid="$(derive_partuuid "$BUILD_NAMESPACE" "esp")"

  cat >"$partsets_dir/all" <<ALL_EOF
rootfs ${rootfs_a_partuuid}
efi ${efi_a_partuuid}
var ${var_a_partuuid}
rootfs ${esp_partuuid}
ALL_EOF

  # Create/update shared partset (esp only)
  cat >"$partsets_dir/shared" <<SHARED_EOF
rootfs ${esp_partuuid}
SHARED_EOF

  return 0
}

# Internal: create/update bootconf files
_simulate_create_bootconf() {
  local esp_dir="$1"
  local conf_dir="$esp_dir/SteamOS/conf"

  if [[ ! -d "$conf_dir" ]]; then
    mkdir -p "$conf_dir"
  fi

  # Create/update A.conf (target slot)
  cat >"$conf_dir/A.conf" <<BOOTCONF_A_EOF
# Bootconf for slot A (build scenario)
title=SteamOS (slot A)
image-invalid=0
boot-attempts=0
BOOTCONF_A_EOF

  return 0
}

# ============================================================================
# simulate_grub_param_add
#
# Add parameters to grub.cfg (simulates reconcile_grub behavior).
#
# Usage:
#   simulate_grub_param_add GRUB_CFG_PATH PARAM1 [PARAM2 ...]
#
# Arguments:
#   GRUB_CFG_PATH - Path to grub.cfg file
#   PARAM1...     - Kernel parameters to add
#
# This function:
#   1. Checks if each parameter is already present (idempotent)
#   2. Appends missing parameters to all linux command lines
#   3. Preserves existing grub.cfg structure
#
# Returns:
#   0 - All parameters added successfully
#   1 - Failed to add parameters
# ============================================================================
simulate_grub_param_add() {
  local grub_cfg="${1:?simulate_grub_param_add: missing GRUB_CFG_PATH}"
  shift
  local -a params=("$@")

  if [[ ${#params[@]} -eq 0 ]]; then
    echo "WARNING: simulate_grub_param_add: no parameters specified" >&2
    return 0
  fi

  if [[ ! -f "$grub_cfg" ]]; then
    echo "ERROR: simulate_grub_param_add: grub.cfg not found: $grub_cfg" >&2
    return 1
  fi

  # Create backup
  cp "$grub_cfg" "${grub_cfg}.bak"

  # For each parameter, check if it exists and add if missing
  local param
  for param in "${params[@]}"; do
    # Check if parameter is already present on any linux line (whole-token match)
    local _found=0 _line
    while IFS= read -r _line; do
      [[ " ${_line%%#*} " == *" ${param} "* ]] && {
        _found=1
        break
      }
    done < <(grep 'linux' "$grub_cfg" 2>/dev/null)
    [[ "$_found" -eq 1 ]] && continue # Already present, skip (idempotent)

    # Add parameter to all linux lines
    # Use sed to append parameter to lines starting with 'linux'
    sed -i "s|^\([[:space:]]*linux .*\)$|\1 ${param}|" "$grub_cfg"
  done

  return 0
}

# ============================================================================
# simulate_grub_param_add_idempotent
#
# Add parameters twice and verify no duplicates result.
#
# Usage:
#   simulate_grub_param_add_idempotent GRUB_CFG_PATH PARAM1 [PARAM2 ...]
#
# Arguments:
#   GRUB_CFG_PATH - Path to grub.cfg file
#   PARAM1...     - Kernel parameters to add
#
# This function:
#   1. Adds parameters once
#   2. Adds parameters again
#   3. Verifies no duplicate parameters exist
#
# Returns:
#   0 - Idempotency verified (no duplicates)
#   1 - Duplicates detected or operation failed
# ============================================================================
simulate_grub_param_add_idempotent() {
  local grub_cfg="${1:?simulate_grub_param_add_idempotent: missing GRUB_CFG_PATH}"
  shift
  local -a params=("$@")

  if [[ ${#params[@]} -eq 0 ]]; then
    echo "WARNING: simulate_grub_param_add_idempotent: no parameters specified" >&2
    return 0
  fi

  if [[ ! -f "$grub_cfg" ]]; then
    echo "ERROR: simulate_grub_param_add_idempotent: grub.cfg not found: $grub_cfg" >&2
    return 1
  fi

  # First addition
  if ! simulate_grub_param_add "$grub_cfg" "${params[@]}"; then
    echo "ERROR: simulate_grub_param_add_idempotent: first addition failed" >&2
    return 1
  fi

  # Second addition (should be idempotent)
  if ! simulate_grub_param_add "$grub_cfg" "${params[@]}"; then
    echo "ERROR: simulate_grub_param_add_idempotent: second addition failed" >&2
    return 1
  fi

  # Verify no duplicates
  local param
  for param in "${params[@]}"; do
    # Count occurrences on linux lines (whole-token match)
    local count=0 _line
    while IFS= read -r _line; do
      [[ " ${_line%%#*} " == *" ${param} "* ]] && ((count++))
    done < <(grep 'linux' "$grub_cfg" 2>/dev/null)
    if [[ "$count" -gt 1 ]]; then
      echo "ERROR: simulate_grub_param_add_idempotent: duplicate parameter '$param' found ($count occurrences)" >&2
      return 1
    fi
  done

  return 0
}

# ============================================================================
# simulate_build_failure
#
# Inject controlled failure (shim that exits with code 42).
#
# Usage:
#   simulate_build_failure BIN_DIR COMMAND_NAME
#
# Arguments:
#   BIN_DIR      - Directory to create the shim in
#   COMMAND_NAME - Name of the command to shim (e.g. "update-grub")
#
# This function creates a shell script that:
#   1. Logs the attempted invocation
#   2. Exits with code 42 (controlled failure)
#
# The shim is executable and can be placed in PATH to intercept real commands.
#
# Returns:
#   0 - Shim created successfully
#   1 - Failed to create shim
# ============================================================================
simulate_build_failure() {
  local bin_dir="${1:?simulate_build_failure: missing BIN_DIR}"
  local command_name="${2:?simulate_build_failure: missing COMMAND_NAME}"

  if [[ ! -d "$bin_dir" ]]; then
    mkdir -p "$bin_dir"
  fi

  local shim_path="$bin_dir/$command_name"

  cat >"$shim_path" <<SHIM_EOF
#!/bin/bash
# Build failure shim for testing error handling
echo "SHIM: intercepted $command_name" >&2
echo "SHIM: arguments: \$*" >&2
echo "SHIM: exiting with controlled failure (code 42)" >&2
exit 42
SHIM_EOF

  chmod +x "$shim_path"

  return 0
}

# ============================================================================
# verify_host_isolation
#
# Snapshot host paths before/after and compare to detect host leakage.
#
# Usage:
#   verify_host_isolation BASE_DIR [EXCLUDE_PATTERNS...]
#
# Arguments:
#   BASE_DIR          - Base directory to scan for host path references
#   EXCLUDE_PATTERNS  - Optional patterns to exclude from scan
#
# This function:
#   1. Takes a "before" snapshot of paths referenced in files
#   2. Executes a provided operation (via callback)
#   3. Takes an "after" snapshot
#   4. Compares snapshots to detect host path leakage
#
# To use: call before_snapshot(), execute your operation, then call
# after_snapshot_and_compare().
#
# Returns:
#   0 - No host path leakage detected
#   1 - Host path references found
# ============================================================================
_HOST_SNAPSHOT_BEFORE=""
_HOST_SNAPSHOT_AFTER=""

verify_host_isolation_before() {
  local base_dir="${1:?verify_host_isolation_before: missing BASE_DIR}"
  shift
  local -a exclude_patterns=("$@")

  if [[ ! -d "$base_dir" ]]; then
    echo "ERROR: verify_host_isolation_before: base_dir not found: $base_dir" >&2
    return 1
  fi

  # Take snapshot: find all files and extract path-like strings
  local snapshot_file
  snapshot_file="$(mktemp "${TMPDIR:-/tmp}/host-snapshot-XXXXXX")"

  # Find all regular files in base_dir
  find "$base_dir" -type f -print0 2>/dev/null | while IFS= read -r -d '' file; do
    # Skip excluded patterns
    local skip=0
    local pattern
    for pattern in "${exclude_patterns[@]}"; do
      if [[ "$file" == *"$pattern"* ]]; then
        skip=1
        break
      fi
    done
    [[ "$skip" -eq 1 ]] && continue

    # Extract strings that look like host paths (absolute paths)
    strings "$file" 2>/dev/null | grep -oE '^/[a-z0-9_-]+(/[a-z0-9._-]+)*' || true
  done | sort -u >"$snapshot_file"

  _HOST_SNAPSHOT_BEFORE="$snapshot_file"
  return 0
}

verify_host_isolation_after() {
  local base_dir="${1:?verify_host_isolation_after: missing BASE_DIR}"
  shift
  local -a exclude_patterns=("$@")

  if [[ ! -d "$base_dir" ]]; then
    echo "ERROR: verify_host_isolation_after: base_dir not found: $base_dir" >&2
    return 1
  fi

  # Take snapshot
  local snapshot_file
  snapshot_file="$(mktemp "${TMPDIR:-/tmp}/host-snapshot-XXXXXX")"

  find "$base_dir" -type f -print0 2>/dev/null | while IFS= read -r -d '' file; do
    local skip=0
    local pattern
    for pattern in "${exclude_patterns[@]}"; do
      if [[ "$file" == *"$pattern"* ]]; then
        skip=1
        break
      fi
    done
    [[ "$skip" -eq 1 ]] && continue

    strings "$file" 2>/dev/null | grep -oE '^/[a-z0-9_-]+(/[a-z0-9._-]+)*' || true
  done | sort -u >"$snapshot_file"

  _HOST_SNAPSHOT_AFTER="$snapshot_file"

  # Compare snapshots
  if [[ -z "$_HOST_SNAPSHOT_BEFORE" || ! -f "$_HOST_SNAPSHOT_BEFORE" ]]; then
    echo "ERROR: verify_host_isolation_after: before snapshot not available" >&2
    return 1
  fi

  # Find paths in after that weren't in before (new host path references)
  local new_paths
  new_paths="$(comm -13 "$_HOST_SNAPSHOT_BEFORE" "$_HOST_SNAPSHOT_AFTER" 2>/dev/null)"

  # Cleanup
  rm -f "$_HOST_SNAPSHOT_BEFORE" "$_HOST_SNAPSHOT_AFTER"
  _HOST_SNAPSHOT_BEFORE=""
  _HOST_SNAPSHOT_AFTER=""

  if [[ -n "$new_paths" ]]; then
    echo "ERROR: verify_host_isolation: new host path references detected:" >&2
    echo "$new_paths" >&2
    return 1
  fi

  return 0
}

# ============================================================================
# verify_preserved_files
#
# Byte-compare sentinel files before/after an operation to verify preservation.
#
# Usage:
#   verify_preserved_files BASE_DIR FILE_PATHS...
#
# Arguments:
#   BASE_DIR     - Base directory containing the files
#   FILE_PATHS   - Relative paths to files to verify (relative to BASE_DIR)
#
# This function:
#   1. Takes checksums of specified files (call before operation)
#   2. After operation, verifies checksums match (call after operation)
#
# To use: call verify_preserved_files_before(), execute your operation,
# then call verify_preserved_files_after().
#
# Returns:
#   0 - All files preserved correctly
#   1 - One or more files were modified or missing
# ============================================================================
_PRESERVED_FILE_CHECKSUMS=""

verify_preserved_files_before() {
  local base_dir="${1:?verify_preserved_files_before: missing BASE_DIR}"
  shift
  local -a file_paths=("$@")

  if [[ ${#file_paths[@]} -eq 0 ]]; then
    echo "WARNING: verify_preserved_files_before: no files specified" >&2
    return 0
  fi

  if [[ ! -d "$base_dir" ]]; then
    echo "ERROR: verify_preserved_files_before: base_dir not found: $base_dir" >&2
    return 1
  fi

  # Create checksum file
  local checksum_file
  checksum_file="$(mktemp "${TMPDIR:-/tmp}/preserved-checksums-XXXXXX")"

  local rel_path
  for rel_path in "${file_paths[@]}"; do
    local full_path="$base_dir/$rel_path"
    if [[ -f "$full_path" ]]; then
      # Store checksum and file path
      md5sum "$full_path" | awk -v rp="$rel_path" '{print $1, rp}' >>"$checksum_file"
    else
      # File doesn't exist yet - store empty marker
      echo "MISSING $rel_path" >>"$checksum_file"
    fi
  done

  _PRESERVED_FILE_CHECKSUMS="$checksum_file"
  return 0
}

verify_preserved_files_after() {
  local base_dir="${1:?verify_preserved_files_after: missing BASE_DIR}"
  shift
  local -a file_paths=("$@")

  if [[ ${#file_paths[@]} -eq 0 ]]; then
    echo "WARNING: verify_preserved_files_after: no files specified" >&2
    return 0
  fi

  if [[ ! -d "$base_dir" ]]; then
    echo "ERROR: verify_preserved_files_after: base_dir not found: $base_dir" >&2
    return 1
  fi

  if [[ -z "$_PRESERVED_FILE_CHECKSUMS" || ! -f "$_PRESERVED_FILE_CHECKSUMS" ]]; then
    echo "ERROR: verify_preserved_files_after: before snapshot not available" >&2
    return 1
  fi

  local rc=0
  local rel_path
  for rel_path in "${file_paths[@]}"; do
    local full_path="$base_dir/$rel_path"

    # Get expected checksum from snapshot
    local expected
    expected="$(grep " $rel_path$" "$_PRESERVED_FILE_CHECKSUMS" 2>/dev/null | awk '{print $1}')"

    if [[ "$expected" == "MISSING" ]]; then
      # File was missing before - should still be missing or newly created
      if [[ -f "$full_path" ]]; then
        # File was created - that's ok if it's new
        continue
      fi
    elif [[ -z "$expected" ]]; then
      echo "WARNING: verify_preserved_files_after: '$rel_path' not in before snapshot" >&2
      continue
    fi

    # File should exist and have same checksum
    if [[ ! -f "$full_path" ]]; then
      echo "ERROR: verify_preserved_files_after: file missing after operation: '$rel_path'" >&2
      rc=1
      continue
    fi

    local actual
    actual="$(md5sum "$full_path" | awk '{print $1}')"

    if [[ "$actual" != "$expected" ]]; then
      echo "ERROR: verify_preserved_files_after: file modified: '$rel_path' (expected=$expected, actual=$actual)" >&2
      rc=1
    fi
  done

  # Cleanup
  rm -f "$_PRESERVED_FILE_CHECKSUMS"
  _PRESERVED_FILE_CHECKSUMS=""

  return $rc
}

# ============================================================================
# verify_single_slot_no_B
#
# Scan for B references in single-slot output to verify no B slot leakage.
#
# Usage:
#   verify_single_slot_no_B BASE_DIR [EXCLUDE_FILES...]
#
# Arguments:
#   BASE_DIR        - Base directory to scan
#   EXCLUDE_FILES   - Optional file patterns to exclude from scan
#
# This function scans all files in BASE_DIR for references to slot B:
#   - "rootfs-B"
#   - "efi-B"
#   - "var-B"
#   - "slot B"
#   - "B.conf"
#
# Returns:
#   0 - No B slot references found (single-slot verified)
#   1 - B slot references detected
# ============================================================================
verify_single_slot_no_B() {
  local base_dir="${1:?verify_single_slot_no_B: missing BASE_DIR}"
  shift
  local -a exclude_files=("$@")

  if [[ ! -d "$base_dir" ]]; then
    echo "ERROR: verify_single_slot_no_B: base_dir not found: $base_dir" >&2
    return 1
  fi

  # Patterns that indicate B slot references
  local b_patterns=(
    'rootfs-B'
    'efi-B'
    'var-B'
    'slot B'
    'B\.conf'
  )

  local rc=0
  local -a found_references=()

  # Scan all files
  while IFS= read -r -d '' file; do
    # Skip excluded patterns
    local skip=0
    local pattern
    for pattern in "${exclude_files[@]}"; do
      if [[ "$file" == *"$pattern"* ]]; then
        skip=1
        break
      fi
    done
    [[ "$skip" -eq 1 ]] && continue

    # Check for B slot patterns
    local b_pattern
    for b_pattern in "${b_patterns[@]}"; do
      if grep -q "$b_pattern" "$file" 2>/dev/null; then
        found_references+=("$file:$b_pattern")
      fi
    done
  done < <(find "$base_dir" -type f -print0 2>/dev/null)

  if [[ ${#found_references[@]} -gt 0 ]]; then
    echo "ERROR: verify_single_slot_no_B: B slot references detected in single-slot fixture:" >&2
    printf "  %s\n" "${found_references[@]}" >&2
    rc=1
  fi

  return $rc
}

# ============================================================================
# inject_stale_transaction
#
# Create stale .new/.bak/.tmp files for testing transaction cleanup.
#
# Usage:
#   inject_stale_transaction EFI_DIR [ESP_DIR]
#
# Arguments:
#   EFI_DIR  - EFI directory to inject stale files into
#   ESP_DIR  - Optional ESP directory to inject stale files into
#
# Creates:
#   - grub.cfg.new (atomic-replace staging file)
#   - grub.cfg.bak (backup of replaced file)
#   - grub.cfg.tmp (temporary work file)
#   - partsets/A.new (partset staging file)
#   - partsets/A.bak (partset backup)
#
# Returns:
#   0 - Stale files created successfully
#   1 - Failed to create stale files
# ============================================================================
inject_stale_transaction() {
  local efi_dir="${1:?inject_stale_transaction: missing EFI_DIR}"
  local esp_dir="${2:-}"

  if [[ ! -d "$efi_dir" ]]; then
    echo "ERROR: inject_stale_transaction: efi_dir not found: $efi_dir" >&2
    return 1
  fi

  # Create stale files in EFI directory
  local steamos_dir="$efi_dir/EFI/steamos"
  if [[ -d "$steamos_dir" ]]; then
    # Atomic-replace staging file
    echo "# STALE: grub.cfg.new (atomic-replace staging)" >"$steamos_dir/grub.cfg.new"

    # Backup of replaced file
    echo "# STALE: grub.cfg.bak (backup)" >"$steamos_dir/grub.cfg.bak"

    # Temporary work file
    echo "# STALE: grub.cfg.tmp (temporary)" >"$steamos_dir/grub.cfg.tmp"
  fi

  # Create stale partset files
  local partsets_dir="$efi_dir/SteamOS/partsets"
  if [[ -d "$partsets_dir" ]]; then
    echo "# STALE: partset A.new" >"$partsets_dir/A.new"
    echo "# STALE: partset A.bak" >"$partsets_dir/A.bak"
  fi

  # Create stale files in ESP directory if provided
  if [[ -n "$esp_dir" && -d "$esp_dir" ]]; then
    local esp_conf_dir="$esp_dir/SteamOS/conf"
    if [[ -d "$esp_conf_dir" ]]; then
      echo "# STALE: bootconf.new" >"$esp_conf_dir/A.conf.new"
      echo "# STALE: bootconf.bak" >"$esp_conf_dir/A.conf.bak"
    fi
  fi

  return 0
}

# ============================================================================
# create_sentinel_files
#
# Create sentinel files in EFI for preservation testing.
#
# Usage:
#   create_sentinel_files EFI_DIR [MARKER_CONTENT]
#
# Arguments:
#   EFI_DIR         - EFI directory to create sentinel files in
#   MARKER_CONTENT  - Optional content for sentinel files (default: "SENTINEL")
#
# Creates sentinel files that should be preserved across operations:
#   - EFI/steamos/sentinel-default.grub
#   - EFI/steamos/sentinel-steamos.grub
#   - SteamOS/partsets/sentinel-self
#
# Returns:
#   0 - Sentinel files created successfully
#   1 - Failed to create sentinel files
# ============================================================================
create_sentinel_files() {
  local efi_dir="${1:?create_sentinel_files: missing EFI_DIR}"
  local marker_content="${2:-SENTINEL}"

  if [[ ! -d "$efi_dir" ]]; then
    echo "ERROR: create_sentinel_files: efi_dir not found: $efi_dir" >&2
    return 1
  fi

  local steamos_dir="$efi_dir/EFI/steamos"
  if [[ ! -d "$steamos_dir" ]]; then
    mkdir -p "$steamos_dir"
  fi

  # Create sentinel files
  echo "$marker_content" >"$steamos_dir/sentinel-default.grub"
  echo "$marker_content" >"$steamos_dir/sentinel-steamos.grub"

  local partsets_dir="$efi_dir/SteamOS/partsets"
  if [[ ! -d "$partsets_dir" ]]; then
    mkdir -p "$partsets_dir"
  fi

  echo "$marker_content" >"$partsets_dir/sentinel-self"

  return 0
}

# ============================================================================
# Utility functions for build tests
# ============================================================================

# Get the target rootfs UUID for the current build fixture
# Usage: get_build_target_uuid
get_build_target_uuid() {
  if [[ -z "$BUILD_TARGET_UUID" ]]; then
    echo "ERROR: get_build_target_uuid: BUILD_TARGET_UUID not set (call build_scenario_setup first)" >&2
    return 1
  fi
  echo "$BUILD_TARGET_UUID"
}

# Get the EFI directory for the current build fixture
# Usage: get_build_efi_dir
get_build_efi_dir() {
  if [[ -z "$BUILD_EFI_DIR" ]]; then
    echo "ERROR: get_build_efi_dir: BUILD_EFI_DIR not set (call build_scenario_setup first)" >&2
    return 1
  fi
  echo "$BUILD_EFI_DIR"
}

# Get the rootfs directory for the current build fixture
# Usage: get_build_rootfs_dir
get_build_rootfs_dir() {
  if [[ -z "$BUILD_ROOTFS_DIR" ]]; then
    echo "ERROR: get_build_rootfs_dir: BUILD_ROOTFS_DIR not set (call build_scenario_setup first)" >&2
    return 1
  fi
  echo "$BUILD_ROOTFS_DIR"
}

# Get the ESP directory for the current build fixture
# Usage: get_build_esp_dir
get_build_esp_dir() {
  if [[ -z "$BUILD_ESP_DIR" ]]; then
    echo "ERROR: get_build_esp_dir: BUILD_ESP_DIR not set (call build_scenario_setup first)" >&2
    return 1
  fi
  echo "$BUILD_ESP_DIR"
}

# Get the metadata directory for the current build fixture
# Usage: get_build_metadata_dir
get_build_metadata_dir() {
  if [[ -z "$BUILD_METADATA_DIR" ]]; then
    echo "ERROR: get_build_metadata_dir: BUILD_METADATA_DIR not set (call build_scenario_setup first)" >&2
    return 1
  fi
  echo "$BUILD_METADATA_DIR"
}
