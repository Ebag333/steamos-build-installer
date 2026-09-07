#!/bin/bash
#
# steamos-build-installer — lib/preflight_rootfs.sh
# Rootfs target validation: ensures the target root filesystem exists,
# is a directory, is mounted, looks like a valid rootfs, and is writable.
# Called by the build pipeline before any modification begins.
#
# Requires: lib/common.sh (die, debug, warn)
# Do not run it directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/preflight_rootfs.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _pf_rfs_canonicalize_rootfs_mount ROOTFS
#   Resolve ROOTFS to an absolute canonical path using `realpath -e`
#   (requires the path to exist).
#   Dies if the input is empty or the result is not an absolute path.
_pf_rfs_canonicalize_rootfs_mount() {
  local rootfs="${1:?_pf_rfs_canonicalize_rootfs_mount: missing rootfs path}"

  local resolved
  resolved="$(realpath -e "$rootfs" 2>/dev/null)" \
    || die "_pf_rfs_canonicalize_rootfs_mount: failed to canonicalize '$rootfs'"

  [[ -n "$resolved" ]] \
    || die "_pf_rfs_canonicalize_rootfs_mount: canonical path is empty for '$rootfs'"

  [[ "$resolved" == /* ]] \
    || die "_pf_rfs_canonicalize_rootfs_mount: canonical path is not absolute: '$resolved'"

  echo "$resolved"
}

# _pf_rfs_get_fstype ROOTFS
#   Get the filesystem type for ROOTFS via `findmnt -nro FSTYPE -M`.
#   Uses exact mountpoint query for precision.
#   Prints the fstype string (e.g. "btrfs", "ext4") or empty on failure.
_pf_rfs_get_fstype() {
  local rootfs="${1:?_pf_rfs_get_fstype: missing rootfs path}"
  findmnt -nro FSTYPE -M "$rootfs" 2>/dev/null || true
}

# _pf_rfs_resolve_identity ROOTFS
#   Resolves the complete rootfs identity in one shot.
#   Sets global variables (caller must check for empty values):
#     _PF_RFS_ID_MOUNTPOINT   - canonical mountpoint
#     _PF_RFS_ID_SOURCE       - mount source device (clean, no subvol suffix)
#     _PF_RFS_ID_MM           - major:minor of the block device
#     _PF_RFS_ID_FSTYPE       - filesystem type
#     _PF_RFS_ID_MOUNT_OPTS   - mount options
#     _PF_RFS_ID_UUID         - filesystem UUID
#     _PF_RFS_ID_PARTUUID     - partition UUID
#   Dies on any resolution failure.
_pf_rfs_resolve_identity() {
  local rootfs="${1:?_pf_rfs_resolve_identity: missing rootfs path}"

  # Canonicalize mountpoint
  local canonical
  canonical="$(_pf_rfs_canonicalize_rootfs_mount "$rootfs" 2>/dev/null)" || true
  if [[ -z "$canonical" ]]; then
    die "_pf_rfs_resolve_identity: cannot canonicalize rootfs mount: $rootfs"
  fi
  _PF_RFS_ID_MOUNTPOINT="$canonical"

  # Get mount source via findmnt (exact mountpoint query)
  local source
  source="$(findmnt -nro SOURCE -M "$canonical" 2>/dev/null)" || source=""
  if [[ -z "$source" ]]; then
    die "_pf_rfs_resolve_identity: cannot determine mount source for $canonical"
  fi

  # Strip Btrfs subvolume suffix: /dev/device[/subvolume] → /dev/device
  source="${source%%[*}"
  _PF_RFS_ID_SOURCE="$source"

  # Get major:minor
  local mm
  mm="$(findmnt -nro MAJ:MIN -M "$canonical" 2>/dev/null)" || mm=""
  if [[ -z "$mm" ]]; then
    die "_pf_rfs_resolve_identity: cannot determine MAJ:MIN for $canonical"
  fi
  _PF_RFS_ID_MM="$mm"

  # Get filesystem type
  local fstype
  fstype="$(findmnt -nro FSTYPE -M "$canonical" 2>/dev/null)" || fstype=""
  if [[ -z "$fstype" ]]; then
    die "_pf_rfs_resolve_identity: cannot determine FSTYPE for $canonical"
  fi
  _PF_RFS_ID_FSTYPE="$fstype"

  # Get mount options
  local opts
  opts="$(findmnt -nro OPTIONS -M "$canonical" 2>/dev/null)" || opts=""
  _PF_RFS_ID_MOUNT_OPTS="$opts"

  # Get UUID
  local uuid
  uuid="$(blkid -s UUID -o value "$source" 2>/dev/null)" || uuid=""
  _PF_RFS_ID_UUID="$uuid"

  # Get PARTUUID
  local partuuid
  partuuid="$(blkid -s PARTUUID -o value "$source" 2>/dev/null)" || partuuid=""
  _PF_RFS_ID_PARTUUID="$partuuid"

  debug "_pf_rfs_resolve_identity: mount=$canonical source=$source mm=$mm fstype=$fstype uuid=${uuid:-<none>} partuuid=${partuuid:-<none>}"
}

# _pf_rfs_resolve_uuid SOURCE_DEVICE
#   Resolves UUID from a block device. Uses the identity snapshot if available.
#   Returns UUID via stdout. Returns 1 on failure.
_pf_rfs_resolve_uuid() {
  local device="${1:?_pf_rfs_resolve_uuid: missing device}"
  local uuid
  uuid="$(blkid -s UUID -o value "$device" 2>/dev/null)" || uuid=""
  if [[ -z "$uuid" ]]; then
    return 1
  fi
  echo "$uuid"
}

# _pf_rfs_uuid_is_valid UUID
#   Validate UUID format: 8-4-4-4-12 hex characters (standard UUID).
#   Returns 0 if valid, 1 otherwise.
_pf_rfs_uuid_is_valid() {
  local uuid="${1:?_pf_rfs_uuid_is_valid: missing uuid}"
  [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# _pf_rfs_contained_path ROOTFS SUBPATH
#   Returns the canonicalized path of ROOTFS/SUBPATH, verifying it resolves
#   within the canonical rootfs mount. Dies if the path escapes.
#   For write operations, use _pf_rfs_write_contained_path instead.
_pf_rfs_contained_path() {
  local rootfs="${1:?_pf_rfs_contained_path: missing rootfs}"
  local subpath="${2:?_pf_rfs_contained_path: missing subpath}"

  local target="${rootfs}${subpath}"
  local resolved
  resolved="$(realpath -e "$target" 2>/dev/null)" || resolved=""

  if [[ -z "$resolved" ]]; then
    die "_pf_rfs_contained_path: cannot resolve $target"
  fi

  # Ensure the resolved path is under the canonical rootfs
  if [[ "$resolved" != "${rootfs}"/* ]]; then
    die "_pf_rfs_contained_path: path escapes chroot — $subpath resolves to $resolved (outside $rootfs)"
  fi

  echo "$resolved"
}

# _pf_rfs_write_contained_path ROOTFS SUBPATH
#   Returns a path suitable for writing under ROOTFS/SUBPATH.
#   Verifies that the parent directory exists and resolves within the rootfs.
#   Dies if the parent escapes.
_pf_rfs_write_contained_path() {
  local rootfs="${1:?_pf_rfs_write_contained_path: missing rootfs}"
  local subpath="${2:?_pf_rfs_write_contained_path: missing subpath}"

  local target="${rootfs}${subpath}"
  local parent
  parent="$(dirname "$target")"

  # Ensure parent directory exists and is contained
  local resolved_parent
  resolved_parent="$(realpath -e "$parent" 2>/dev/null)" || resolved_parent=""

  if [[ -z "$resolved_parent" ]]; then
    die "_pf_rfs_write_contained_path: parent directory does not exist: $parent"
  fi

  if [[ "$resolved_parent" != "${rootfs}"/* ]]; then
    die "_pf_rfs_write_contained_path: parent escapes chroot — $parent resolves to $resolved_parent (outside $rootfs)"
  fi

  echo "${resolved_parent}/$(basename "$target")"
}

# ---------------------------------------------------------------------------
# Preflight checks — independently callable
# ---------------------------------------------------------------------------

# _preflight_rootfs_device_identity ROOTFS EXPECTED_DEVICE EXPECTED_PARTUUID
#   Verify the rootfs mount is backed by the expected block device and partition.
#   Compares major:minor between the mount and expected device, then verifies PARTUUID.
#   Dies on any mismatch.
_preflight_rootfs_device_identity() {
  local rootfs="${1:?_preflight_rootfs_device_identity: missing rootfs path}"
  local expected_device="${2:?_preflight_rootfs_device_identity: missing expected device}"
  local expected_partuuid="${3:?_preflight_rootfs_device_identity: missing expected PARTUUID}"

  # Resolve identity (uses shared snapshot if already called, otherwise fresh)
  _pf_rfs_resolve_identity "$rootfs"

  # Canonicalize expected device
  local canonical_device
  canonical_device="$(realpath -e "$expected_device" 2>/dev/null)" || true
  if [[ -z "$canonical_device" ]]; then
    die "PF-DEV: cannot canonicalize expected device: $expected_device"
  fi

  # Get expected device MAJ:MIN
  if [[ ! -b "$canonical_device" ]]; then
    die "PF-DEV: expected device is not a block device: $canonical_device"
  fi
  local expected_mm
  expected_mm="$(stat -c '%t:%T' "$canonical_device" 2>/dev/null)" || true
  if [[ -n "$expected_mm" ]]; then
    local major_hex="${expected_mm%%:*}" minor_hex="${expected_mm##*:}"
    expected_mm="$((16#${major_hex})):$((16#${minor_hex}))"
  fi
  if [[ -z "$expected_mm" ]]; then
    die "PF-DEV: cannot determine MAJ:MIN for expected device $canonical_device"
  fi

  # Compare MAJ:MIN
  if [[ "$_PF_RFS_ID_MM" != "$expected_mm" ]]; then
    die "PF-DEV: rootfs device mismatch — mounted at $_PF_RFS_ID_MM, expected $canonical_device ($expected_mm)"
  fi

  # Compare PARTUUID (case-insensitive)
  if [[ "${_PF_RFS_ID_PARTUUID,,}" != "${expected_partuuid,,}" ]]; then
    die "PF-DEV: rootfs PARTUUID mismatch — device reports ${_PF_RFS_ID_PARTUUID:-<none>}, expected $expected_partuuid"
  fi

  debug "PF-DEV: rootfs device identity OK — $_PF_RFS_ID_SOURCE ($_PF_RFS_ID_MM) PARTUUID=$_PF_RFS_ID_PARTUUID"
}

# _preflight_rootfs_exists ROOTFS
#   PF-01: Verify the target root path exists.
_preflight_rootfs_exists() {
  local rootfs="${1:?_preflight_rootfs_exists: missing rootfs path}"

  if [[ ! -e "$rootfs" ]]; then
    die "PF-01: target root not found: $rootfs"
  fi

  debug "PF-01: rootfs exists: $rootfs"
}

# _preflight_rootfs_is_directory ROOTFS
#   PF-02: Verify the target root is a directory.
_preflight_rootfs_is_directory() {
  local rootfs="${1:?_preflight_rootfs_is_directory: missing rootfs path}"

  if [[ ! -d "$rootfs" ]]; then
    die "PF-02: target root is not a directory: $rootfs"
  fi

  debug "PF-02: rootfs is a directory: $rootfs"
}

# _preflight_rootfs_is_mounted ROOTFS
#   PF-03: Verify the target root is a mountpoint.
_preflight_rootfs_is_mounted() {
  local rootfs="${1:?_preflight_rootfs_is_mounted: missing rootfs path}"

  if ! mountpoint -q "$rootfs" 2>/dev/null; then
    die "PF-03: target root is not mounted: $rootfs"
  fi

  debug "PF-03: rootfs is mounted: $rootfs"
}

# _preflight_rootfs_os_release ROOTFS
#   PF-04: Verify the rootfs contains a valid os-release file.
#   Checks $rootfs/etc/os-release first, then $rootfs/usr/lib/os-release.
#   Verifies the file is regular, non-empty, and contains expected fields.
#   Parses safely via grep (no sourcing as shell code).
_preflight_rootfs_os_release() {
  local rootfs="${1:?_preflight_rootfs_os_release: missing rootfs path}"

  # Check for os-release in standard locations (contained paths)
  local os_release=""
  for candidate in "/etc/os-release" "/usr/lib/os-release"; do
    local resolved
    resolved="$(_pf_rfs_contained_path "$rootfs" "$candidate" 2>/dev/null)" || continue
    if [[ -f "$resolved" && -s "$resolved" ]]; then
      os_release="$resolved"
      break
    fi
  done

  if [[ -z "$os_release" ]]; then
    die "PF-04: no valid os-release found in $rootfs"
  fi

  # Verify it's not a symlink pointing outside rootfs (already handled by _pf_rfs_contained_path)

  # Parse expected keys safely (grep-based, no sourcing)
  local has_id=false
  local has_name=false

  if grep -q '^ID=' "$os_release" 2>/dev/null; then
    has_id=true
  fi
  if grep -q '^PRETTY_NAME=' "$os_release" 2>/dev/null; then
    has_name=true
  fi

  if [[ "$has_id" != "true" || "$has_name" != "true" ]]; then
    die "PF-04: os-release is missing required fields (ID=$has_id, PRETTY_NAME=$has_name): $os_release"
  fi

  debug "PF-04: os-release validation passed: $os_release"
}

# _preflight_rootfs_writable ROOTFS
#   PF-05: Verify the rootfs is writable.
#   Phase 1: Check mount options via findmnt for 'ro' (read-only).
#   Phase 2: Real write test by creating and immediately removing a temp file
#   under $rootfs/etc. No trap is used — individual preflight modules must not
#   replace global traps.
#   IMPORTANT: This function performs a real write to the rootfs. It must be called
#   AFTER all identity validation checks (device identity, UUID, filesystem type)
#   have passed. The orchestrator is responsible for correct call ordering.
_preflight_rootfs_writable() {
  local rootfs="${1:?_preflight_rootfs_writable: missing rootfs path}"

  # Phase 1: Check mount options for read-only flag
  local mount_opts
  mount_opts="$(findmnt -rn -o OPTIONS "$rootfs" 2>/dev/null)" || mount_opts=""

  if [[ -n "$mount_opts" ]]; then
    # Match 'ro' as a standalone comma-separated mount option (not a substring
    # like 'rootfs' or 'proc').  The regex anchors to word boundaries implied
    # by comma separation or start/end of string.
    if [[ ",$mount_opts," =~ ,ro, || "$mount_opts" == ro || "$mount_opts" =~ ^ro, || "$mount_opts" =~ ,ro$ ]]; then
      die "PF-05: rootfs is not writable (mounted read-only): $rootfs"
    fi
  fi

  # Phase 2: Real write test — create temp file, remove it immediately.
  # No trap — individual preflight modules must not replace global traps.
  local contained_dir
  contained_dir="$(_pf_rfs_write_contained_path "$rootfs" "/etc/.preflight-writable-XXXXXX" 2>/dev/null)" \
    || die "PF-05: rootfs is not writable (cannot resolve write path in $rootfs/etc): $rootfs"

  local test_file
  test_file="$(mktemp "${contained_dir}" 2>/dev/null)" \
    || die "PF-05: rootfs is not writable (cannot create file in $rootfs/etc): $rootfs"

  rm -f "$test_file" 2>/dev/null \
    || die "PF-05: rootfs is not writable (cannot remove test file): $rootfs"

  debug "PF-05: rootfs is writable: $rootfs"
}

# _preflight_rootfs_is_btrfs ROOTFS
#   PF-45: Verify the root filesystem is Btrfs.
_preflight_rootfs_is_btrfs() {
  local rootfs="${1:?_preflight_rootfs_is_btrfs: missing rootfs path}"

  local fstype
  fstype="$(_pf_rfs_get_fstype "$rootfs" 2>/dev/null)" || true
  if [[ -z "$fstype" ]]; then
    die "PF-45: could not determine filesystem type for: $rootfs"
  fi

  if [[ "$fstype" != "btrfs" ]]; then
    die "PF-45: rootfs is not Btrfs (found $fstype): $rootfs"
  fi

  debug "PF-45: rootfs is Btrfs: $rootfs"
}

# _preflight_rootfs_uuid_available ROOTFS
#   PF-46: Verify the rootfs UUID is resolvable via findmnt + blkid.
_preflight_rootfs_uuid_available() {
  local rootfs="${1:?_preflight_rootfs_uuid_available: missing rootfs path}"

  # Resolve the mount source device, stripping any Btrfs subvolume suffix
  local source
  source="$(findmnt -nro SOURCE -M "$rootfs" 2>/dev/null)" || source=""
  source="${source%%[*}"

  local uuid
  if [[ -n "$source" ]]; then
    uuid="$(_pf_rfs_resolve_uuid "$source" 2>/dev/null)" || true
  fi
  if [[ -z "$uuid" ]]; then
    die "PF-46: could not resolve UUID for rootfs: $rootfs"
  fi

  if ! _pf_rfs_uuid_is_valid "$uuid"; then
    die "PF-46: resolved UUID has invalid format '$uuid' for: $rootfs"
  fi

  debug "PF-46: rootfs UUID is resolvable: $uuid ($rootfs)"
}

# _preflight_rootfs_uuid_unique ROOTFS SOURCE_UUID
#   PF-47: Verify the rootfs UUID has been changed from the source and is globally unique.
#   SOURCE_UUID is required — if missing, this is a fatal error (the caller must
#   have captured it before mutation).
#   BREAKING CHANGE: SOURCE_UUID is now mandatory (was optional). Callers that
#   previously relied on the warn-only fallback must now always supply it.
_preflight_rootfs_uuid_unique() {
  local rootfs="${1:?_preflight_rootfs_uuid_unique: missing rootfs path}"
  local source_uuid="${2:?_preflight_rootfs_uuid_unique: missing source UUID (must be captured before mutation)}"

  # Validate source UUID format
  if ! _pf_rfs_uuid_is_valid "$source_uuid" 2>/dev/null; then
    die "PF-47: source UUID format is invalid: $source_uuid"
  fi

  # Resolve identity
  _pf_rfs_resolve_identity "$rootfs"

  if [[ -z "$_PF_RFS_ID_UUID" ]]; then
    die "PF-47: cannot determine current UUID for rootfs at $rootfs"
  fi

  # Verify UUID is valid format
  if [[ ! "$_PF_RFS_ID_UUID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    die "PF-47: rootfs UUID has invalid format: ${_PF_RFS_ID_UUID}"
  fi

  # Verify target differs from source
  if [[ "${_PF_RFS_ID_UUID,,}" == "${source_uuid,,}" ]]; then
    die "PF-47: rootfs UUID has not been changed — still matches source UUID: $_PF_RFS_ID_UUID"
  fi

  # Verify UUID is unique among visible Btrfs devices
  local duplicate_count=0
  local dev
  for dev in /dev/sd* /dev/nvme* /dev/mapper/*; do
    [[ -b "$dev" ]] || continue
    local dev_uuid
    dev_uuid="$(blkid -s UUID -o value "$dev" 2>/dev/null)" || continue
    [[ -z "$dev_uuid" ]] && continue
    local dev_fstype
    dev_fstype="$(blkid -s TYPE -o value "$dev" 2>/dev/null)" || continue
    [[ "$dev_fstype" != "btrfs" ]] && continue
    [[ "$dev" == "$_PF_RFS_ID_SOURCE" ]] && continue
    if [[ "${dev_uuid,,}" == "${_PF_RFS_ID_UUID,,}" ]]; then
      duplicate_count=$((duplicate_count + 1))
      debug "PF-47: duplicate UUID found on $dev"
    fi
  done

  if [[ "$duplicate_count" -gt 0 ]]; then
    die "PF-47: rootfs UUID $_PF_RFS_ID_UUID is not unique — found on $duplicate_count other Btrfs device(s)"
  fi

  debug "PF-47: rootfs UUID $_PF_RFS_ID_UUID is unique and differs from source $source_uuid"
}

# _preflight_rootfs_uuid_finalized ROOTFS PRE_MUTATION_UUID [EXPECTED_PARTUUID] [EXPECTED_DEVICE_MM]
#   PF-48: Verify the rootfs UUID has changed from the pre-mutation value.
#   This enforces that btrfstune -u completed successfully before we
#   proceed to boot generation.
#   Optional parameters:
#     EXPECTED_PARTUUID  - if provided, the PARTUUID must match (case-insensitive)
#     EXPECTED_DEVICE_MM - if provided, the device MAJ:MIN must match exactly
_preflight_rootfs_uuid_finalized() {
  local rootfs="${1:?_preflight_rootfs_uuid_finalized: missing rootfs path}"
  local pre_mutation_uuid="${2:?_preflight_rootfs_uuid_finalized: missing pre_mutation_uuid}"
  local expected_partuuid="${3:-}"
  local expected_device_mm="${4:-}"

  # Resolve the mount source device, stripping any Btrfs subvolume suffix
  local source
  source="$(findmnt -nro SOURCE -M "$rootfs" 2>/dev/null)" || source=""
  source="${source%%[*}"

  local uuid
  if [[ -n "$source" ]]; then
    uuid="$(_pf_rfs_resolve_uuid "$source" 2>/dev/null)" || true
  fi

  if [[ -z "$uuid" ]]; then
    die "PF-48: could not resolve UUID for rootfs: $rootfs"
  fi

  if [[ -z "$pre_mutation_uuid" ]]; then
    die "PF-48: PRE_MUTATION_UUID is empty — cannot verify UUID was finalized: $rootfs"
  fi

  # Case-insensitive UUID comparison
  local uuid_lower="${uuid,,}"
  local pre_mutation_uuid_lower="${pre_mutation_uuid,,}"
  if [[ "$uuid_lower" == "$pre_mutation_uuid_lower" ]]; then
    die "PF-48: rootfs UUID ($uuid) has not changed from pre-mutation value ($pre_mutation_uuid) — btrfstune -u must complete before boot generation: $rootfs"
  fi

  # Verify PARTUUID matches expected (if provided)
  if [[ -n "$expected_partuuid" ]]; then
    local actual_partuuid
    actual_partuuid="$(blkid -s PARTUUID -o value "$source" 2>/dev/null)" || actual_partuuid=""
    if [[ -n "$actual_partuuid" ]] && [[ "${actual_partuuid,,}" != "${expected_partuuid,,}" ]]; then
      die "PF-48: PARTUUID mismatch — device reports ${actual_partuuid:-<none>}, expected $expected_partuuid"
    fi
  fi

  # Verify device identity matches expected (if provided)
  if [[ -n "$expected_device_mm" ]]; then
    local actual_mm
    actual_mm="$(findmnt -nro MAJ:MIN -M "$rootfs" 2>/dev/null)" || actual_mm=""
    if [[ -n "$actual_mm" ]] && [[ "$actual_mm" != "$expected_device_mm" ]]; then
      die "PF-48: device MAJ:MIN mismatch — device reports $actual_mm, expected $expected_device_mm"
    fi
  fi

  debug "PF-48: rootfs UUID finalized: $pre_mutation_uuid -> $uuid ($rootfs)"
}

# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

# preflight_rootfs_validate ROOTFS [SOURCE_UUID] [EXPECTED_DEVICE] [EXPECTED_PARTUUID] [SKIP_WRITABLE]
#   Master preflight for rootfs validation.
#
#   Parameters:
#     ROOTFS           - required, path to the mounted rootfs
#     SOURCE_UUID      - required for Flashless/UUID mutation scenarios (pre-mutation UUID)
#     EXPECTED_DEVICE  - required for slot-specific validation (expected block device)
#     EXPECTED_PARTUUID - required for partition identity validation
#     SKIP_WRITABLE    - "true" to skip write probe (e.g., Flashless ro=true initial state)
#
#   Validation order (safety-critical):
#     1. Rootfs is a Btrfs filesystem
#     2. Device identity matches expected (if provided)
#     3. UUID is available and valid
#     4. UUID has been mutated from source (if SOURCE_UUID provided)
#     5. UUID is globally unique (if SOURCE_UUID provided)
#     6. UUID mutation finalized (if SOURCE_UUID provided)
#     7. os-release validation
#     8. Writable probe (LAST — after all identity checks pass)
#
#   Backward-compatible: preflight_rootfs_validate ROOTFS still works.
#   All parameters after ROOTFS are optional with defaults.
preflight_rootfs_validate() {
  local rootfs="${1:?preflight_rootfs_validate: missing rootfs path}"
  local source_uuid="${2:-}"
  local expected_device="${3:-}"
  local expected_partuuid="${4:-}"
  local skip_writable="${5:-false}"

  debug "preflight_rootfs_validate: root=$rootfs source_uuid=${source_uuid:-<none>} device=${expected_device:-<none>} partuuid=${expected_partuuid:-<none>} skip_writable=$skip_writable"

  # 0. Basic existence checks — must pass before any other validation
  _preflight_rootfs_exists "$rootfs"
  _preflight_rootfs_is_directory "$rootfs"
  _preflight_rootfs_is_mounted "$rootfs"

  # Resolve identity once (shared snapshot for all checks)
  _pf_rfs_resolve_identity "$rootfs"

  # 1. Btrfs filesystem check
  _preflight_rootfs_is_btrfs "$rootfs"

  # 2. Device identity (if expected device provided)
  if [[ -n "$expected_device" && -n "$expected_partuuid" ]]; then
    _preflight_rootfs_device_identity "$rootfs" "$expected_device" "$expected_partuuid"
  fi

  # 3. UUID available
  _preflight_rootfs_uuid_available "$rootfs"

  # 4. UUID mutation (if source UUID provided)
  if [[ -n "$source_uuid" ]]; then
    _preflight_rootfs_uuid_unique "$rootfs" "$source_uuid"
  fi

  # 5. UUID finalized (if source UUID provided)
  if [[ -n "$source_uuid" ]]; then
    _preflight_rootfs_uuid_finalized "$rootfs" "$source_uuid"
  fi

  # 6. os-release validation
  _preflight_rootfs_os_release "$rootfs"

  # 7. Writable probe (LAST — only if not skipped)
  if [[ "$skip_writable" != "true" ]]; then
    _preflight_rootfs_writable "$rootfs"
  else
    debug "preflight_rootfs_validate: write probe skipped (skip_writable=true)"
  fi

  debug "preflight_rootfs_validate: all rootfs checks passed"
}
