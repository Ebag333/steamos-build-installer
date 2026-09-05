#!/bin/bash
#
# steamos-build-installer — lib/preflight_rootfs.sh
# Rootfs target validation: ensures the target root filesystem exists,
# is a directory, is mounted, looks like a valid rootfs, and is writable.
# Called by the build pipeline before any modification begins.
#
# Requires: lib/common.sh (die, debug)
# Do not run it directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/preflight_rootfs.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _canonicalize_rootfs_mount ROOTFS
#   Resolve ROOTFS to an absolute canonical path using `realpath -m`
#   (tolerant: does not require the path to exist).
#   Dies if the input is empty or the result is not an absolute path.
_canonicalize_rootfs_mount() {
  local rootfs="${1:?_canonicalize_rootfs_mount: missing rootfs path}"

  local resolved
  resolved="$(realpath -m "$rootfs" 2>/dev/null)" \
    || die "_canonicalize_rootfs_mount: failed to canonicalize '$rootfs'"

  [[ -n "$resolved" ]] \
    || die "_canonicalize_rootfs_mount: canonical path is empty for '$rootfs'"

  [[ "$resolved" == /* ]] \
    || die "_canonicalize_rootfs_mount: canonical path is not absolute: '$resolved'"

  echo "$resolved"
}

# _pf_rfs_get_fstype ROOTFS
#   Get the filesystem type for ROOTFS via `findmnt -n -o FSTYPE`.
#   Prints the fstype string (e.g. "btrfs", "ext4") or empty on failure.
_pf_rfs_get_fstype() {
  local rootfs="${1:?_pf_rfs_get_fstype: missing rootfs path}"
  findmnt -n -o FSTYPE "$rootfs" 2>/dev/null || true
}

# _pf_rfs_resolve_uuid ROOTFS
#   Resolve the Btrfs UUID for ROOTFS using `findmnt` (to get the block
#   device) followed by `blkid` (to get the UUID).
#   Prints the UUID string or empty on failure.
_pf_rfs_resolve_uuid() {
  local rootfs="${1:?_pf_rfs_resolve_uuid: missing rootfs path}"

  local device
  device="$(findmnt -n -o SOURCE "$rootfs" 2>/dev/null)" || device=""
  [[ -n "$device" ]] || return 1

  local uuid
  uuid="$(blkid -s UUID -o value "$device" 2>/dev/null)" || uuid=""
  echo "$uuid"
}

# _pf_rfs_uuid_is_valid UUID
#   Validate UUID format: 8-4-4-4-12 hex characters (standard UUID).
#   Returns 0 if valid, 1 otherwise.
_pf_rfs_uuid_is_valid() {
  local uuid="${1:?_pf_rfs_uuid_is_valid: missing uuid}"
  [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# ---------------------------------------------------------------------------
# Preflight checks — independently callable
# ---------------------------------------------------------------------------

# preflight_rootfs_exists ROOTFS
#   PF-01: Verify the target root path exists.
preflight_rootfs_exists() {
  local rootfs="${1:?preflight_rootfs_exists: missing rootfs path}"

  if [[ ! -e "$rootfs" ]]; then
    die "PF-01: target root not found: $rootfs"
  fi

  debug "PF-01: rootfs exists: $rootfs"
}

# preflight_rootfs_is_directory ROOTFS
#   PF-02: Verify the target root is a directory.
preflight_rootfs_is_directory() {
  local rootfs="${1:?preflight_rootfs_is_directory: missing rootfs path}"

  if [[ ! -d "$rootfs" ]]; then
    die "PF-02: target root is not a directory: $rootfs"
  fi

  debug "PF-02: rootfs is a directory: $rootfs"
}

# preflight_rootfs_is_mounted ROOTFS
#   PF-03: Verify the target root is a mountpoint.
preflight_rootfs_is_mounted() {
  local rootfs="${1:?preflight_rootfs_is_mounted: missing rootfs path}"

  if ! mountpoint -q "$rootfs" 2>/dev/null; then
    die "PF-03: target root is not mounted: $rootfs"
  fi

  debug "PF-03: rootfs is mounted: $rootfs"
}

# preflight_rootfs_os_release ROOTFS
#   PF-04: Verify the rootfs contains a valid os-release file.
#   Checks $rootfs/etc/os-release first, then $rootfs/usr/lib/os-release.
#   Uses [[ -r ... ]] which follows symlinks.
preflight_rootfs_os_release() {
  local rootfs="${1:?preflight_rootfs_os_release: missing rootfs path}"

  local os_release=""

  if [[ -r "$rootfs/etc/os-release" ]]; then
    os_release="$rootfs/etc/os-release"
  elif [[ -r "$rootfs/usr/lib/os-release" ]]; then
    os_release="$rootfs/usr/lib/os-release"
  fi

  if [[ -z "$os_release" ]]; then
    die "PF-04: rootfs does not look like a rootfs (no os-release found): $rootfs"
  fi

  debug "PF-04: rootfs has os-release: $os_release"
}

# preflight_rootfs_writable ROOTFS
#   PF-05: Verify the rootfs is writable.
#   Phase 1: Check mount options via findmnt for 'ro' (read-only).
#   Phase 2: Real write test by touching a temporary file under $rootfs/etc.
#   A cleanup trap ensures the test file is removed.
preflight_rootfs_writable() {
  local rootfs="${1:?preflight_rootfs_writable: missing rootfs path}"

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

  # Phase 2: Real write test — touch a file under $rootfs/etc
  local test_file
  test_file="$(mktemp "$rootfs/etc/.preflight-writable-XXXXXX" 2>/dev/null)" \
    || die "PF-05: rootfs is not writable (cannot create file in $rootfs/etc): $rootfs"

  # Ensure cleanup of the test file
  trap 'rm -f "$test_file" 2>/dev/null' RETURN

  rm -f "$test_file" 2>/dev/null \
    || die "PF-05: rootfs is not writable (cannot remove test file): $rootfs"

  debug "PF-05: rootfs is writable: $rootfs"
}

# preflight_rootfs_is_btrfs ROOTFS
#   PF-45: Verify the root filesystem is Btrfs.
preflight_rootfs_is_btrfs() {
  local rootfs="${1:?preflight_rootfs_is_btrfs: missing rootfs path}"

  local fstype
  fstype="$(_pf_rfs_get_fstype "$rootfs")"

  if [[ -z "$fstype" ]]; then
    die "PF-45: could not determine filesystem type for: $rootfs"
  fi

  if [[ "$fstype" != "btrfs" ]]; then
    die "PF-45: rootfs is not Btrfs (found $fstype): $rootfs"
  fi

  debug "PF-45: rootfs is Btrfs: $rootfs"
}

# preflight_rootfs_uuid_available ROOTFS
#   PF-46: Verify the rootfs UUID is resolvable via findmnt + blkid.
preflight_rootfs_uuid_available() {
  local rootfs="${1:?preflight_rootfs_uuid_available: missing rootfs path}"

  local uuid
  uuid="$(_pf_rfs_resolve_uuid "$rootfs")"

  if [[ -z "$uuid" ]]; then
    die "PF-46: could not resolve UUID for rootfs: $rootfs"
  fi

  if ! _pf_rfs_uuid_is_valid "$uuid"; then
    die "PF-46: resolved UUID has invalid format '$uuid' for: $rootfs"
  fi

  debug "PF-46: rootfs UUID is resolvable: $uuid ($rootfs)"
}

# preflight_rootfs_uuid_unique ROOTFS [SOURCE_UUID]
#   PF-47: Verify the rootfs UUID does not duplicate the source image UUID.
#   When SOURCE_UUID is not provided, this check is warn-only (not fatal).
preflight_rootfs_uuid_unique() {
  local rootfs="${1:?preflight_rootfs_uuid_unique: missing rootfs path}"
  local source_uuid="${2:-}"

  local uuid
  uuid="$(_pf_rfs_resolve_uuid "$rootfs")"

  if [[ -z "$uuid" ]]; then
    # If UUID could not be resolved, that is caught by PF-46.
    # Here we just skip the uniqueness check gracefully.
    debug "PF-47: UUID not resolved — skipping uniqueness check: $rootfs"
    return 0
  fi

  if [[ -z "$source_uuid" ]]; then
    warn "PF-47: SOURCE_UUID not provided — cannot verify uniqueness for: $rootfs (uuid=$uuid)"
    return 0
  fi

  if [[ "$uuid" == "$source_uuid" ]]; then
    die "PF-47: rootfs UUID ($uuid) is identical to source UUID ($source_uuid) — btrfstune -u must complete before boot generation: $rootfs"
  fi

  debug "PF-47: rootfs UUID ($uuid) is unique (source=$source_uuid): $rootfs"
}

# preflight_rootfs_uuid_finalized ROOTFS PRE_MUTATION_UUID
#   PF-48: Verify the rootfs UUID has changed from the pre-mutation value.
#   This enforces that btrfstune -u completed successfully before we
#   proceed to boot generation.
preflight_rootfs_uuid_finalized() {
  local rootfs="${1:?preflight_rootfs_uuid_finalized: missing rootfs path}"
  local pre_mutation_uuid="${2:?preflight_rootfs_uuid_finalized: missing pre_mutation_uuid}"

  local uuid
  uuid="$(_pf_rfs_resolve_uuid "$rootfs")"

  if [[ -z "$uuid" ]]; then
    die "PF-48: could not resolve UUID for rootfs: $rootfs"
  fi

  if [[ -z "$pre_mutation_uuid" ]]; then
    die "PF-48: PRE_MUTATION_UUID is empty — cannot verify UUID was finalized: $rootfs"
  fi

  if [[ "$uuid" == "$pre_mutation_uuid" ]]; then
    die "PF-48: rootfs UUID ($uuid) has not changed from pre-mutation value ($pre_mutation_uuid) — btrfstune -u must complete before boot generation: $rootfs"
  fi

  debug "PF-48: rootfs UUID finalized: $pre_mutation_uuid -> $uuid ($rootfs)"
}

# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

# preflight_rootfs_validate ROOTFS [PRE_MUTATION_UUID] [SOURCE_UUID]
#   Run all rootfs preflight checks in sequence.
#   Uses `realpath -m` for tolerant canonicalization before validation.
#   Dies on the first failure.
#   PRE_MUTATION_UUID: If provided, PF-48 verifies the UUID has changed from this value.
#   SOURCE_UUID:       If provided, PF-47 verifies the UUID does not duplicate it.
#   Backward-compatible: preflight_rootfs_validate ROOTFS still works.
preflight_rootfs_validate() {
  local rootfs="${1:?preflight_rootfs_validate: missing rootfs path}"
  local pre_mutation_uuid="${2:-}"
  local source_uuid="${3:-}"

  # Canonicalize the path first
  rootfs="$(_canonicalize_rootfs_mount "$rootfs")"

  debug "preflight_rootfs_validate: validating $rootfs"

  preflight_rootfs_exists "$rootfs"
  preflight_rootfs_is_directory "$rootfs"
  preflight_rootfs_is_mounted "$rootfs"
  preflight_rootfs_os_release "$rootfs"
  preflight_rootfs_writable "$rootfs"

  # Rootfs filesystem validation (Section 2.7)
  preflight_rootfs_is_btrfs "$rootfs"
  preflight_rootfs_uuid_available "$rootfs"
  preflight_rootfs_uuid_unique "$rootfs" "$source_uuid"

  # PF-48: Only run if caller supplied the pre-mutation UUID
  if [[ -n "$pre_mutation_uuid" ]]; then
    preflight_rootfs_uuid_finalized "$rootfs" "$pre_mutation_uuid"
  fi

  debug "preflight_rootfs_validate: all checks passed for $rootfs"
}
