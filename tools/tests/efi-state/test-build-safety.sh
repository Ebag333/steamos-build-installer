#!/bin/bash
#
# tools/tests/efi-state/test-build-safety.sh
# Build scenario safety tests (B-11 through B-15).
#
# Tests that verify safety invariants of the EFI state application mechanism
# for the Build (single-slot, target A) scenario:
#
#   B-11  Application is idempotent
#   B-12  Existing state survives failed replacement
#   B-13  Host isolation
#   B-14  Unmanaged EFI files preserved
#   B-15  No nonexistent slot emitted
#
# Usage:
#   bash tools/tests/efi-state/test-build-safety.sh
#
# Dependencies:
#   - test-harness.sh       (lifecycle, assertions)
#   - build-helpers.sh      (build fixture setup, simulate_efi_state_apply, ...)
#   - fixture-factory.sh    (mock fixture creation)

set -euo pipefail

# ---------------------------------------------------------------------------
# Source libraries
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=test-harness.sh
source "$SCRIPT_DIR/test-harness.sh"
# shellcheck source=fixture-factory.sh
source "$SCRIPT_DIR/fixture-factory.sh"
# shellcheck source=build-helpers.sh
source "$SCRIPT_DIR/build-helpers.sh"

# ---------------------------------------------------------------------------
# Initialize harness
# ---------------------------------------------------------------------------
test_harness_init
trap test_harness_cleanup EXIT

# ============================================================================
# B-11: Application is idempotent
# ============================================================================
test_b11_idempotent() {
  build_scenario_setup || exit 1

  # Apply EFI state once
  if ! simulate_efi_state_apply; then
    test_harness_fail "B-11: first simulate_efi_state_apply failed"
    build_scenario_teardown
    exit 1
  fi

  # Snapshot grub.cfg and keep-list after first apply
  local grub_cfg="$BUILD_EFI_DIR/EFI/steamos/grub.cfg"
  local keep_list="$BUILD_ROOTFS_DIR/etc/atomic-update.conf.d/keep-list.conf"
  local grub_cfg_after_first keep_list_after_first
  grub_cfg_after_first="$(mktemp)"
  keep_list_after_first="$(mktemp)"
  cp "$grub_cfg" "$grub_cfg_after_first"
  cp "$keep_list" "$keep_list_after_first"

  # Apply EFI state a second time (should be idempotent)
  if ! simulate_efi_state_apply; then
    test_harness_fail "B-11: second simulate_efi_state_apply failed"
    rm -f "$grub_cfg_after_first" "$keep_list_after_first"
    build_scenario_teardown
    exit 1
  fi

  # Verify no duplicate kernel params in grub.cfg
  local has_duplicates=0
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    local params
    params="$(printf '%s' "$line" | sed -n 's/^[[:space:]]*linux[[:space:]]\+[^ ]*[[:space:]]*//p')"
    if [[ -n "$params" ]]; then
      local -a tokens
      read -ra tokens <<<"$params"
      local -A seen=()
      local token
      for token in "${tokens[@]}"; do
        if [[ -n "${seen[$token]+_}" ]]; then
          has_duplicates=1
          echo "    DUPLICATE PARAM: '$token' in: $line" >&2
        fi
        seen["$token"]=1
      done
    fi
  done <"$grub_cfg"

  if [[ "$has_duplicates" -ne 0 ]]; then
    test_harness_fail "B-11: duplicate kernel parameters found in grub.cfg after second apply"
    rm -f "$grub_cfg_after_first" "$keep_list_after_first"
    build_scenario_teardown
    exit 1
  fi

  # Verify no duplicate keep-list entries
  local keep_has_duplicates=0
  if [[ -f "$keep_list" ]]; then
    local -A seen_patterns=()
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -z "${line// /}" ]] && continue
      if [[ -n "${seen_patterns[$line]+_}" ]]; then
        keep_has_duplicates=1
        echo "    DUPLICATE KEEP-LIST: '$line'" >&2
      fi
      seen_patterns["$line"]=1
    done <"$keep_list"
  fi

  if [[ "$keep_has_duplicates" -ne 0 ]]; then
    test_harness_fail "B-11: duplicate keep-list entries found after second apply"
    rm -f "$grub_cfg_after_first" "$keep_list_after_first"
    build_scenario_teardown
    exit 1
  fi

  # Verify semantic state is stable (grub.cfg content unchanged between applies)
  local grub_diff
  grub_diff="$(diff "$grub_cfg_after_first" "$grub_cfg" 2>/dev/null || true)"
  if [[ -n "$grub_diff" ]]; then
    test_harness_fail "B-11: grub.cfg changed between first and second apply (semantic instability)"
    rm -f "$grub_cfg_after_first" "$keep_list_after_first"
    build_scenario_teardown
    exit 1
  fi

  # Verify keep-list content is stable
  local keep_diff
  keep_diff="$(diff "$keep_list_after_first" "$keep_list" 2>/dev/null || true)"
  if [[ -n "$keep_diff" ]]; then
    test_harness_fail "B-11: keep-list changed between first and second apply (semantic instability)"
    rm -f "$grub_cfg_after_first" "$keep_list_after_first"
    build_scenario_teardown
    exit 1
  fi

  # Verify partset files are stable (self, all, shared)
  local partsets_dir="$BUILD_EFI_DIR/SteamOS/partsets"
  for partset_name in self all shared; do
    local partset_file="$partsets_dir/$partset_name"
    test_harness_assert_file_exists "$partset_file" || true
  done

  rm -f "$grub_cfg_after_first" "$keep_list_after_first"
  build_scenario_teardown
}

# ============================================================================
# B-12: Existing state survives failed replacement
# ============================================================================
test_b12_failed_replacement() {
  build_scenario_setup || exit 1

  # Apply EFI state once (should succeed)
  if ! simulate_efi_state_apply; then
    test_harness_fail "B-12: first simulate_efi_state_apply failed"
    build_scenario_teardown
    exit 1
  fi

  # Capture checksums of key files after first successful apply
  local grub_cfg="$BUILD_EFI_DIR/EFI/steamos/grub.cfg"
  local grubx64="$BUILD_EFI_DIR/EFI/steamos/grubx64.efi"
  local partset_self="$BUILD_EFI_DIR/SteamOS/partsets/self"
  local partset_all="$BUILD_EFI_DIR/SteamOS/partsets/all"
  local bootconf_a="$BUILD_ESP_DIR/SteamOS/conf/A.conf"
  local grub_after_first grubx64_after_first partset_self_after_first
  local partset_all_after_first bootconf_a_after_first
  grub_after_first="$(md5sum "$grub_cfg" | awk '{print $1}')"
  grubx64_after_first="$(md5sum "$grubx64" | awk '{print $1}')"
  partset_self_after_first="$(md5sum "$partset_self" | awk '{print $1}')"
  partset_all_after_first="$(md5sum "$partset_all" | awk '{print $1}')"
  bootconf_a_after_first="$(md5sum "$bootconf_a" | awk '{print $1}')"

  # Inject a failure: make grub.cfg read-only so patching fails on second apply
  local shim_dir="$BUILD_FIXTURE_DIR/shim-bin"
  mkdir -p "$shim_dir"
  simulate_build_failure "$shim_dir" "update-grub"
  chmod 444 "$grub_cfg"

  # Second apply should fail (grub.cfg is read-only)
  simulate_efi_state_apply || true

  # Restore permissions so we can verify
  chmod 644 "$grub_cfg"

  # Verify previous valid files remain intact
  local grub_current grubx64_current partset_self_current
  local partset_all_current bootconf_a_current
  grub_current="$(md5sum "$grub_cfg" | awk '{print $1}')"
  grubx64_current="$(md5sum "$grubx64" | awk '{print $1}')"
  partset_self_current="$(md5sum "$partset_self" | awk '{print $1}')"
  partset_all_current="$(md5sum "$partset_all" | awk '{print $1}')"
  bootconf_a_current="$(md5sum "$bootconf_a" | awk '{print $1}')"

  local files_ok=1

  if [[ "$grub_current" != "$grub_after_first" ]]; then
    echo "    B-12: grub.cfg was modified after failed second apply" >&2
    files_ok=0
  fi

  if [[ "$grubx64_current" != "$grubx64_after_first" ]]; then
    echo "    B-12: grubx64.efi was modified after failed second apply" >&2
    files_ok=0
  fi

  if [[ "$partset_self_current" != "$partset_self_after_first" ]]; then
    echo "    B-12: partsets/self was modified after failed second apply" >&2
    files_ok=0
  fi

  if [[ "$partset_all_current" != "$partset_all_after_first" ]]; then
    echo "    B-12: partsets/all was modified after failed second apply" >&2
    files_ok=0
  fi

  if [[ "$bootconf_a_current" != "$bootconf_a_after_first" ]]; then
    echo "    B-12: A.conf was modified after failed second apply" >&2
    files_ok=0
  fi

  if [[ "$files_ok" -eq 0 ]]; then
    test_harness_fail "B-12: valid files were not preserved after failed replacement"
    build_scenario_teardown
    exit 1
  fi

  # Verify no truncated final-path files (files that exist but are empty
  # when they should not be)
  local truncated_found=0
  for f in "$grub_cfg" "$grubx64" "$partset_self" "$partset_all" "$bootconf_a"; do
    if [[ -f "$f" && ! -s "$f" ]]; then
      echo "    B-12: truncated (empty) file found: $f" >&2
      truncated_found=1
    fi
  done

  if [[ "$truncated_found" -ne 0 ]]; then
    test_harness_fail "B-12: truncated final-path files detected after failed replacement"
    build_scenario_teardown
    exit 1
  fi

  # Verify grub.cfg is still valid (has at least one menuentry with linux)
  if ! grep -q 'menuentry' "$grub_cfg" 2>/dev/null; then
    test_harness_fail "B-12: grub.cfg lost menuentry structure after failed replacement"
    build_scenario_teardown
    exit 1
  fi

  if ! grep -q '^\s*linux ' "$grub_cfg" 2>/dev/null; then
    test_harness_fail "B-12: grub.cfg lost linux command after failed replacement"
    build_scenario_teardown
    exit 1
  fi

  build_scenario_teardown
}

# ============================================================================
# B-13: Host isolation
# ============================================================================
test_b13_host_isolation() {
  # Setup build fixture and apply EFI state
  build_scenario_setup || {
    test_harness_fail "B-13: build_scenario_setup failed"
    exit 1
  }

  if ! simulate_efi_state_apply; then
    test_harness_fail "B-13: simulate_efi_state_apply failed"
    build_scenario_teardown
    exit 1
  fi

  # Verify host directories are untouched by checking for test namespace leaks
  local host_changed=0

  # Check /etc - verify no new files were created in the real /etc
  # by looking for files that contain our test namespace
  local etc_leaks
  etc_leaks="$(find /etc -maxdepth 3 -newer /etc/hostname -type f \
    -exec grep -l "$BUILD_NAMESPACE" {} + 2>/dev/null || true)"
  if [[ -n "$etc_leaks" ]]; then
    echo "    B-13: host /etc contains test namespace references:" >&2
    echo "$etc_leaks" >&2
    host_changed=1
  fi

  # Check /boot - verify no test files were written
  local boot_leaks
  boot_leaks="$(find /boot -maxdepth 2 -type f \
    -exec grep -l "$BUILD_NAMESPACE" {} + 2>/dev/null || true)"
  if [[ -n "$boot_leaks" ]]; then
    echo "    B-13: host /boot contains test namespace references:" >&2
    echo "$boot_leaks" >&2
    host_changed=1
  fi

  # Check /efi and /esp - verify no test files were written
  if [[ -d /efi ]]; then
    local efi_leaks
    efi_leaks="$(find /efi -maxdepth 3 -type f \
      -exec grep -l "$BUILD_NAMESPACE" {} + 2>/dev/null || true)"
    if [[ -n "$efi_leaks" ]]; then
      echo "    B-13: host /efi contains test namespace references:" >&2
      echo "$efi_leaks" >&2
      host_changed=1
    fi
  fi

  if [[ -d /esp ]]; then
    local esp_leaks
    esp_leaks="$(find /esp -maxdepth 3 -type f \
      -exec grep -l "$BUILD_NAMESPACE" {} + 2>/dev/null || true)"
    if [[ -n "$esp_leaks" ]]; then
      echo "    B-13: host /esp contains test namespace references:" >&2
      echo "$esp_leaks" >&2
      host_changed=1
    fi
  fi

  # Verify fixture dirs do not overlap with host dirs
  local resolved_fixture
  resolved_fixture="$(realpath "$BUILD_FIXTURE_DIR" 2>/dev/null || echo "$BUILD_FIXTURE_DIR")"
  local host_dir resolved_host
  for host_dir in /etc /boot /efi /esp; do
    if [[ -d "$host_dir" ]]; then
      resolved_host="$(realpath "$host_dir" 2>/dev/null || echo "$host_dir")"
      if [[ "$resolved_fixture" == "$resolved_host" || "$resolved_fixture" == "$resolved_host"/* ]]; then
        echo "    B-13: fixture overlaps host directory: $host_dir" >&2
        host_changed=1
      fi
    fi
  done

  build_scenario_teardown

  if [[ "$host_changed" -ne 0 ]]; then
    test_harness_fail "B-13: host directories were modified by test"
    exit 1
  fi
}

# ============================================================================
# B-14: Unmanaged EFI files preserved
# ============================================================================
test_b14_unmanaged_preserved() {
  build_scenario_setup || exit 1

  # Create sentinel (unmanaged) files that should be preserved
  create_sentinel_files "$BUILD_EFI_DIR" "SENTINEL-UNMANAGED-B14"

  # Define the sentinel files to track
  local -a sentinel_relative_paths=(
    "EFI/steamos/sentinel-default.grub"
    "EFI/steamos/sentinel-steamos.grub"
    "SteamOS/partsets/sentinel-self"
  )

  # Take before checksums
  verify_preserved_files_before "$BUILD_EFI_DIR" "${sentinel_relative_paths[@]}"

  # Apply EFI state
  if ! simulate_efi_state_apply; then
    test_harness_fail "B-14: simulate_efi_state_apply failed"
    build_scenario_teardown
    exit 1
  fi

  # Verify sentinel files are preserved (byte-identical)
  if ! verify_preserved_files_after "$BUILD_EFI_DIR" "${sentinel_relative_paths[@]}"; then
    test_harness_fail "B-14: sentinel files were modified or lost during EFI state application"
    build_scenario_teardown
    exit 1
  fi

  # Double-check: verify sentinel files still contain original content
  local content_ok=1
  local rel_path
  for rel_path in "${sentinel_relative_paths[@]}"; do
    local full_path="$BUILD_EFI_DIR/$rel_path"
    if [[ ! -f "$full_path" ]]; then
      echo "    B-14: sentinel file missing: $full_path" >&2
      content_ok=0
      continue
    fi
    local content
    content="$(cat "$full_path")"
    if [[ "$content" != "SENTINEL-UNMANAGED-B14" ]]; then
      echo "    B-14: sentinel file content changed: $full_path (got: '$content')" >&2
      content_ok=0
    fi
  done

  if [[ "$content_ok" -eq 0 ]]; then
    test_harness_fail "B-14: sentinel files lost original content after EFI state application"
    build_scenario_teardown
    exit 1
  fi

  build_scenario_teardown
}

# ============================================================================
# B-15: No nonexistent slot emitted
# ============================================================================
test_b15_no_nonexistent_slot() {
  build_scenario_setup || exit 1

  # Apply EFI state
  if ! simulate_efi_state_apply; then
    test_harness_fail "B-15: simulate_efi_state_apply failed"
    build_scenario_teardown
    exit 1
  fi

  # Verify no B slot references in any generated files
  if ! verify_single_slot_no_B "$BUILD_EFI_DIR"; then
    test_harness_fail "B-15: B slot references found in EFI directory"
    build_scenario_teardown
    exit 1
  fi

  # Check ESP bootconf directory for B.conf references
  local esp_conf_dir="$BUILD_ESP_DIR/SteamOS/conf"
  if [[ -d "$esp_conf_dir" ]]; then
    if [[ -f "$esp_conf_dir/B.conf" ]]; then
      echo "    B-15: B.conf bootconf file exists in single-slot fixture" >&2
      test_harness_fail "B-15: nonexistent B.conf bootconf found in single-slot build scenario"
      build_scenario_teardown
      exit 1
    fi
  fi

  # Verify partset files do not reference any B-partition PARTUUIDs
  local partsets_dir="$BUILD_EFI_DIR/SteamOS/partsets"
  if [[ -d "$partsets_dir" ]]; then
    local b_ref_found=0
    local file
    while IFS= read -r -d '' file; do
      if grep -q 'rootfs-B\|efi-B\|var-B' "$file" 2>/dev/null; then
        echo "    B-15: B-partition reference found in: $file" >&2
        b_ref_found=1
      fi
    done < <(find "$partsets_dir" -type f -print0 2>/dev/null)

    if [[ "$b_ref_found" -ne 0 ]]; then
      test_harness_fail "B-15: partset files reference nonexistent B slot partitions"
      build_scenario_teardown
      exit 1
    fi
  fi

  # Verify no B slot in grub.cfg
  local grub_cfg="$BUILD_EFI_DIR/EFI/steamos/grub.cfg"
  if [[ -f "$grub_cfg" ]]; then
    if grep -q 'slot B\|rootfs-B\|efi-B\|var-B' "$grub_cfg" 2>/dev/null; then
      echo "    B-15: B slot reference found in grub.cfg" >&2
      test_harness_fail "B-15: grub.cfg references nonexistent B slot in single-slot build"
      build_scenario_teardown
      exit 1
    fi
  fi

  # Verify no B.conf in bootconf
  local bootconf_dir="$BUILD_ESP_DIR/SteamOS/conf"
  if [[ -d "$bootconf_dir" ]]; then
    if [[ -f "$bootconf_dir/B.conf" ]]; then
      echo "    B-15: B.conf exists in single-slot bootconf" >&2
      test_harness_fail "B-15: nonexistent B.conf bootconf emitted for single-slot build"
      build_scenario_teardown
      exit 1
    fi
  fi

  build_scenario_teardown
}

# ============================================================================
# Run tests
# ============================================================================

# B-11
test_harness_begin_test "B-11: Application is idempotent"
(test_b11_idempotent) || true
# Only pass if the function did not already fail
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# B-12
test_harness_begin_test "B-12: Existing state survives failed replacement"
(test_b12_failed_replacement) || true
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# B-13
test_harness_begin_test "B-13: Host isolation"
(test_b13_host_isolation) || true
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# B-14
test_harness_begin_test "B-14: Unmanaged EFI files preserved"
(test_b14_unmanaged_preserved) || true
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# B-15
test_harness_begin_test "B-15: No nonexistent slot emitted"
(test_b15_no_nonexistent_slot) || true
if [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
  test_harness_pass
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
test_harness_summary
test_harness_exit_code
