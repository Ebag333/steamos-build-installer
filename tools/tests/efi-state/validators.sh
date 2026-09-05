#!/bin/bash
#
# tools/tests/efi-state/validators.sh
# Validator profiles for the EFI state application test suite.
#
# Each validator is a self-contained function that inspects a mounted
# rootfs and optional EFI partition, asserts structural invariants,
# and returns 0 on success / 1 on failure.
#
# Validators are feature-agnostic: they verify *structure*, not content
# (e.g. "a linux entry exists", not "nvidia is listed on the cmdline").
#
# Usage:
#   source tools/tests/efi-state/validators.sh
#
#   validate_grub_structure "$rootfs_dir" "$efi_dir" "$expected_uuid"
#
# Validator profiles:
#   validate_grub_structure   - GRUB config structure and binary integrity
#   validate_binary_structure - EFI binary structure (grubx64.efi)

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "validators.sh is a library — source it, don't execute it directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Guard: ensure test-harness.sh assertion helpers are available
# ---------------------------------------------------------------------------
if ! declare -f test_harness_assert_file_exists >/dev/null 2>&1; then
  echo "ERROR: validators.sh requires test-harness.sh (source it first)." >&2
  return 1 2>/dev/null || exit 1
fi

# ===========================================================================
# validate_grub_structure ROOTFS_DIR EFI_DIR EXPECTED_UUID
#
# Validate GRUB configuration structure and binary integrity.
#
# Arguments:
#   ROOTFS_DIR   - Path to the mounted root filesystem (required).
#   EFI_DIR      - Path to the mounted EFI partition (required).
#   EXPECTED_UUID - The UUID that search --fs-uuid entries must resolve to (required).
#
# Checks performed:
#   1. grub.cfg exists and is nonempty
#   2. At least one steamenv_boot linux entry exists (excluding comments)
#   3. Each linux entry has a search --fs-uuid --set=root command
#   4. UUID in search matches EXPECTED_UUID
#   5. No stale UUIDs present (UUID != EXPECTED_UUID on any search line)
#   6. Kernel paths referenced by linux entries exist in rootfs
#   7. Initramfs paths referenced by initrd entries exist in rootfs
#   8. grubx64.efi exists and is a valid PE binary (MZ header check)
#
# Returns:
#   0 - all checks passed
#   1 - one or more checks failed (details emitted via harness)
# ===========================================================================
validate_grub_structure() {
  local rootfs_dir="${1:?validate_grub_structure: missing ROOTFS_DIR}"
  local efi_dir="${2:?validate_grub_structure: missing EFI_DIR}"
  local expected_uuid="${3:?validate_grub_structure: missing EXPECTED_UUID}"

  local grub_cfg="$efi_dir/EFI/steamos/grub.cfg"
  local grubx64="$efi_dir/EFI/steamos/grubx64.efi"
  local rc=0

  # ── 1. grub.cfg exists and is nonempty ───────────────────────────────────
  test_harness_assert_file_exists "$grub_cfg" || {
    rc=1
    return 1
  }

  if [[ ! -s "$grub_cfg" ]]; then
    echo "    ASSERTION FAILED: grub.cfg is empty: '$grub_cfg'" >&2
    test_harness_fail "grub.cfg exists but is empty"
    return 1
  fi

  # ── 2. At least one steamenv_boot linux entry exists (excl. comments) ────
  # We define a "linux entry" as a non-comment, non-blank line that contains
  # the keyword 'linux ' (with a space) — GRUB's linux command.
  # Filter out lines that are pure comments (# ...) and blank lines.
  local non_comment_content
  non_comment_content="$(grep -v '^\s*#' "$grub_cfg" | grep -v '^\s*$')"

  if [[ -z "$non_comment_content" ]]; then
    echo "    ASSERTION FAILED: grub.cfg contains only comments/whitespace" >&2
    test_harness_fail "no executable entries in grub.cfg (only comments)"
    return 1
  fi

  # Check for at least one steamenv_boot linux menuentry.
  # A "steamenv_boot" entry is a menuentry whose body contains 'linux '
  # and whose overall block is identified by the steamenv_boot marker or
  # simply any menuentry block. We look for menuentry lines (to count
  # entries) and linux lines within them.
  local menuentry_count
  menuentry_count="$(grep -c '^\s*menuentry ' "$grub_cfg" 2>/dev/null || true)"
  if [[ "$menuentry_count" -lt 1 ]]; then
    echo "    ASSERTION FAILED: no menuentry blocks found in grub.cfg" >&2
    test_harness_fail "expected at least one menuentry in grub.cfg"
    return 1
  fi

  # Check for at least one linux command line
  local linux_count
  linux_count="$(grep -c '^\s*linux ' "$grub_cfg" 2>/dev/null || true)"
  if [[ "$linux_count" -lt 1 ]]; then
    echo "    ASSERTION FAILED: no 'linux' commands found in grub.cfg" >&2
    test_harness_fail "expected at least one linux command in grub.cfg"
    return 1
  fi

  # ── 3. Each linux entry has a search --fs-uuid --set=root command ────────
  # Extract all non-comment lines, then scan for search lines.
  # Every menuentry block must have a search --fs-uuid --set=root before
  # its linux command. We verify by checking that the global config
  # contains at least one such search line (global search applies to all
  # entries) or that per-entry searches exist.
  local search_uuid_count
  search_uuid_count="$(grep -c 'search.*--fs-uuid.*--set=root' "$grub_cfg" 2>/dev/null || true)"
  if [[ "$search_uuid_count" -lt 1 ]]; then
    echo "    ASSERTION FAILED: no 'search --fs-uuid --set=root' found in grub.cfg" >&2
    test_harness_fail "each linux entry requires a search --fs-uuid --set=root command"
    return 1
  fi

  # ── 4. UUID in search matches EXPECTED_UUID ──────────────────────────────
  # Extract the UUID from each search line and verify it matches.
  local stale_uuid_found=0
  while IFS= read -r line; do
    # Skip comments
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    # Skip blank lines
    [[ -z "${line// /}" ]] && continue
    # Extract UUID after --set=root
    local found_uuid
    found_uuid="$(printf '%s' "$line" | grep -oP 'search.*--fs-uuid.*--set=root\s+\K[0-9a-fA-F-]+')"
    if [[ -z "$found_uuid" ]]; then
      continue
    fi
    # Check match
    if [[ "$found_uuid" != "$expected_uuid" ]]; then
      stale_uuid_found=1
    fi
  done <"$grub_cfg"

  # Now do the positive assertion: at least one search line must use expected_uuid
  local expected_uuid_count
  expected_uuid_count="$(grep -c "search.*--fs-uuid.*--set=root.*${expected_uuid}" "$grub_cfg" 2>/dev/null || true)"
  if [[ "$expected_uuid_count" -lt 1 ]]; then
    echo "    ASSERTION FAILED: no search line uses expected UUID '$expected_uuid'" >&2
    test_harness_fail "search --fs-uuid --set=root does not reference expected UUID"
    rc=1
  fi

  # ── 5. No stale UUIDs present ────────────────────────────────────────────
  # Re-scan: any UUID on a search line that is NOT the expected UUID is stale.
  if [[ "$stale_uuid_found" -eq 1 ]]; then
    # Find the specific stale UUID for the diagnostic
    local stale_uuid
    stale_uuid="$(grep 'search.*--fs-uuid.*--set=root' "$grub_cfg" \
      | grep -v "$expected_uuid" \
      | grep -oP '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' \
      | head -1)"
    echo "    ASSERTION FAILED: stale UUID '$stale_uuid' found in grub.cfg" >&2
    test_harness_fail "grub.cfg contains stale UUID '$stale_uuid', expected '$expected_uuid'"
    rc=1
  fi

  # ── 6. Kernel paths referenced by linux entries exist in rootfs ───────────
  # Extract kernel paths from 'linux /path/to/vmlinuz-...' lines.
  local kernel_path
  while IFS= read -r line; do
    # Skip comments and blanks
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    # Extract the path: 'linux <path> ...'
    kernel_path="$(printf '%s' "$line" | sed -n 's/^[[:space:]]*linux[[:space:]]\+\([^[:space:]]*\).*/\1/p')"
    if [[ -n "$kernel_path" ]]; then
      # Resolve relative paths against rootfs
      local full_kernel_path
      if [[ "$kernel_path" == /* ]]; then
        full_kernel_path="$rootfs_dir$kernel_path"
      else
        full_kernel_path="$rootfs_dir/$kernel_path"
      fi
      test_harness_assert_file_exists "$full_kernel_path" || { rc=1; }
    fi
  done <<<"$non_comment_content"

  # ── 7. Initramfs paths referenced by initrd entries exist in rootfs ──────
  # Extract initramfs paths from 'initrd /path/to/initramfs-...' lines.
  # initrd can list multiple paths separated by spaces.
  local initrd_line
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    initrd_line="$(printf '%s' "$line" | sed -n 's/^[[:space:]]*initrd[[:space:]]\+//p')"
    if [[ -n "$initrd_line" ]]; then
      # Split on spaces — initrd can have multiple initrd paths
      local -a initrd_paths
      read -ra initrd_paths <<<"$initrd_line"
      local initrd_path
      for initrd_path in "${initrd_paths[@]}"; do
        [[ -z "$initrd_path" ]] && continue
        local full_initrd_path
        if [[ "$initrd_path" == /* ]]; then
          full_initrd_path="$rootfs_dir$initrd_path"
        else
          full_initrd_path="$rootfs_dir/$initrd_path"
        fi
        test_harness_assert_file_exists "$full_initrd_path" || { rc=1; }
      done
    fi
  done <<<"$non_comment_content"

  # ── 8. grubx64.efi exists and is a valid PE binary (MZ header) ──────────
  test_harness_assert_file_exists "$grubx64" || {
    rc=1
    return $rc
  }

  # Check MZ header (first two bytes must be 0x4D 0x5A = "MZ")
  local mz_header
  mz_header="$(dd if="$grubx64" bs=1 count=2 2>/dev/null | od -A n -t x1 | tr -d ' ')"
  if [[ "$mz_header" != "4d5a" ]]; then
    echo "    ASSERTION FAILED: grubx64.efi does not have MZ header (got: $mz_header)" >&2
    test_harness_fail "grubx64.efi is not a valid PE binary (missing MZ header)"
    rc=1
  fi

  # ── Return result ────────────────────────────────────────────────────────
  return $rc
}

# ===========================================================================
# validate_binary_structure EFI_MOUNT_PATH
#
# Validate that the EFI binary at <EFI_MOUNT_PATH>/EFI/steamos/grubx64.efi
# has a structurally correct PE32+ layout with an embedded target UUID
# and no stale UUIDs.
#
# Checks performed (Section 7.2 of the test plan):
#   1. grubx64.efi exists at EFI/steamos/grubx64.efi
#   2. File is nonempty
#   3. File starts with MZ header (PE32+ format)
#   4. Binary contains a target UUID (embedded UUID search)
#   5. No stale UUIDs are present (only the expected target UUID)
#
# Uses test_harness_assert_* helpers for all assertions.
#
# Arguments:
#   EFI_MOUNT_PATH - Root of the EFI partition directory tree
#
# Returns:
#   0 - All structural checks passed
#   1 - One or more checks failed (assertions recorded via test harness)
# ===========================================================================
validate_binary_structure() {
  local efi_mount="${1:?validate_binary_structure: missing EFI_MOUNT_PATH}"
  local efi_binary="${efi_mount}/EFI/steamos/grubx64.efi"

  # ── Check 1: File exists ────────────────────────────────────────────────
  test_harness_assert_file_exists "$efi_binary"

  # Guard: if the file doesn't exist, skip remaining checks to avoid
  # spurious errors on a missing file.
  if [[ ! -f "$efi_binary" ]]; then
    return 1
  fi

  # ── Check 2: File is nonempty ───────────────────────────────────────────
  local file_size
  file_size="$(stat -c '%s' "$efi_binary" 2>/dev/null || echo 0)"

  if [[ "$file_size" -eq 0 ]]; then
    echo "    ASSERTION FAILED: file is empty: '$efi_binary'" >&2
    test_harness_fail "EFI binary is empty: '$efi_binary'"
    return 1
  fi

  # ── Check 3: MZ header (PE32+ format) ──────────────────────────────────
  local mz_header
  mz_header="$(dd if="$efi_binary" bs=1 count=2 2>/dev/null | od -A n -t x1 | tr -d ' ')"

  test_harness_assert_eq "$mz_header" "4d5a"

  # ── Check 4: Binary contains a target UUID ──────────────────────────────
  # Search for a UUID pattern in the binary. UUIDs are embedded as ASCII
  # strings in the PE data section (offset 0x100 in mock fixtures).
  # Pattern: 8 hex chars, dash, 4 hex chars, dash, 4 hex chars, dash,
  #          4 hex chars, dash, 12 hex chars.
  local uuid_pattern='[0-9a-fA-F]\{8\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{12\}'
  local embedded_uuid
  embedded_uuid="$(strings "$efi_binary" 2>/dev/null | grep -oE "$uuid_pattern" | head -1)"

  if [[ -z "$embedded_uuid" ]]; then
    echo "    ASSERTION FAILED: no UUID found embedded in '$efi_binary'" >&2
    test_harness_fail "EFI binary does not contain an embedded UUID"
    return 1
  fi

  # ── Check 5: No stale UUIDs ────────────────────────────────────────────
  # Collect all UUIDs found in the binary. A structurally correct binary
  # should contain exactly one UUID (the current target). Multiple UUIDs
  # indicate stale references from a previous build that were not cleaned
  # up properly.
  local -a all_uuids
  mapfile -t all_uuids < <(strings "$efi_binary" 2>/dev/null | grep -oE "$uuid_pattern")

  if [[ "${#all_uuids[@]}" -gt 1 ]]; then
    echo "    ASSERTION FAILED: multiple UUIDs found in EFI binary:" >&2
    printf "      %s\n" "${all_uuids[@]}" >&2
    test_harness_fail "EFI binary contains ${#all_uuids[@]} UUIDs (expected 1 — stale references present)"
    return 1
  fi

  return 0
}

# ===========================================================================
# validate_boot_paths ROOTFS_DIR EXPECTED_UUID [KERNEL_VERSION]
#
# Validate that the rootfs contains expected kernel and initramfs files,
# and that all paths referenced are safe (no symlink escapes).
#
# Arguments:
#   ROOTFS_DIR      - Path to the mounted root filesystem (required).
#   EXPECTED_UUID   - The rootfs UUID (used for path safety context).
#   KERNEL_VERSION  - Kernel version string (default: 6.1.52-neptune-61).
#
# Checks performed:
#   1. /boot directory exists and is a real directory (not a symlink)
#   2. vmlinuz-<KERNEL_VERSION> exists and is a regular file
#   3. initramfs-<KERNEL_VERSION>.img exists and is a regular file
#   4. amd-ucode.img exists and is a regular file
#   5. No boot files are symlinks (escape risk)
#   6. Paths do not resolve outside rootfs (containment check)
#
# Returns:
#   0 - all checks passed
#   1 - one or more checks failed (details emitted via harness)
# ===========================================================================
validate_boot_paths() {
  local rootfs_dir="${1:?validate_boot_paths: missing ROOTFS_DIR}"
  local expected_uuid="${2:?validate_boot_paths: missing EXPECTED_UUID}"
  local kernel_version="${3:-6.1.52-neptune-61}"

  local boot_dir="$rootfs_dir/boot"
  local rc=0

  # ── 1. /boot directory exists and is a real directory ───────────────────
  test_harness_assert_dir_exists "$boot_dir" || {
    rc=1
    return 1
  }

  if [[ -L "$boot_dir" ]]; then
    echo "    ASSERTION FAILED: /boot is a symlink (escape risk): '$boot_dir'" >&2
    test_harness_fail "/boot must not be a symlink"
    return 1
  fi

  # ── 2. vmlinuz exists and is a regular file ────────────────────────────
  local kernel_path="$boot_dir/vmlinuz-${kernel_version}"
  test_harness_assert_file_exists "$kernel_path" || { rc=1; }

  if [[ -L "$kernel_path" ]]; then
    echo "    ASSERTION FAILED: kernel is a symlink (escape risk): '$kernel_path'" >&2
    test_harness_fail "vmlinuz must not be a symlink"
    rc=1
  fi

  # ── 3. initramfs exists and is a regular file ──────────────────────────
  local initramfs_path="$boot_dir/initramfs-${kernel_version}.img"
  test_harness_assert_file_exists "$initramfs_path" || { rc=1; }

  if [[ -L "$initramfs_path" ]]; then
    echo "    ASSERTION FAILED: initramfs is a symlink (escape risk): '$initramfs_path'" >&2
    test_harness_fail "initramfs must not be a symlink"
    rc=1
  fi

  # ── 4. amd-ucode.img exists and is a regular file ──────────────────────
  local microcode_path="$boot_dir/amd-ucode.img"
  test_harness_assert_file_exists "$microcode_path" || { rc=1; }

  if [[ -L "$microcode_path" ]]; then
    echo "    ASSERTION FAILED: amd-ucode.img is a symlink (escape risk): '$microcode_path'" >&2
    test_harness_fail "amd-ucode.img must not be a symlink"
    rc=1
  fi

  # ── 5. No boot files are symlinks (escape risk) ───────────────────────
  # Scan for any symlinks directly under /boot that should be real files.
  local symlink_count
  symlink_count="$(find "$boot_dir" -maxdepth 1 -type l 2>/dev/null | wc -l)"
  if [[ "$symlink_count" -gt 0 ]]; then
    local symlinks
    symlinks="$(find "$boot_dir" -maxdepth 1 -type l -printf '    %p -> %l\n' 2>/dev/null)"
    echo "    ASSERTION FAILED: $symlink_count symlink(s) found in /boot (escape risk):" >&2
    printf '%s\n' "$symlinks" >&2
    test_harness_fail "/boot contains symlinks (escape risk)"
    rc=1
  fi

  # ── 6. Paths do not resolve outside rootfs (containment check) ────────
  local real_rootfs
  real_rootfs="$(realpath "$rootfs_dir" 2>/dev/null)" || real_rootfs="$rootfs_dir"

  local real_boot
  real_boot="$(realpath "$boot_dir" 2>/dev/null)" || real_boot="$boot_dir"
  if [[ "$real_boot" != "$real_rootfs" && "$real_boot" != "$real_rootfs"/* ]]; then
    echo "    ASSERTION FAILED: /boot resolves outside rootfs: '$real_boot'" >&2
    test_harness_fail "/boot path escapes rootfs boundary"
    rc=1
  fi

  return $rc
}

# ===========================================================================
# validate_partsets EFI_DIR EXPECTED_PARTITIONS [PARTITION_COUNT]
#
# Validate that partset files exist under <EFI_DIR>/SteamOS/partsets/ and
# that each contains valid PARTUUID entries with the expected structure.
#
# Arguments:
#   EFI_DIR            - Path to the mounted EFI partition (required).
#   EXPECTED_PARTITIONS - Comma-separated list of expected partition names
#                         (e.g. "rootfs-A,efi-A,var-A") (required).
#   PARTITION_COUNT     - Number of partitions expected (default: derived from EXPECTED_PARTITIONS).
#
# Partset file format (one entry per line):
#   <role> <PARTUUID>
# where <role> is rootfs|efi|var and <PARTUUID> is a valid UUID format.
#
# Checks performed:
#   1. Each expected partset file exists
#   2. Partset files are not empty
#   3. Each line has exactly two fields: role and PARTUUID
#   4. PARTUUID matches UUID format (8-4-4-4-12 hex)
#   5. Roles are among the valid set (rootfs, efi, var)
#   6. No duplicate PARTUUIDs within a single partset
#
# Returns:
#   0 - all checks passed
#   1 - one or more checks failed (details emitted via harness)
# ===========================================================================
validate_partsets() {
  local efi_dir="${1:?validate_partsets: missing EFI_DIR}"
  local expected_partitions="${2:?validate_partsets: missing EXPECTED_PARTITIONS}"
  local partition_count="${3:-}"

  local partsets_dir="$efi_dir/SteamOS/partsets"
  local rc=0

  # UUID pattern: 8 hex chars, dash, 4 hex chars, dash, 4 hex chars, dash,
  #               4 hex chars, dash, 12 hex chars.
  local uuid_pattern='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  # Valid roles in a partset file
  local valid_roles="rootfs efi var"

  # ── 1. Partsets directory exists ───────────────────────────────────────
  test_harness_assert_dir_exists "$partsets_dir" || {
    rc=1
    return 1
  }

  # Split expected partitions into an array
  local -a expected_parts
  IFS=',' read -ra expected_parts <<<"$expected_partitions"

  for part in "${expected_parts[@]}"; do
    local partset_file="$partsets_dir/$part"

    # ── 2. Partset file exists ──────────────────────────────────────────
    test_harness_assert_file_exists "$partset_file" || {
      rc=1
      continue
    }

    # ── 3. Partset file is not empty ────────────────────────────────────
    if [[ ! -s "$partset_file" ]]; then
      echo "    ASSERTION FAILED: partset file is empty: '$partset_file'" >&2
      test_harness_fail "partset file is empty: $part"
      rc=1
      continue
    fi

    # ── 4-6. Validate each line ─────────────────────────────────────────
    local line_num=0
    local -a seen_uuids=()
    while IFS= read -r line; do
      line_num=$((line_num + 1))

      # Skip comments and blank lines
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -z "${line// /}" ]] && continue

      # Check line has exactly two fields
      local role uuid
      read -r role uuid _extra <<<"$line"
      if [[ -z "$role" || -z "$uuid" || -n "${_extra:-}" ]]; then
        echo "    ASSERTION FAILED: partset $part line $line_num has invalid format (expected 'role PARTUUID'): '$line'" >&2
        test_harness_fail "invalid partset line format in $part"
        rc=1
        continue
      fi

      # Check role is valid
      local valid=0
      for vr in $valid_roles; do
        if [[ "$role" == "$vr" ]]; then
          valid=1
          break
        fi
      done
      if [[ "$valid" -eq 0 ]]; then
        echo "    ASSERTION FAILED: partset $part line $line_num has invalid role: '$role'" >&2
        test_harness_fail "invalid role '$role' in partset $part"
        rc=1
        continue
      fi

      # Check UUID format
      if ! [[ "$uuid" =~ $uuid_pattern ]]; then
        echo "    ASSERTION FAILED: partset $part line $line_num has invalid PARTUUID: '$uuid'" >&2
        test_harness_fail "invalid PARTUUID format in partset $part"
        rc=1
        continue
      fi

      # Check for duplicate UUIDs within this partset
      local dup_found=0
      for seen in "${seen_uuids[@]}"; do
        if [[ "$seen" == "$uuid" ]]; then
          dup_found=1
          break
        fi
      done
      if [[ "$dup_found" -eq 1 ]]; then
        echo "    ASSERTION FAILED: partset $part contains duplicate PARTUUID: '$uuid'" >&2
        test_harness_fail "duplicate PARTUUID in partset $part"
        rc=1
      fi
      seen_uuids+=("$uuid")

    done <"$partset_file"
  done

  return $rc
}

# ===========================================================================
# validate_bootconf CONF_DIR EXPECTED_CONF_FILES [REQUIRED_FIELDS]
#
# Validate that bootconf files exist under CONF_DIR (the SteamOS/conf/
# directory on the ESP partition) and contain the required fields.
#
# Arguments:
#   CONF_DIR          - Path to the SteamOS/conf/ directory on the ESP (required).
#   EXPECTED_CONF_FILES - Comma-separated list of expected conf file names
#                          e.g. "A.conf,B.conf" (required).
#   REQUIRED_FIELDS   - Comma-separated list of required field names
#                        (default: "title,image-invalid,boot-attempts").
#
# Bootconf file format (one key=value pair per line):
#   key=value
# Lines starting with '#' are comments and are ignored.
#
# Checks performed:
#   1. Each expected bootconf file exists
#   2. Bootconf files are not empty
#   3. Each required field is present in the file
#   4. Each field has a non-empty value
#   5. Fields follow key=value format
#
# Returns:
#   0 - all checks passed
#   1 - one or more checks failed (details emitted via harness)
# ===========================================================================
validate_bootconf() {
  local conf_dir="${1:?validate_bootconf: missing CONF_DIR}"
  local expected_conf_files="${2:?validate_bootconf: missing EXPECTED_CONF_FILES}"
  local required_fields="${3:-title,image-invalid,boot-attempts}"

  local rc=0

  # ── 1. Conf directory exists ──────────────────────────────────────────
  test_harness_assert_dir_exists "$conf_dir" || {
    rc=1
    return 1
  }

  # Split expected files and required fields into arrays
  local -a conf_files
  IFS=',' read -ra conf_files <<<"$expected_conf_files"

  local -a required_fields_arr
  IFS=',' read -ra required_fields_arr <<<"$required_fields"

  for conf_file in "${conf_files[@]}"; do
    local conf_path="$conf_dir/$conf_file"

    # ── 2. Bootconf file exists ─────────────────────────────────────────
    test_harness_assert_file_exists "$conf_path" || {
      rc=1
      continue
    }

    # ── 3. Bootconf file is not empty ───────────────────────────────────
    if [[ ! -s "$conf_path" ]]; then
      echo "    ASSERTION FAILED: bootconf file is empty: '$conf_path'" >&2
      test_harness_fail "bootconf file is empty: $conf_file"
      rc=1
      continue
    fi

    # ── 4. Check required fields ────────────────────────────────────────
    local content
    content="$(cat "$conf_path")"

    for field in "${required_fields_arr[@]}"; do
      # Skip empty field names
      [[ -z "$field" ]] && continue

      # Check if field is present as a key=value line (ignoring comments)
      local field_found
      field_found="$(printf '%s\n' "$content" | grep -v '^\s*#' | grep -c "^${field}=" 2>/dev/null)" || field_found=0

      if [[ "$field_found" -eq 0 ]]; then
        echo "    ASSERTION FAILED: bootconf $conf_file missing required field: '$field'" >&2
        test_harness_fail "missing required field '$field' in bootconf $conf_file"
        rc=1
        continue
      fi

      # Verify the field has a non-empty value
      local field_value
      field_value="$(printf '%s\n' "$content" | grep -v '^\s*#' | grep "^${field}=" | head -1 | cut -d= -f2-)"
      if [[ -z "$field_value" ]]; then
        echo "    ASSERTION FAILED: bootconf $conf_file field '$field' has empty value" >&2
        test_harness_fail "empty value for field '$field' in bootconf $conf_file"
        rc=1
      fi
    done
  done

  return $rc
}

# ===========================================================================
# validate_cross_artifact_consistency ROOTFS_DIR EFI_DIR EXPECTED_UUID
#
# Cross-validate that UUIDs and references are consistent across all boot
# artifacts: grub.cfg, grubx64.efi, partsets, and bootconf.
#
# Arguments:
#   ROOTFS_DIR    - Path to the mounted root filesystem (required).
#   EFI_DIR       - Path to the mounted EFI partition (required).
#   EXPECTED_UUID - The rootfs UUID expected across all artifacts (required).
#
# Checks performed:
#   1. grub.cfg search --fs-uuid entries reference EXPECTED_UUID
#   2. grub.cfg linux entries reference paths that exist in rootfs
#   3. grubx64.efi binary contains EXPECTED_UUID (embedded identity)
#   4. partset self file references valid PARTUUIDs
#   5. grub.cfg UUID is consistent with EFI binary UUID
#   6. No UUID mismatch between grub.cfg and embedded binary
#
# Returns:
#   0 - all checks passed
#   1 - one or more checks failed (details emitted via harness)
# ===========================================================================
validate_cross_artifact_consistency() {
  local rootfs_dir="${1:?validate_cross_artifact_consistency: missing ROOTFS_DIR}"
  local efi_dir="${2:?validate_cross_artifact_consistency: missing EFI_DIR}"
  local expected_uuid="${3:?validate_cross_artifact_consistency: missing EXPECTED_UUID}"

  local grub_cfg="$efi_dir/EFI/steamos/grub.cfg"
  local grubx64="$efi_dir/EFI/steamos/grubx64.efi"
  local rc=0

  # UUID pattern
  local uuid_pattern='[0-9a-fA-F]\{8\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{12\}'

  # ── 1. grub.cfg search --fs-uuid entries reference EXPECTED_UUID ──────
  if [[ -f "$grub_cfg" ]]; then
    local expected_count
    expected_count="$(grep -c "search.*--fs-uuid.*--set=root.*${expected_uuid}" "$grub_cfg" 2>/dev/null || echo 0)"
    if [[ "$expected_count" -eq 0 ]]; then
      echo "    ASSERTION FAILED: grub.cfg does not reference expected UUID '$expected_uuid'" >&2
      test_harness_fail "grub.cfg search --fs-uuid does not match expected UUID"
      rc=1
    fi
  fi

  # ── 2. grub.cfg linux entries reference paths that exist in rootfs ────
  if [[ -f "$grub_cfg" ]]; then
    local kernel_path
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -z "${line// /}" ]] && continue
      kernel_path="$(printf '%s' "$line" | sed -n 's/^[[:space:]]*linux[[:space:]]\+\([^[:space:]]*\).*/\1/p')"
      if [[ -n "$kernel_path" ]]; then
        local full_path
        if [[ "$kernel_path" == /* ]]; then
          full_path="$rootfs_dir$kernel_path"
        else
          full_path="$rootfs_dir/$kernel_path"
        fi
        test_harness_assert_file_exists "$full_path" || { rc=1; }
      fi
    done <<<"$(grep -v '^\s*#' "$grub_cfg" | grep '^\s*linux ')"
  fi

  # ── 3. grubx64.efi binary contains EXPECTED_UUID ─────────────────────
  if [[ -f "$grubx64" ]]; then
    local embedded_uuid
    embedded_uuid="$(strings "$grubx64" 2>/dev/null | grep -oE "$uuid_pattern" | head -1)"
    if [[ -z "$embedded_uuid" ]]; then
      echo "    ASSERTION FAILED: grubx64.efi does not contain any UUID" >&2
      test_harness_fail "EFI binary has no embedded UUID for cross-validation"
      rc=1
    elif [[ "$embedded_uuid" != "$expected_uuid" ]]; then
      echo "    ASSERTION FAILED: grubx64.efi UUID '$embedded_uuid' != expected '$expected_uuid'" >&2
      test_harness_fail "EFI binary UUID mismatch: got '$embedded_uuid', expected '$expected_uuid'"
      rc=1
    fi
  fi

  # ── 4. Partset self file references valid PARTUUIDs ───────────────────
  local self_partset="$efi_dir/SteamOS/partsets/self"
  if [[ -f "$self_partset" ]]; then
    local partuuid_pattern='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -z "${line// /}" ]] && continue
      local role uuid
      read -r role uuid _extra <<<"$line"
      if [[ -n "$uuid" ]] && ! [[ "$uuid" =~ $partuuid_pattern ]]; then
        echo "    ASSERTION FAILED: partset self has invalid PARTUUID: '$uuid' for role '$role'" >&2
        test_harness_fail "invalid PARTUUID in self partset"
        rc=1
      fi
    done <"$self_partset"
  fi

  # ── 5. grub.cfg UUID is consistent with EFI binary UUID ───────────────
  if [[ -f "$grub_cfg" && -f "$grubx64" ]]; then
    local grub_uuid
    grub_uuid="$(grep -oP 'search.*--fs-uuid.*--set=root\s+\K[0-9a-fA-F-]+' "$grub_cfg" 2>/dev/null | head -1)"
    local binary_uuid
    binary_uuid="$(strings "$grubx64" 2>/dev/null | grep -oE "$uuid_pattern" | head -1)"

    if [[ -n "$grub_uuid" && -n "$binary_uuid" ]]; then
      if [[ "$grub_uuid" != "$binary_uuid" ]]; then
        echo "    ASSERTION FAILED: grub.cfg UUID '$grub_uuid' != grubx64.efi UUID '$binary_uuid'" >&2
        test_harness_fail "UUID mismatch between grub.cfg and EFI binary"
        rc=1
      fi
    fi
  fi

  # ── 6. No UUID mismatch between grub.cfg and embedded binary ──────────
  # This is covered by checks 1 and 3 above (both must match EXPECTED_UUID
  # which transitively enforces consistency).

  return $rc
}

# ===========================================================================
# validate_transaction_phase EFI_DIR [ESP_DIR]
#
# Check that no stale transaction artifacts remain in the EFI and optional
# ESP partition directories.  Stale transactions indicate a prior
# application was interrupted and may leave the system in an inconsistent
# state.
#
# Arguments:
#   EFI_DIR  - Path to the mounted EFI partition (required).
#   ESP_DIR  - Path to the shared ESP partition (optional).
#
# Stale artifact patterns (matching preflight_path_safety.sh conventions):
#   *.new          - Atomic-replace staging file (left behind on crash)
#   *.bak          - Backup of replaced file
#   *.tmp          - Temporary work file
#   *.transaction-* - Transaction marker files
#
# Excluded from stale detection:
#   .building      - Active build marker (not stale)
#   .build-complete - Completed build marker (not stale)
#
# Checks performed:
#   1. No *.new files in EFI or ESP directories
#   2. No *.bak files in EFI or ESP directories
#   3. No *.tmp files in EFI or ESP directories
#   4. No *.transaction-* files in EFI or ESP directories
#   5. .building marker, if present, is accompanied by active process
#      (presence alone is flagged as a warning)
#
# Returns:
#   0 - no stale transactions found (clean state)
#   1 - stale transaction artifacts detected (details emitted via harness)
# ===========================================================================
validate_transaction_phase() {
  local efi_dir="${1:?validate_transaction_phase: missing EFI_DIR}"
  local esp_dir="${2:-}"

  local rc=0

  # Stale artifact patterns (glob patterns for find -name)
  local stale_patterns=(
    '*.new'
    '*.bak'
    '*.tmp'
    '*.transaction-*'
  )

  # ── Scan function for a single directory ──────────────────────────────
  _validate_no_stale_in_dir() {
    local scan_dir="$1"
    local label="$2"

    if [[ ! -d "$scan_dir" ]]; then
      return 0 # Non-existent dir is not an error
    fi

    local -a found_artifacts=()

    for pattern in "${stale_patterns[@]}"; do
      while IFS= read -r match; do
        [[ -z "$match" ]] && continue
        # Exclude .building and .build-complete markers
        local basename
        basename="$(basename "$match")"
        if [[ "$basename" == ".building" || "$basename" == ".build-complete" ]]; then
          continue
        fi
        found_artifacts+=("$match")
      done < <(find "$scan_dir" -maxdepth 5 -name "$pattern" -type f 2>/dev/null)
    done

    if [[ "${#found_artifacts[@]}" -gt 0 ]]; then
      echo "    ASSERTION FAILED: ${#found_artifacts[@]} stale transaction artifact(s) in $label:" >&2
      printf '      %s\n' "${found_artifacts[@]}" >&2
      test_harness_fail "stale transaction artifacts detected in $label (${#found_artifacts[@]} files)"
      return 1
    fi

    return 0
  }

  # ── 1-4. Scan EFI directory for stale artifacts ───────────────────────
  _validate_no_stale_in_dir "$efi_dir" "EFI" || { rc=1; }

  # ── Scan ESP directory if provided ────────────────────────────────────
  if [[ -n "$esp_dir" ]]; then
    _validate_no_stale_in_dir "$esp_dir" "ESP" || { rc=1; }
  fi

  # ── 5. Check for .building marker (warning only) ─────────────────────
  # The .building marker indicates an active build. Its presence without
  # a running build process suggests a stale state, but we treat it as
  # informational rather than a hard failure — the caller should verify
  # process state separately.
  if [[ -f "$efi_dir/.building" ]]; then
    echo "    WARNING: .building marker found in EFI directory — verify build process is active" >&2
  fi
  if [[ -n "$esp_dir" && -f "$esp_dir/.building" ]]; then
    echo "    WARNING: .building marker found in ESP directory — verify build process is active" >&2
  fi

  return $rc
}
