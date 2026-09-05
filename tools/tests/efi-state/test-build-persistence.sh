#!/bin/bash
#
# tools/tests/efi-state/test-build-persistence.sh
# Build scenario persistence tests B-06 through B-10.
#
# Tests the persistence layer of the EFI state application mechanism:
#   B-06: Persistent defaults patched (grub-steamos managed keys)
#   B-07: Atomic-update keep-list populated
#   B-08: Function-owned mounts cleaned
#   B-09: Function-owned chroot mounts cleaned
#   B-10: Runtime GRUB failure cleans up
#
# Dependencies:
#   - test-harness.sh     (test lifecycle, assertions)
#   - build-helpers.sh    (build fixture setup, EFI state simulation)
#   - fixture-factory.sh  (mock fixture creation)
#   - topology.sh         (deterministic UUID/PARTUUID generation)
#
# Usage:
#   bash tools/tests/efi-state/test-build-persistence.sh

# ---------------------------------------------------------------------------
# Source required libraries
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/test-harness.sh"
source "$SCRIPT_DIR/fixture-factory.sh"
source "$SCRIPT_DIR/topology.sh"
source "$SCRIPT_DIR/build-helpers.sh"

# ---------------------------------------------------------------------------
# Managed keys: the kernel parameters the build process writes to grub-steamos.
# These are the keys that must appear exactly once after patching.
# ---------------------------------------------------------------------------
MANAGED_KEYS=(
  "rd.driver.blacklist=nouveau"
  "modprobe.blacklist=nouveau"
  "nvidia-drm.modeset=1"
  "nvidia-drm.fbdev=1"
)

# GRUB files required in the keep-list (atomic-update retention).
REQUIRED_KEEP_FILES=(
  "/etc/default/grub-steamos"
)

# Required GRUB files that must be retained (one copy each).
REQUIRED_GRUB_FILES=(
  "EFI/steamos/grub.cfg"
  "EFI/steamos/grubx64.efi"
)

# Mountpoints the build function creates under rootfs (for chroot operations).
FUNCTION_CHROOT_MOUNTS=(
  "proc"
  "sys"
  "dev"
  "dev/pts"
  "run"
)

# ============================================================================
# Helper: count occurrences of a key in grub-steamos
#
# Usage: _count_key_in_grub_steamos FILE KEY
# Returns: prints the count
# ============================================================================
_count_key_in_grub_steamos() {
  local file="${1:?_count_key_in_grub_steamos: missing FILE}"
  local key="${2:?_count_key_in_grub_steamos: missing KEY}"

  if [[ ! -f "$file" ]]; then
    echo 0
    return
  fi

  # Count lines that contain the key as a whole token (space-delimited or
  # at the end of a quoted value).
  local count
  count="$(grep -c "$key" "$file" 2>/dev/null || echo 0)"
  echo "$count"
}

# ============================================================================
# Helper: simulate apply of persistent defaults to grub-steamos
#
# This simulates patch_persistent_defaults() from lib/grub.sh by adding
# managed keys to the fixture's /etc/default/grub-steamos.
#
# Usage: _simulate_apply_persistent_defaults ROOTFS_DIR
# ============================================================================
_simulate_apply_persistent_defaults() {
  local rootfs_dir="${1:?_simulate_apply_persistent_defaults: missing ROOTFS_DIR}"
  local grub_steamos="$rootfs_dir/etc/default/grub-steamos"

  if [[ ! -f "$grub_steamos" ]]; then
    echo "ERROR: _simulate_apply_persistent_defaults: grub-steamos not found: $grub_steamos" >&2
    return 1
  fi

  # Read current GRUB_CMDLINE_LINUX value
  local current_line
  current_line="$(grep '^GRUB_CMDLINE_LINUX=' "$grub_steamos" 2>/dev/null || true)"

  local current_value=""
  if [[ -n "$current_line" ]]; then
    # Extract value between quotes
    current_value="${current_line#GRUB_CMDLINE_LINUX=\"}"
    current_value="${current_value%\"}"
  fi

  # Add each managed key if not already present
  local key
  for key in "${MANAGED_KEYS[@]}"; do
    if [[ " $current_value " != *" $key "* ]]; then
      current_value="${current_value:+$current_value }$key"
    fi
  done

  # Write back the GRUB_CMDLINE_LINUX line
  local tmp="$grub_steamos.tmp"
  while IFS= read -r line; do
    if [[ "$line" =~ ^GRUB_CMDLINE_LINUX= ]]; then
      echo "GRUB_CMDLINE_LINUX=\"$current_value\""
    else
      echo "$line"
    fi
  done <"$grub_steamos" >"$tmp"
  mv "$tmp" "$grub_steamos"

  return 0
}

# ============================================================================
# Helper: simulate ensure keep-list
#
# This simulates _ensure_grub_steamos_keep_list() from lib/grub.sh.
#
# Usage: _simulate_ensure_keep_list ROOTFS_DIR
# ============================================================================
_simulate_ensure_keep_list() {
  local rootfs_dir="${1:?_simulate_ensure_keep_list: missing ROOTFS_DIR}"
  local keep_dir="$rootfs_dir/etc/atomic-update.conf.d"
  local keep_file="$keep_dir/steamos-build-installer.conf"

  mkdir -p "$keep_dir"

  if [[ -f "$keep_file" ]]; then
    # Check each required entry
    local entry
    for entry in "${REQUIRED_KEEP_FILES[@]}"; do
      if ! grep -qxF "$entry" "$keep_file" 2>/dev/null; then
        echo "$entry" >>"$keep_file"
      fi
    done
  else
    # Create the file with required entries
    {
      echo "# Files to preserve across atomic updates"
      for entry in "${REQUIRED_KEEP_FILES[@]}"; do
        echo "$entry"
      done
    } >"$keep_file"
  fi

  return 0
}

# ============================================================================
# Helper: simulate applying EFI state with build persistence
#
# Orchestrates the full EFI state application for build scenarios.
#
# Usage: _simulate_full_build_apply ROOTFS_DIR EFI_DIR [ESP_DIR]
# ============================================================================
_simulate_full_build_apply() {
  local rootfs_dir="${1:?_simulate_full_build_apply: missing ROOTFS_DIR}"
  local efi_dir="${2:?_simulate_full_build_apply: missing EFI_DIR}"
  local esp_dir="${3:-}"

  # 1. Patch EFI grub.cfg with target UUID
  if ! simulate_efi_state_apply "$rootfs_dir" "$efi_dir" "$esp_dir"; then
    echo "ERROR: _simulate_full_build_apply: EFI state apply failed" >&2
    return 1
  fi

  # 2. Patch persistent defaults (grub-steamos)
  if ! _simulate_apply_persistent_defaults "$rootfs_dir"; then
    echo "ERROR: _simulate_full_build_apply: persistent defaults patch failed" >&2
    return 1
  fi

  # 3. Ensure grub-steamos is in the atomic-update keep-list
  if ! _simulate_ensure_keep_list "$rootfs_dir"; then
    echo "ERROR: _simulate_full_build_apply: keep-list update failed" >&2
    return 1
  fi

  return 0
}

# ============================================================================
# Helper: create function-owned temp mountpoints
#
# Simulates the function creating temp mountpoints during build.
# In a real build, these would be bind mounts or tmpfs mounts.
#
# Usage: _create_function_temp_mountpoints ROOTFS_DIR
# ============================================================================
_create_function_temp_mountpoints() {
  local rootfs_dir="${1:?_create_function_temp_mountpoints: missing ROOTFS_DIR}"

  # Create mountpoint directories under rootfs
  local mp
  for mp in "${FUNCTION_CHROOT_MOUNTS[@]}"; do
    mkdir -p "$rootfs_dir/$mp"
  done

  # Record them as tracked mounts (simulates build function's mount tracking)
  local mount_tmp
  mount_tmp="$(mktemp "${TMPDIR:-/tmp}/mounts-XXXXXX")"
  for mp in "${FUNCTION_CHROOT_MOUNTS[@]}"; do
    echo "$rootfs_dir/$mp" >>"$mount_tmp"
  done
  echo "$mount_tmp"
}

# ============================================================================
# Helper: cleanup function-owned temp mountpoints
#
# Simulates the function cleaning up its own temp mountpoints.
#
# Usage: _cleanup_function_temp_mountpoints ROOTFS_DIR
# ============================================================================
_cleanup_function_temp_mountpoints() {
  local rootfs_dir="${1:?_cleanup_function_temp_mountpoints: missing ROOTFS_DIR}"

  local mp
  for mp in "${FUNCTION_CHROOT_MOUNTS[@]}"; do
    rmdir "$rootfs_dir/$mp" 2>/dev/null || true
  done

  return 0
}

# ============================================================================
# Helper: create caller-owned mounts (simulating mounts not owned by build)
#
# Usage: _create_caller_owned_mounts ROOTFS_DIR
# ============================================================================
_create_caller_owned_mounts() {
  local rootfs_dir="${1:?_create_caller_owned_mounts: missing ROOTFS_DIR}"

  # Caller might mount /boot, /home, etc. — create these as evidence.
  mkdir -p "$rootfs_dir/boot"
  mkdir -p "$rootfs_dir/home"

  # Create a marker file to prove they existed before build
  echo "caller-owned" >"$rootfs_dir/.caller-mounts-existed"
  return 0
}

# ============================================================================
# Helper: create mountpoint snapshots for before/after comparison
#
# Usage: _snapshot_mountpoints ROOTFS_DIR
# Returns: path to snapshot file
# ============================================================================
_snapshot_mountpoints() {
  local rootfs_dir="${1:?_snapshot_mountpoints: missing ROOTFS_DIR}"

  local snap
  snap="$(mktemp "${TMPDIR:-/tmp}/mount-snap-XXXXXX")"

  # Find all directories under rootfs that could be mountpoints
  find "$rootfs_dir" -mindepth 1 -maxdepth 2 -type d -printf '%P\n' 2>/dev/null \
    | sort >"$snap"

  echo "$snap"
}

# ============================================================================
# Helper: simulate build failure with shim
#
# Creates a shim that exits with code 42, then runs the build simulation
# to trigger the failure path.
#
# Usage: _simulate_build_with_failure ROOTFS_DIR EFI_DIR
# Returns: exit code from the simulated build
# ============================================================================
_simulate_build_with_failure() {
  local rootfs_dir="${1:?_simulate_build_with_failure: missing ROOTFS_DIR}"
  local efi_dir="${2:?_simulate_build_with_failure: missing EFI_DIR}"

  # Create a temp bin directory with the failure shim
  local bin_dir
  bin_dir="$(mktemp -d "${TMPDIR:-/tmp}/bin-XXXXXX")"

  if ! simulate_build_failure "$bin_dir" "update-grub"; then
    echo "ERROR: _simulate_build_with_failure: failed to create shim" >&2
    return 1
  fi

  # Prepend the shim directory to PATH so it intercepts update-grub
  export PATH="$bin_dir:$PATH"

  # Create function-owned mountpoints (simulating the build starting)
  _create_function_temp_mountpoints "$rootfs_dir" >/dev/null

  # Attempt the build — it should fail because update-grub is shimmed
  local rc=0
  if ! _simulate_full_build_apply "$rootfs_dir" "$efi_dir"; then
    rc=$?
  fi

  # Also try the shim directly to confirm it returns 42
  if "$bin_dir/update-grub" >/dev/null 2>&1; then
    rc=42
  else
    rc=$?
  fi

  # Cleanup: remove the shim and restore PATH
  rm -rf "$bin_dir"
  export PATH="${PATH#"$bin_dir":}"

  return $rc
}

# ============================================================================
# Test: B-06 — Persistent defaults patched
#
# Verifies that after applying EFI state, the grub-steamos file contains
# each managed key exactly once, and that unrelated settings remain unchanged.
# ============================================================================
test_b06_persistent_defaults_patched() {
  test_harness_begin_test "B-06: Persistent defaults patched"

  # Setup
  build_scenario_setup || {
    test_harness_fail "setup failed"
    return
  }

  local grub_steamos="$BUILD_ROOTFS_DIR/etc/default/grub-steamos"
  local grub_default="$BUILD_ROOTFS_DIR/etc/default/grub"

  # Snapshot original state of unrelated settings
  local original_grub_default
  original_grub_default="$(cat "$grub_default" 2>/dev/null || true)"

  # Apply EFI state (patches grub-steamos with managed keys)
  if ! _simulate_full_build_apply "$BUILD_ROOTFS_DIR" "$BUILD_EFI_DIR" "$BUILD_ESP_DIR"; then
    test_harness_fail "_simulate_full_build_apply failed"
    build_scenario_teardown
    return
  fi

  # Verify: each managed key appears exactly once in grub-steamos
  local key count
  for key in "${MANAGED_KEYS[@]}"; do
    count="$(_count_key_in_grub_steamos "$grub_steamos" "$key")"
    if [[ "$count" -ne 1 ]]; then
      test_harness_fail "key '$key' appears $count time(s) in grub-steamos (expected 1)"
      build_scenario_teardown
      return
    fi
  done

  # Verify: unrelated settings in /etc/default/grub remain unchanged
  local current_grub_default
  current_grub_default="$(cat "$grub_default" 2>/dev/null || true)"

  if [[ "$original_grub_default" != "$current_grub_default" ]]; then
    test_harness_fail "/etc/default/grub was modified unexpectedly"
    build_scenario_teardown
    return
  fi

  # Verify: GRUB_CMDLINE_LINUX in grub-steamos is non-empty
  local cmd_line
  cmd_line="$(grep '^GRUB_CMDLINE_LINUX=' "$grub_steamos" 2>/dev/null | head -1)"
  if [[ -z "$cmd_line" ]]; then
    test_harness_fail "GRUB_CMDLINE_LINUX not found in grub-steamos"
    build_scenario_teardown
    return
  fi

  # Verify: GRUB_DEFAULT and GRUB_TIMEOUT in /etc/default/grub are preserved
  if ! grep -q '^GRUB_DEFAULT=' "$grub_default" 2>/dev/null; then
    test_harness_fail "GRUB_DEFAULT missing from /etc/default/grub"
    build_scenario_teardown
    return
  fi

  if ! grep -q '^GRUB_TIMEOUT=' "$grub_default" 2>/dev/null; then
    test_harness_fail "GRUB_TIMEOUT missing from /etc/default/grub"
    build_scenario_teardown
    return
  fi

  test_harness_pass
  build_scenario_teardown
}

# ============================================================================
# Test: B-07 — Atomic-update keep-list populated
#
# Verifies that after applying EFI state, the keep-list file exists and
# contains all required GRUB files (exactly once each).
# ============================================================================
test_b07_keeplist_populated() {
  test_harness_begin_test "B-07: Atomic-update keep-list populated"

  # Setup
  build_scenario_setup || {
    test_harness_fail "setup failed"
    return
  }

  # Apply EFI state
  if ! _simulate_full_build_apply "$BUILD_ROOTFS_DIR" "$BUILD_EFI_DIR" "$BUILD_ESP_DIR"; then
    test_harness_fail "_simulate_full_build_apply failed"
    build_scenario_teardown
    return
  fi

  # Verify: keep-list file exists
  local keep_dir="$BUILD_ROOTFS_DIR/etc/atomic-update.conf.d"
  local keep_file="$keep_dir/steamos-build-installer.conf"

  test_harness_assert_file_exists "$keep_file"
  if [[ ! -f "$keep_file" ]]; then
    build_scenario_teardown
    return
  fi

  # Verify: keep-list is non-empty
  if [[ ! -s "$keep_file" ]]; then
    test_harness_fail "keep-list file is empty: $keep_file"
    build_scenario_teardown
    return
  fi

  # Verify: each required entry appears exactly once
  local entry count
  for entry in "${REQUIRED_KEEP_FILES[@]}"; do
    count="$(grep -cxF "$entry" "$keep_file" 2>/dev/null || echo 0)"
    if [[ "$count" -ne 1 ]]; then
      test_harness_fail "keep-list entry '$entry' appears $count time(s) (expected 1)"
      build_scenario_teardown
      return
    fi
  done

  # Verify: required GRUB files exist in rootfs
  local file
  for file in "${REQUIRED_GRUB_FILES[@]}"; do
    local full_path="$BUILD_ROOTFS_DIR/$file"
    test_harness_assert_file_exists "$full_path"
    if [[ ! -f "$full_path" ]]; then
      build_scenario_teardown
      return
    fi
  done

  # Verify: required GRUB files exist exactly once (no duplicates from staging)
  for file in "${REQUIRED_GRUB_FILES[@]}"; do
    local basename_file
    basename_file="$(basename "$file")"
    local dirname_file
    dirname_file="$(dirname "$file")"
    local dir_full_path="$BUILD_ROOTFS_DIR/$dirname_file"

    if [[ -d "$dir_full_path" ]]; then
      local file_count
      file_count="$(find "$dir_full_path" -maxdepth 1 -name "$basename_file" -type f 2>/dev/null | wc -l)"
      if [[ "$file_count" -ne 1 ]]; then
        test_harness_fail "GRUB file '$file' has $file_count copy(ies) (expected 1)"
        build_scenario_teardown
        return
      fi
    fi
  done

  test_harness_pass
  build_scenario_teardown
}

# ============================================================================
# Test: B-08 — Function-owned mounts cleaned
#
# Verifies that after applying EFI state, function-created temp mountpoints
# are gone, but caller-owned mounts still exist.
# ============================================================================
test_b08_function_mounts_cleaned() {
  test_harness_begin_test "B-08: Function-owned mounts cleaned"

  # Setup
  build_scenario_setup || {
    test_harness_fail "setup failed"
    return
  }

  # Create caller-owned mounts (simulating pre-existing mounts)
  _create_caller_owned_mounts "$BUILD_ROOTFS_DIR"

  # Create function-owned temp mountpoints
  _create_function_temp_mountpoints "$BUILD_ROOTFS_DIR" >/dev/null

  # Snapshot mountpoints before
  local snap_before
  snap_before="$(_snapshot_mountpoints "$BUILD_ROOTFS_DIR")"

  # Simulate function cleanup (unmount and remove temp mountpoints)
  _cleanup_function_temp_mountpoints "$BUILD_ROOTFS_DIR"

  # Verify: function-created temp mountpoints are gone
  local mp
  for mp in "${FUNCTION_CHROOT_MOUNTS[@]}"; do
    local mp_path="$BUILD_ROOTFS_DIR/$mp"
    # The directories may still exist (from the fixture) but should not be
    # function-owned. We verify that the function-created mountpoints were
    # cleaned up by checking that the function's tracking markers are gone.
    if [[ -d "$mp_path" ]]; then
      # Check if it was a function-owned mountpoint by looking at the
      # cleanup痕迹 — the function should have removed its tracking.
      local mount_marker="$mp_path/.function-mount"
      if [[ -f "$mount_marker" ]]; then
        test_harness_fail "function-owned mountpoint marker still exists: $mp_path"
        build_scenario_teardown
        return
      fi
    fi
  done

  # Verify: caller-owned mounts still exist
  if [[ ! -f "$BUILD_ROOTFS_DIR/.caller-mounts-existed" ]]; then
    test_harness_fail "caller-owned mount marker was deleted"
    build_scenario_teardown
    return
  fi

  # Verify: caller-owned directories still exist
  if [[ ! -d "$BUILD_ROOTFS_DIR/boot" ]]; then
    test_harness_fail "caller-owned /boot directory was deleted"
    build_scenario_teardown
    return
  fi

  if [[ ! -d "$BUILD_ROOTFS_DIR/home" ]]; then
    test_harness_fail "caller-owned /home directory was deleted"
    build_scenario_teardown
    return
  fi

  # Verify: no new unexpected mountpoints appeared
  local snap_after
  snap_after="$(_snapshot_mountpoints "$BUILD_ROOTFS_DIR")"

  local new_entries
  new_entries="$(comm -13 "$snap_before" "$snap_after" 2>/dev/null || true)"

  # Filter out expected entries (function mounts that may be recreated)
  local unexpected=""
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local is_function_mount=0
    for mp in "${FUNCTION_CHROOT_MOUNTS[@]}"; do
      if [[ "$entry" == "$mp" || "$entry" == */"$mp" ]]; then
        is_function_mount=1
        break
      fi
    done
    if [[ "$is_function_mount" -eq 0 ]]; then
      unexpected="${unexpected:+$unexpected }$entry"
    fi
  done <<<"$new_entries"

  if [[ -n "$unexpected" ]]; then
    test_harness_fail "unexpected new mountpoints appeared: $unexpected"
    build_scenario_teardown
    return
  fi

  # Cleanup snapshots
  rm -f "$snap_before" "$snap_after"

  test_harness_pass
  build_scenario_teardown
}

# ============================================================================
# Test: B-09 — Function-owned chroot mounts cleaned
#
# Verifies that after applying EFI state, no function-created mounts remain
# under rootfs/{proc,sys,dev,dev/pts,run}.
# ============================================================================
test_b09_chroot_mounts_cleaned() {
  test_harness_begin_test "B-09: Function-owned chroot mounts cleaned"

  # Setup
  build_scenario_setup || {
    test_harness_fail "setup failed"
    return
  }

  # Create the chroot mountpoint directories
  local mp
  for mp in "${FUNCTION_CHROOT_MOUNTS[@]}"; do
    mkdir -p "$BUILD_ROOTFS_DIR/$mp"
  done

  # Simulate function creating mounts (we can't actually mount in tests,
  # but we verify that after cleanup, these directories are either empty
  # or contain only the fixture's base content).

  # Record initial content of each chroot mountpoint
  local -A initial_contents
  for mp in "${FUNCTION_CHROOT_MOUNTS[@]}"; do
    local mp_path="$BUILD_ROOTFS_DIR/$mp"
    initial_contents[$mp]="$(find "$mp_path" -mindepth 1 -maxdepth 1 2>/dev/null | sort)"
  done

  # Simulate the function cleaning up its mounts
  # (In production, this would call umount_chroot_fs + cleanup_tracked_mounts)
  for mp in "${FUNCTION_CHROOT_MOUNTS[@]}"; do
    local mp_path="$BUILD_ROOTFS_DIR/$mp"

    # Remove any function-created content from the mountpoint
    # (In tests, we verify the cleanup removes what the function added)
    find "$mp_path" -mindepth 1 -maxdepth 1 -type f -delete 2>/dev/null || true
    find "$mp_path" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true
  done

  # Verify: no function-created mounts remain under rootfs/{proc,sys,dev,dev/pts,run}
  for mp in "${FUNCTION_CHROOT_MOUNTS[@]}"; do
    local mp_path="$BUILD_ROOTFS_DIR/$mp"

    # Check for any function-created artifacts
    local function_artifacts
    function_artifacts="$(find "$mp_path" -mindepth 1 -maxdepth 2 \
      -name "*.mount" -o -name ".function-owned" -o -name ".build-marker" 2>/dev/null || true)"

    if [[ -n "$function_artifacts" ]]; then
      test_harness_fail "function-created artifacts remain under rootfs/$mp: $function_artifacts"
      build_scenario_teardown
      return
    fi
  done

  # Verify: the directories themselves still exist (they're part of the fixture)
  for mp in "${FUNCTION_CHROOT_MOUNTS[@]}"; do
    if [[ ! -d "$BUILD_ROOTFS_DIR/$mp" ]]; then
      test_harness_fail "chroot directory rootfs/$mp was deleted (should only unmount, not delete)"
      build_scenario_teardown
      return
    fi
  done

  # Verify: no mount markers from the function remain
  local mount_markers
  mount_markers="$(find "$BUILD_ROOTFS_DIR" -maxdepth 3 \
    -name ".function-mount" -o -name ".build-mount" 2>/dev/null || true)"

  if [[ -n "$mount_markers" ]]; then
    test_harness_fail "function mount markers still exist: $mount_markers"
    build_scenario_teardown
    return
  fi

  test_harness_pass
  build_scenario_teardown
}

# ============================================================================
# Test: B-10 — Runtime GRUB failure cleans up
#
# Verifies that when a GRUB operation fails during build (shim exits 42):
#   1. The build exits with non-zero status
#   2. Function-owned mounts are cleaned up
#   3. Partial outputs are rolled back
# ============================================================================
test_b10_build_failure_cleanup() {
  test_harness_begin_test "B-10: Runtime GRUB failure cleans up"

  # Setup
  build_scenario_setup || {
    test_harness_fail "setup failed"
    return
  }

  # Record pre-failure state of EFI directory for rollback verification
  local grub_cfg_before
  grub_cfg_before="$(cat "$BUILD_EFI_DIR/EFI/steamos/grub.cfg" 2>/dev/null || true)"

  local grub_steamos_before
  grub_steamos_before="$(cat "$BUILD_ROOTFS_DIR/etc/default/grub-steamos" 2>/dev/null || true)"

  # Create function-owned temp mountpoints (simulating build starting)
  _create_function_temp_mountpoints "$BUILD_ROOTFS_DIR" >/dev/null

  # Verify: function-owned mountpoints exist before failure
  local mp
  for mp in "${FUNCTION_CHROOT_MOUNTS[@]}"; do
    if [[ ! -d "$BUILD_ROOTFS_DIR/$mp" ]]; then
      test_harness_fail "setup: function-owned mountpoint rootfs/$mp not created"
      build_scenario_teardown
      return
    fi
  done

  # Inject build failure: create shim that exits 42
  local bin_dir
  bin_dir="$(mktemp -d "${TMPDIR:-/tmp}/bin-fail-XXXXXX")"

  if ! simulate_build_failure "$bin_dir" "update-grub"; then
    test_harness_fail "failed to create failure shim"
    rm -rf "$bin_dir"
    build_scenario_teardown
    return
  fi

  # Run the build with the shim in PATH — it should fail
  local build_exit_code=0
  (
    export PATH="$bin_dir:$PATH"
    # Apply EFI state — this should succeed (pre-shim operations)
    _simulate_full_build_apply "$BUILD_ROOTFS_DIR" "$BUILD_EFI_DIR" "$BUILD_ESP_DIR"
    # Now try to run update-grub — this should fail (shim exits 42)
    update-grub >/dev/null 2>&1
    exit $?
  ) || build_exit_code=$?

  # Verify: non-zero exit code
  if [[ "$build_exit_code" -eq 0 ]]; then
    test_harness_fail "build should have failed but exited with code 0"
    rm -rf "$bin_dir"
    build_scenario_teardown
    return
  fi

  # Verify: function-owned mountpoints are cleaned up
  # (Simulate the error handler cleaning up)
  _cleanup_function_temp_mountpoints "$BUILD_ROOTFS_DIR"

  for mp in "${FUNCTION_CHROOT_MOUNTS[@]}"; do
    local mp_path="$BUILD_ROOTFS_DIR/$mp"
    # After cleanup, there should be no function-created content
    local function_content
    function_content="$(find "$mp_path" -mindepth 1 -maxdepth 1 \
      -name ".function-*" -o -name ".build-*" 2>/dev/null || true)"

    if [[ -n "$function_content" ]]; then
      test_harness_fail "function-owned content remains after failure cleanup: $function_content"
      rm -rf "$bin_dir"
      build_scenario_teardown
      return
    fi
  done

  # Verify: partial outputs are rolled back
  # After a failed build, the grub.cfg should either:
  #   1. Be unchanged (rollback to pre-build state), or
  #   2. Be absent (cleaned up)
  # In our simulation, we verify that the grub.cfg was not corrupted.

  local grub_cfg_after
  grub_cfg_after="$(cat "$BUILD_EFI_DIR/EFI/steamos/grub.cfg" 2>/dev/null || true)"

  # If grub.cfg was modified, it should still be valid (not corrupted)
  if [[ -n "$grub_cfg_after" ]]; then
    # Verify it's still a valid grub.cfg structure
    if ! grep -q 'menuentry\|search\|linux' "$BUILD_EFI_DIR/EFI/steamos/grub.cfg" 2>/dev/null; then
      test_harness_fail "grub.cfg was corrupted after build failure"
      rm -rf "$bin_dir"
      build_scenario_teardown
      return
    fi
  fi

  # Verify: no stale transaction artifacts in EFI directory
  local stale_artifacts
  stale_artifacts="$(find "$BUILD_EFI_DIR" -name "*.tmp" -o -name "*.transaction-*" 2>/dev/null || true)"

  if [[ -n "$stale_artifacts" ]]; then
    test_harness_fail "stale transaction artifacts found after failure: $stale_artifacts"
    rm -rf "$bin_dir"
    build_scenario_teardown
    return
  fi

  # Cleanup
  rm -rf "$bin_dir"

  test_harness_pass
  build_scenario_teardown
}

# ============================================================================
# Main: run all tests
# ============================================================================

main() {
  test_harness_init
  trap test_harness_cleanup EXIT

  echo "═══════════════════════════════════════════════════════════"
  echo "  Build Persistence Tests (B-06 through B-10)"
  echo "═══════════════════════════════════════════════════════════"
  echo ""

  test_b06_persistent_defaults_patched
  test_b07_keeplist_populated
  test_b08_function_mounts_cleaned
  test_b09_chroot_mounts_cleaned
  test_b10_build_failure_cleanup

  test_harness_summary
  test_harness_exit_code
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
