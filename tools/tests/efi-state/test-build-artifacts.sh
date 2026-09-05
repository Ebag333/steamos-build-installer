#!/bin/bash
#
# tools/tests/efi-state/test-build-artifacts.sh
# Build scenario tests B-01 through B-05.
#
# Tests for single-slot (target A) build scenario: artifact generation
# correctness, EFI binary structure, GRUB configuration, partset content,
# and bootconf creation.
#
# Dependencies:
#   - test-harness.sh    (test lifecycle, assertions)
#   - build-helpers.sh   (build scenario setup/teardown, EFI state simulation)
#   - fixture-factory.sh (mock fixture creation, UUID derivation)
#   - validators.sh      (structural validators)
#   - topology.sh        (deterministic UUID/PARTUUID generation)

# ---------------------------------------------------------------------------
# Guard: source-only
# ---------------------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "test-build-artifacts.sh is a library — source it, don't execute it directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Resolve SCRIPT_DIR relative to this file for sourcing dependencies
# ---------------------------------------------------------------------------

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Source dependencies (order matters: harness first, then factories, helpers)
# ---------------------------------------------------------------------------

# shellcheck source=test-harness.sh
# shellcheck disable=SC1091
source "$_SCRIPT_DIR/test-harness.sh"
# shellcheck source=fixture-factory.sh
# shellcheck disable=SC1091
source "$_SCRIPT_DIR/fixture-factory.sh"
# shellcheck source=build-helpers.sh
# shellcheck disable=SC1091
source "$_SCRIPT_DIR/build-helpers.sh"
# shellcheck source=validators.sh
# shellcheck disable=SC1091
source "$_SCRIPT_DIR/validators.sh"
# shellcheck source=topology.sh
# shellcheck disable=SC1091
source "$_SCRIPT_DIR/topology.sh"

# ---------------------------------------------------------------------------
# B-01: Happy path — all generated artifacts pass semantic validation
#
# Setup build fixture → apply EFI state → run all validators → verify pass.
# ---------------------------------------------------------------------------

test_b01_all_artifacts_pass_semantic_validation() {
  test_harness_begin_test "B-01: Happy path — all generated artifacts pass semantic validation"

  # Setup build fixture
  build_scenario_setup || {
    test_harness_fail "build_scenario_setup failed"
    return
  }

  # Register cleanup
  test_harness_register_cleanup build_scenario_teardown

  # Apply EFI state
  simulate_efi_state_apply || {
    test_harness_fail "simulate_efi_state_apply failed"
    build_scenario_teardown
    return
  }

  local rc=0

  # Run all validators against the fixture
  validate_grub_structure "$BUILD_ROOTFS_DIR" "$BUILD_EFI_DIR" "$BUILD_TARGET_UUID" || rc=1
  validate_binary_structure "$BUILD_EFI_DIR" || rc=1
  validate_boot_paths "$BUILD_ROOTFS_DIR" "$BUILD_TARGET_UUID" || rc=1
  validate_partsets "$BUILD_EFI_DIR" "self,all,shared" || rc=1
  validate_bootconf "$BUILD_ESP_DIR/SteamOS/conf" "A.conf" || rc=1

  build_scenario_teardown

  if [[ "$rc" -ne 0 ]]; then
    test_harness_fail "one or more validators failed"
    return
  fi

  test_harness_pass
}

# ---------------------------------------------------------------------------
# B-02: EFI binary generated correctly
#
# Setup build fixture → apply EFI state → verify grubx64.efi is nonempty,
# valid PE, and contains the target UUID.
# ---------------------------------------------------------------------------

test_b02_efi_binary_generated_correctly() {
  test_harness_begin_test "B-02: EFI binary generated correctly"

  build_scenario_setup || {
    test_harness_fail "build_scenario_setup failed"
    return
  }
  test_harness_register_cleanup build_scenario_teardown

  simulate_efi_state_apply || {
    test_harness_fail "simulate_efi_state_apply failed"
    build_scenario_teardown
    return
  }

  local grubx64="$BUILD_EFI_DIR/EFI/steamos/grubx64.efi"

  # Verify the file exists
  test_harness_assert_file_exists "$grubx64" || {
    build_scenario_teardown
    return
  }

  # Verify it is nonempty
  local file_size
  file_size="$(stat -c '%s' "$grubx64" 2>/dev/null || echo 0)"
  if [[ "$file_size" -eq 0 ]]; then
    test_harness_fail "grubx64.efi is empty"
    build_scenario_teardown
    return
  fi

  # Verify valid PE (MZ header)
  local mz_header
  mz_header="$(dd if="$grubx64" bs=1 count=2 2>/dev/null | od -A n -t x1 | tr -d ' ')"
  test_harness_assert_eq "$mz_header" "4d5a" || {
    build_scenario_teardown
    return
  }

  # Verify it contains the target UUID
  local uuid_pattern='[0-9a-fA-F]\{8\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{12\}'
  local embedded_uuid
  embedded_uuid="$(strings "$grubx64" 2>/dev/null | grep -oE "$uuid_pattern" | head -1)"

  if [[ -z "$embedded_uuid" ]]; then
    test_harness_fail "grubx64.efi does not contain an embedded UUID"
    build_scenario_teardown
    return
  fi

  test_harness_assert_eq "$embedded_uuid" "$BUILD_TARGET_UUID" || {
    build_scenario_teardown
    return
  }

  build_scenario_teardown
  test_harness_pass
}

# ---------------------------------------------------------------------------
# B-03: GRUB configuration generated correctly
#
# Setup build fixture → apply EFI state → verify entries use target UUID
# and required params appear exactly once per entry.
# ---------------------------------------------------------------------------

test_b03_grub_configuration_generated_correctly() {
  test_harness_begin_test "B-03: GRUB configuration generated correctly"

  build_scenario_setup || {
    test_harness_fail "build_scenario_setup failed"
    return
  }
  test_harness_register_cleanup build_scenario_teardown

  simulate_efi_state_apply || {
    test_harness_fail "simulate_efi_state_apply failed"
    build_scenario_teardown
    return
  }

  local grub_cfg="$BUILD_EFI_DIR/EFI/steamos/grub.cfg"

  # Verify grub.cfg exists
  test_harness_assert_file_exists "$grub_cfg" || {
    build_scenario_teardown
    return
  }

  # Verify entries use target UUID (search --fs-uuid lines reference target)
  local expected_uuid_count
  expected_uuid_count="$(grep -c "search.*--fs-uuid.*--set=root.*${BUILD_TARGET_UUID}" "$grub_cfg" 2>/dev/null || echo 0)"

  if [[ "$expected_uuid_count" -lt 1 ]]; then
    test_harness_fail "no search --fs-uuid entries reference target UUID '${BUILD_TARGET_UUID}'"
    build_scenario_teardown
    return
  fi

  # Verify no stale UUIDs are present
  local stale_count
  stale_count="$(grep 'search.*--fs-uuid.*--set=root' "$grub_cfg" 2>/dev/null \
    | grep -cv "$BUILD_TARGET_UUID" 2>/dev/null || echo 0)"

  if [[ "$stale_count" -gt 0 ]]; then
    test_harness_fail "grub.cfg contains stale UUIDs (non-target references on search lines)"
    build_scenario_teardown
    return
  fi

  # Verify required params appear exactly once per entry
  # Required params: root=UUID=<target> should appear on each linux line exactly once
  local required_param="root=UUID=${BUILD_TARGET_UUID}"
  local linux_line_count
  linux_line_count="$(grep -c '^\s*linux ' "$grub_cfg" 2>/dev/null || echo 0)"

  if [[ "$linux_line_count" -eq 0 ]]; then
    test_harness_fail "no linux commands found in grub.cfg"
    build_scenario_teardown
    return
  fi

  local param_total_count
  param_total_count="$(grep -o "$required_param" "$grub_cfg" 2>/dev/null | wc -l)"

  # Each linux line should have exactly one root=UUID=... param,
  # so total occurrences == linux line count
  if [[ "$param_total_count" -ne "$linux_line_count" ]]; then
    test_harness_fail "root=UUID param count ($param_total_count) != linux line count ($linux_line_count)"
    build_scenario_teardown
    return
  fi

  build_scenario_teardown
  test_harness_pass
}

# ---------------------------------------------------------------------------
# B-04: Partsets contain target identities
#
# Setup build fixture → apply EFI state → verify partset files are regular
# files (not symlinks) and contain exact target PARTUUIDs.
# ---------------------------------------------------------------------------

test_b04_partsets_contain_target_identities() {
  test_harness_begin_test "B-04: Partsets contain target identities"

  build_scenario_setup || {
    test_harness_fail "build_scenario_setup failed"
    return
  }
  test_harness_register_cleanup build_scenario_teardown

  simulate_efi_state_apply || {
    test_harness_fail "simulate_efi_state_apply failed"
    build_scenario_teardown
    return
  }

  local partsets_dir="$BUILD_EFI_DIR/SteamOS/partsets"
  local rc=0

  # Derive expected PARTUUIDs for the target (slot A)
  local expected_rootfs_partuuid expected_efi_partuuid expected_var_partuuid
  expected_rootfs_partuuid="$(derive_partuuid "$BUILD_NAMESPACE" "rootfs-A")"
  expected_efi_partuuid="$(derive_partuuid "$BUILD_NAMESPACE" "efi-A")"
  expected_var_partuuid="$(derive_partuuid "$BUILD_NAMESPACE" "var-A")"

  # Derive expected ESP PARTUUID
  local expected_esp_partuuid
  expected_esp_partuuid="$(derive_partuuid "$BUILD_NAMESPACE" "esp")"

  local partuuid_pattern='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

  # Verify each partset file
  for partset_name in self all shared; do
    local partset_file="$partsets_dir/$partset_name"

    # Verify file exists
    test_harness_assert_file_exists "$partset_file" || {
      rc=1
      continue
    }

    # Verify it is a regular file (not a symlink)
    if [[ -L "$partset_file" ]]; then
      echo "    ASSERTION FAILED: partset '$partset_name' is a symlink" >&2
      test_harness_fail "partset file '$partset_name' is a symlink, expected regular file"
      rc=1
      continue
    fi

    # Verify it is not empty
    if [[ ! -s "$partset_file" ]]; then
      echo "    ASSERTION FAILED: partset '$partset_name' is empty" >&2
      test_harness_fail "partset file '$partset_name' is empty"
      rc=1
      continue
    fi

    # Verify lines contain valid PARTUUIDs
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -z "${line// /}" ]] && continue

      local role uuid
      read -r role uuid _extra <<<"$line"
      if [[ -n "$uuid" ]] && ! [[ "$uuid" =~ $partuuid_pattern ]]; then
        echo "    ASSERTION FAILED: partset '$partset_name' has invalid PARTUUID: '$uuid'" >&2
        test_harness_fail "invalid PARTUUID format in partset '$partset_name'"
        rc=1
      fi
    done <"$partset_file"
  done

  # Verify "self" partset contains the exact target PARTUUIDs
  if [[ -f "$partsets_dir/self" ]]; then
    local has_rootfs=0 has_efi=0 has_var=0
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -z "${line// /}" ]] && continue

      local role uuid
      read -r role uuid _extra <<<"$line"
      case "$role" in
        rootfs) [[ "$uuid" == "$expected_rootfs_partuuid" ]] && has_rootfs=1 ;;
        efi) [[ "$uuid" == "$expected_efi_partuuid" ]] && has_efi=1 ;;
        var) [[ "$uuid" == "$expected_var_partuuid" ]] && has_var=1 ;;
      esac
    done <"$partsets_dir/self"

    if [[ "$has_rootfs" -ne 1 ]]; then
      echo "    ASSERTION FAILED: self partset missing rootfs PARTUUID '$expected_rootfs_partuuid'" >&2
      test_harness_fail "self partset does not contain expected rootfs PARTUUID"
      rc=1
    fi
    if [[ "$has_efi" -ne 1 ]]; then
      echo "    ASSERTION FAILED: self partset missing efi PARTUUID '$expected_efi_partuuid'" >&2
      test_harness_fail "self partset does not contain expected efi PARTUUID"
      rc=1
    fi
    if [[ "$has_var" -ne 1 ]]; then
      echo "    ASSERTION FAILED: self partset missing var PARTUUID '$expected_var_partuuid'" >&2
      test_harness_fail "self partset does not contain expected var PARTUUID"
      rc=1
    fi
  fi

  # Verify "all" partset contains target PARTUUIDs (slot A + ESP for single-slot)
  if [[ -f "$partsets_dir/all" ]]; then
    local all_has_rootfs_a=0 all_has_esp=0
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -z "${line// /}" ]] && continue
      local role uuid
      read -r role uuid _extra <<<"$line"
      if [[ "$role" == "rootfs" && "$uuid" == "$expected_rootfs_partuuid" ]]; then
        all_has_rootfs_a=1
      fi
      if [[ "$uuid" == "$expected_esp_partuuid" ]]; then
        all_has_esp=1
      fi
    done <"$partsets_dir/all"

    if [[ "$all_has_rootfs_a" -ne 1 ]]; then
      echo "    ASSERTION FAILED: all partset missing rootfs-A PARTUUID" >&2
      test_harness_fail "all partset does not contain rootfs-A PARTUUID"
      rc=1
    fi
    if [[ "$all_has_esp" -ne 1 ]]; then
      echo "    ASSERTION FAILED: all partset missing esp PARTUUID" >&2
      test_harness_fail "all partset does not contain esp PARTUUID"
      rc=1
    fi
  fi

  build_scenario_teardown

  if [[ "$rc" -ne 0 ]]; then
    test_harness_fail "partset identity verification failed"
    return
  fi

  test_harness_pass
}

# ---------------------------------------------------------------------------
# B-05: Slot-A bootconf created
#
# Setup build fixture → apply EFI state → verify A.conf exists, is
# parseable, and contains expected build-state values.
# ---------------------------------------------------------------------------

test_b05_slot_a_bootconf_created() {
  test_harness_begin_test "B-05: Slot-A bootconf created"

  build_scenario_setup || {
    test_harness_fail "build_scenario_setup failed"
    return
  }
  test_harness_register_cleanup build_scenario_teardown

  simulate_efi_state_apply || {
    test_harness_fail "simulate_efi_state_apply failed"
    build_scenario_teardown
    return
  }

  local conf_dir="$BUILD_ESP_DIR/SteamOS/conf"
  local a_conf="$conf_dir/A.conf"
  local rc=0

  # Verify A.conf exists
  test_harness_assert_file_exists "$a_conf" || {
    build_scenario_teardown
    return
  }

  # Verify A.conf is a regular file (not a symlink)
  if [[ -L "$a_conf" ]]; then
    test_harness_fail "A.conf is a symlink, expected regular file"
    build_scenario_teardown
    return
  fi

  # Verify A.conf is nonempty
  if [[ ! -s "$a_conf" ]]; then
    test_harness_fail "A.conf is empty"
    build_scenario_teardown
    return
  fi

  # Verify A.conf is parseable (key=value format, no syntax errors)
  local content
  content="$(cat "$a_conf")"

  # Parse key=value pairs; reject lines that are neither comments nor key=value
  local parse_error=0
  while IFS= read -r line; do
    # Skip blank lines and comments
    [[ -z "${line// /}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    # Must be key=value format
    if ! [[ "$line" =~ ^[[:space:]]*[a-zA-Z0-9_-]+=[^[:space:]] ]]; then
      echo "    ASSERTION FAILED: A.conf has unparseable line: '$line'" >&2
      test_harness_fail "A.conf contains unparseable line"
      parse_error=1
      break
    fi
  done <<<"$content"

  if [[ "$parse_error" -ne 0 ]]; then
    build_scenario_teardown
    return
  fi

  # Verify required fields are present with correct values
  local title_value
  title_value="$(printf '%s\n' "$content" | grep -v '^\s*#' | grep '^title=' | head -1 | cut -d= -f2-)"
  if [[ -z "$title_value" ]]; then
    test_harness_fail "A.conf missing 'title' field"
    rc=1
  fi

  local image_invalid_value
  image_invalid_value="$(printf '%s\n' "$content" | grep -v '^\s*#' | grep '^image-invalid=' | head -1 | cut -d= -f2-)"
  if [[ -z "$image_invalid_value" ]]; then
    test_harness_fail "A.conf missing 'image-invalid' field"
    rc=1
  else
    # image-invalid should be 0 for a valid build slot
    test_harness_assert_eq "$image_invalid_value" "0" || rc=1
  fi

  local boot_attempts_value
  boot_attempts_value="$(printf '%s\n' "$content" | grep -v '^\s*#' | grep '^boot-attempts=' | head -1 | cut -d= -f2-)"
  if [[ -z "$boot_attempts_value" ]]; then
    test_harness_fail "A.conf missing 'boot-attempts' field"
    rc=1
  else
    # boot-attempts should be 0 for a fresh build
    test_harness_assert_eq "$boot_attempts_value" "0" || rc=1
  fi

  # Verify title references slot A
  if [[ -n "$title_value" ]]; then
    local has_slot_a=0
    case "$title_value" in
      *"slot A"* | *"(A)"*) has_slot_a=1 ;;
    esac
    if [[ "$has_slot_a" -ne 1 ]]; then
      echo "    ASSERTION FAILED: A.conf title does not reference slot A: '$title_value'" >&2
      test_harness_fail "A.conf title does not reference slot A"
      rc=1
    fi
  fi

  build_scenario_teardown

  if [[ "$rc" -ne 0 ]]; then
    test_harness_fail "bootconf validation failed"
    return
  fi

  test_harness_pass
}

# ---------------------------------------------------------------------------
# Test runner — when sourced, this array is populated for the caller
# ---------------------------------------------------------------------------

# shellcheck disable=SC2034  # BUILD_ARTIFACT_TESTS is part of the public API (read by consumers)
BUILD_ARTIFACT_TESTS=(
  test_b01_all_artifacts_pass_semantic_validation
  test_b02_efi_binary_generated_correctly
  test_b03_grub_configuration_generated_correctly
  test_b04_partsets_contain_target_identities
  test_b05_slot_a_bootconf_created
)
