#!/bin/bash
#
# steamos-build-installer — lib/preflight_filesystem_state.sh
# Filesystem state validation: ensures the target filesystem is in a
# stable, consistent state before any modification begins.  Detects
# in-progress Btrfs operations (balance, device-replace, UUID change),
# verifies dm-verity device state and policy, checks boot payload
# integrity, and validates source image integrity via SHA-256 hashes.
#
# SHA-256 semantics (PF-64):
#   The SHA-256 verification here provides *transport/storage integrity*
#   checking, NOT source authenticity or cryptographic provenance.  It
#   detects accidental corruption (bit-rot, incomplete writes, media
#   errors) but does NOT prove the image came from a trusted source.
#   An attacker who controls the image file can trivially update the
#   adjacent .sha256 file to match a tampered image.  There is also an
#   inherent TOCTOU (time-of-check-to-time-of-use) gap: the image can
#   be modified after hashing but before it is attached or copied to its
#   final destination.  A proper solution requires a file lock or
#   snapshot mechanism to pin the image for the duration of the
#   operation; this is not yet implemented.  Until then, the check is a
#   best-effort integrity guard, not a security boundary.
#
# Requires: lib/common.sh (die, debug, warn)
# Do not run it directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/preflight_filesystem_state.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# NOTE — future module separation:
#   The source-integrity checks (PF-64) and boot-payload checks (PF-63) are
#   logically independent from the filesystem-state and dm-verity checks
#   (PF-59–PF-62).  As the codebase grows, these should be split into
#   dedicated modules (e.g., preflight_source_integrity.sh and
#   preflight_boot_payload.sh) to keep responsibilities cohesive and reduce
#   merge-conflict surface area.

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _pf_fs_resolve_findmnt_source SOURCE
#   Normalise a findmnt(8) SOURCE field to an absolute /dev/* path.
#   Handles:
#     - Already /dev/* paths — returned as-is
#     - dm-N names (always at /dev/dm-N) — prepends /dev/
#     - UUID=, PARTUUID=, LABEL= references — resolved via blkid -L / blkid -U
#     - Bare dm-mapper names — tried as /dev/mapper/<name> first, then /dev/<name>
#   Prints the resolved path and returns 0 on success, or returns 1 if
#   the result is not an existing block device.
_pf_fs_resolve_findmnt_source() {
  local source="${1:?_pf_fs_resolve_findmnt_source: missing source}"

  local resolved=""

  # Already an absolute /dev/* path — use directly.
  if [[ "$source" == /dev/* ]]; then
    resolved="$source"

  # dm-N kernel names are always at /dev/dm-N.
  elif [[ "$source" == dm-* ]]; then
    resolved="/dev/${source}"

  # UUID= / PARTUUID= / LABEL= references — resolve via blkid.
  elif [[ "$source" == UUID=* || "$source" == PARTUUID=* || "$source" == LABEL=* ]]; then
    # Strip the key prefix to get the bare value.
    local value="${source#*=}"
    local key="${source%%=*}"

    case "$key" in
      UUID)
        resolved="$(blkid -U "$value" 2>/dev/null)" || resolved=""
        ;;
      PARTUUID)
        # blkid -U does not always handle PARTUUID; fall back to findmnt -S.
        resolved="$(blkid -U "$value" 2>/dev/null)" || resolved=""
        if [[ -z "$resolved" ]] && command -v findmnt &>/dev/null; then
          resolved="$(findmnt -n -o SOURCE -S "$source" 2>/dev/null)" || resolved=""
          # findmnt may return another non-/dev path — recurse.
          if [[ -n "$resolved" && "$resolved" != /dev/* ]]; then
            resolved="$(_pf_fs_resolve_findmnt_source "$resolved")" || resolved=""
          fi
        fi
        ;;
      LABEL)
        resolved="$(blkid -L "$value" 2>/dev/null)" || resolved=""
        ;;
    esac

  # Bare dm-mapper name (no path separator) — try /dev/mapper/<name> first.
  elif [[ "$source" != /* ]]; then
    if [[ -b "/dev/mapper/${source}" ]]; then
      resolved="/dev/mapper/${source}"
    else
      resolved="/dev/${source}"
    fi

  # Absolute path but not under /dev/ (unlikely from findmnt, but be safe).
  else
    resolved="$source"
  fi

  # Verify the result is an actual block device.
  if [[ -z "$resolved" ]]; then
    return 1
  fi

  # Use -L to follow symlinks before the -b test.
  if [[ -L "$resolved" ]]; then
    local real
    real="$(realpath "$resolved" 2>/dev/null)" || real=""
    if [[ -n "$real" && -b "$real" ]]; then
      echo "$real"
      return 0
    fi
  fi

  if [[ -b "$resolved" ]]; then
    echo "$resolved"
    return 0
  fi

  return 1
}

# _pf_fs_acquire_btrfs_lock ROOTFS
#   Acquire an exclusive, non-blocking flock to serialise Btrfs mutations.
#   The lock must be held for the entire duration of any Btrfs-modifying
#   operation (not just the check).  On success, sets PF_BTRFS_LOCK_FD
#   and installs a RETURN trap to release the lock.  Dies immediately if
#   the lock cannot be acquired (another operation in progress).
#   Pattern follows preflight_resources_acquire_lock (PF-54a).
_pf_fs_acquire_btrfs_lock() {
  local rootfs="${1:?_pf_fs_acquire_btrfs_lock: missing rootfs path}"

  local lock_path="/tmp/steamos-btrfs-${rootfs//\//_}.lock"
  local lock_dir
  lock_dir="$(dirname "$lock_path")"

  if [[ ! -d "$lock_dir" ]]; then
    mkdir -p "$lock_dir" \
      || die "PF-60: could not create btrfs lock directory: $lock_dir"
  fi

  local fd=9
  # Attempt to acquire a non-blocking exclusive lock (subshell probe).
  # shellcheck disable=SC2094
  if ! (eval "exec ${fd}>\"$lock_path\"" && eval "flock -n ${fd}") 2>/dev/null; then
    die "PF-60: could not acquire Btrfs lock (another operation may be running): $lock_path"
  fi

  # Re-open and flock in the current shell so the lock is held for our lifetime.
  eval "exec ${fd}>\"$lock_path\""
  if ! flock -n "${fd}"; then
    eval "exec ${fd}>&-" 2>/dev/null || true
    die "PF-60: could not acquire Btrfs lock (another operation may be running): $lock_path"
  fi

  PF_BTRFS_LOCK_FD="$fd"

  # Install cleanup trap so the lock is released on function return or exit.
  trap '_pf_fs_release_btrfs_lock' RETURN

  debug "PF-60: Btrfs lock acquired on $lock_path (fd=$PF_BTRFS_LOCK_FD)"
}

# _pf_fs_release_btrfs_lock
#   Release the Btrfs flock held via _pf_fs_acquire_btrfs_lock.
#   Called automatically by the RETURN trap installed in the acquirer.
_pf_fs_release_btrfs_lock() {
  if [[ -n "${PF_BTRFS_LOCK_FD:-}" ]]; then
    eval "exec ${PF_BTRFS_LOCK_FD}>&-" 2>/dev/null || true
    debug "PF-60: Btrfs lock released (fd=$PF_BTRFS_LOCK_FD)"
    PF_BTRFS_LOCK_FD=""
  fi
}

# _pf_fs_get_btrfs_mount ROOTFS
#   Resolve the Btrfs mountpoint for ROOTFS via findmnt.
#   Prints the canonical mount path or empty on failure.
#   Uses findmnt -n -o TARGET for a clean output.
_pf_fs_get_btrfs_mount() {
  local rootfs="${1:?_pf_fs_get_btrfs_mount: missing rootfs path}"

  local mountpoint
  mountpoint="$(findmnt -n -o TARGET "$rootfs" 2>/dev/null)" || mountpoint=""

  if [[ -n "$mountpoint" ]]; then
    echo "$mountpoint"
  fi
}

# _pf_fs_btrfs_balance_active ROOTFS
#   Check whether a Btrfs balance operation is active on the filesystem
#   containing ROOTFS.
#   Returns:
#     0 — active balance operation detected
#     1 — no active balance operation (idle)
#     2 — unable to determine (missing tool, permission error, unexpected output)
#   Uses `btrfs balance status` which is non-destructive and safe to call.
_pf_fs_btrfs_balance_active() {
  local rootfs="${1:?_pf_fs_btrfs_balance_active: missing rootfs path}"

  # Fail closed: if btrfs is not installed we cannot determine status.
  if ! command -v btrfs &>/dev/null; then
    return 2
  fi

  local exit_code=0
  local output
  output="$(btrfs balance status "$rootfs" 2>&1)" || exit_code=$?

  # Exit code > 1 indicates an error (permission denied, invalid path, etc.).
  if ((exit_code > 1)); then
    return 2
  fi

  # The output contains "No balance found" when idle.
  if [[ "$output" == *"No balance found"* ]]; then
    return 1
  fi

  # The output contains "Balance is running" when active.
  if [[ "$output" == *"Balance is running"* ]]; then
    return 0
  fi

  # Unrecognised output — fail closed.
  return 2
}

# _pf_fs_btrfs_replace_active ROOTFS
#   Check whether a Btrfs device-replace operation is active on the
#   filesystem containing ROOTFS.
#   Returns:
#     0 — active replace operation detected
#     1 — no active replace operation (idle)
#     2 — unable to determine (missing tool, permission error, unexpected output)
#   Uses `btrfs replace status` which is non-destructive.
_pf_fs_btrfs_replace_active() {
  local rootfs="${1:?_pf_fs_btrfs_replace_active: missing rootfs path}"

  # Fail closed: if btrfs is not installed we cannot determine status.
  if ! command -v btrfs &>/dev/null; then
    return 2
  fi

  local exit_code=0
  local output
  output="$(btrfs replace status "$rootfs" 2>&1)" || exit_code=$?

  # Exit code > 1 indicates an error (permission denied, invalid path, etc.).
  if ((exit_code > 1)); then
    return 2
  fi

  # The output contains "No replace found on" when idle.
  if [[ "$output" == *"No replace found"* || "$output" == *"no replace found"* ]]; then
    return 1
  fi

  # The output contains "Replace operation in progress" when active.
  if [[ "$output" == *"in progress"* || "$output" == *"Replace running"* ]]; then
    return 0
  fi

  # Unrecognised output — fail closed.
  return 2
}

# _pf_fs_btrfs_uuid_change_active
#   Check whether a btrfstune UUID-change operation is active.
#   Returns:
#     0 — active UUID-change operation detected (not used currently, see below)
#     1 — no active UUID-change operation (idle)
#     2 — unable to determine (always, until a reliable locking mechanism is implemented)
#   NOTE: The old pgrep-based approach was unreliable (global, race-prone).
#         A proper per-filesystem locking mechanism is needed for accurate detection.
#         Until then we always return 2 (unable to determine) to fail closed.
_pf_fs_btrfs_uuid_change_active() {
  # pgrep -x btrfstune is unreliable — it is global and race-prone.
  # We cannot reliably detect an in-progress UUID change without proper
  # per-filesystem locking (e.g., advisory lock files or btrfs-specific state).
  # Fail closed: return unable-to-determine.
  return 2
}

# _pf_fs_resolve_device_major_minor DEVICE
#   Get the major:minor number pair for a block device.
#   Uses stat to extract device numbers. Prints "major:minor" or empty on failure.
_pf_fs_resolve_device_major_minor() {
  local device="${1:?_pf_fs_resolve_device_major_minor: missing device path}"

  if [[ ! -b "$device" ]]; then
    return 1
  fi

  local major minor
  major="$(stat -c '%t' "$device" 2>/dev/null)" || return 1
  minor="$(stat -c '%T' "$device" 2>/dev/null)" || return 1

  # stat returns hex; convert to decimal for dmsetup comparison.
  major=$((16#$major))
  minor=$((16#$minor))

  echo "${major}:${minor}"
}

# _pf_fs_get_dm_table_type DEVICE
#   Get the device-mapper target type for a dm device.
#   Uses `dmsetup table` to inspect the mapping table.
#   Prints the target type (e.g., "verity", "linear", "crypt") or empty on failure.
#   For devices with multiple table segments, returns the first segment's type.
_pf_fs_get_dm_table_type() {
  local device="${1:?_pf_fs_get_dm_table_type: missing device path}"

  local dev_name
  dev_name="$(basename "$device")"

  local dm_table
  dm_table="$(dmsetup table "$dev_name" 2>/dev/null)" || dm_table=""

  if [[ -z "$dm_table" ]]; then
    return 1
  fi

  # dmsetup table output format: "start_sector num_sectors TYPE args..."
  # The target type is the 3rd field (index 2) of the first line.
  local table_type
  table_type="$(echo "$dm_table" | head -n1 | awk '{print $3}')" || table_type=""

  if [[ -n "$table_type" ]]; then
    echo "$table_type"
  else
    return 1
  fi
}

# _pf_fs_check_device_identity DEVICE_A DEVICE_B
#   Compare two block devices using major:minor numbers to determine if they
#   refer to the same underlying device.
#   Returns:
#     0 — devices are identical (same major:minor)
#     1 — devices are different
#     2 — unable to determine (missing tools, non-block device, etc.)
_pf_fs_check_device_identity() {
  local device_a="${1:?_pf_fs_check_device_identity: missing device A}"
  local device_b="${2:?_pf_fs_check_device_identity: missing device B}"

  local mm_a mm_b
  mm_a="$(_pf_fs_resolve_device_major_minor "$device_a")" || return 2
  mm_b="$(_pf_fs_resolve_device_major_minor "$device_b")" || return 2

  if [[ "$mm_a" == "$mm_b" ]]; then
    return 0
  fi

  return 1
}

# _pf_fs_resolve_dm_data_device_major_minor DM_DEVICE_NAME
#   Resolve the underlying data device major:minor for a dm device.
#   Uses dmsetup table to parse the verity table and extract the data device.
#   Also tries dmsetup deps as a fallback for non-verity or complex tables.
#   Prints "major:minor" or empty on failure.
_pf_fs_resolve_dm_data_device_major_minor() {
  local dm_name="${1:?_pf_fs_resolve_dm_data_device_major_minor: missing dm device name}"

  # Method 1: Parse the dm table to find the data device field.
  # Verity table format (first segment):
  #   start_sector num_sectors verity <version> <data_device> <hash_device> ...
  local dm_table
  dm_table="$(dmsetup table "$dm_name" 2>/dev/null)" || dm_table=""

  if [[ -n "$dm_table" ]]; then
    # Extract the data device field (5th field from the first segment).
    local data_device_field
    data_device_field="$(echo "$dm_table" | head -n1 | awk '{print $5}')" || data_device_field=""

    if [[ -n "$data_device_field" ]]; then
      # Handle major:minor format directly.
      if [[ "$data_device_field" == *:* ]]; then
        echo "$data_device_field"
        return 0
      fi

      # Handle block device path.
      if [[ -b "$data_device_field" ]]; then
        local mm
        mm="$(_pf_fs_resolve_device_major_minor "$data_device_field" 2>/dev/null)" || mm=""
        if [[ -n "$mm" ]]; then
          echo "$mm"
          return 0
        fi
      fi

      # Handle dm device name (e.g., "rootfs.0") — resolve to major:minor.
      # A dm name in the table refers to another dm device; resolve it.
      if [[ "$data_device_field" != /* && "$data_device_field" != *:* ]]; then
        local resolved_mm
        resolved_mm="$(_pf_fs_resolve_device_major_minor "/dev/mapper/${data_device_field}" 2>/dev/null)" || resolved_mm=""
        if [[ -n "$resolved_mm" ]]; then
          echo "$resolved_mm"
          return 0
        fi
      fi
    fi
  fi

  # Method 2: Use dmsetup deps to find underlying device major:minor pairs.
  # dmsetup deps output format: "name: (major, minor) [(major, minor), ...]"
  # The deps list shows the devices that the dm device depends on.
  local dm_deps
  dm_deps="$(dmsetup deps "$dm_name" 2>/dev/null)" || dm_deps=""

  if [[ -n "$dm_deps" ]]; then
    # Extract all (major, minor) pairs from the deps line.
    local first_dep
    first_dep="$(echo "$dm_deps" | grep -oP '\(\d+,\s*\d+\)' | head -n1)" || first_dep=""

    if [[ -n "$first_dep" ]]; then
      # Convert "(major, minor)" to "major:minor" using parameter expansion.
      local dep_mm="${first_dep//[() ]/}"
      dep_mm="${dep_mm/,/:}"
      if [[ -n "$dep_mm" ]]; then
        echo "$dep_mm"
        return 0
      fi
    fi
  fi

  return 1
}

# _pf_fs_active_verity_devices ROOTFS
#   List active dm-verity devices associated with ROOTFS.
#   Prints each device path (one per line) or nothing if none exist.
#   Uses dmsetup table/deps and major/minor numbers to identify device
#   relationships. Handles devices without "verity" in their name by
#   checking the dm table type directly. Supports both /dev/dm-N and
#   /dev/mapper/<name> device sources. Relates devices to the target
#   rootfs using RAUC/partset topology via major:minor matching.
_pf_fs_active_verity_devices() {
  local rootfs="${1:?_pf_fs_active_verity_devices: missing rootfs path}"

  if ! command -v dmsetup &>/dev/null; then
    return 0
  fi

  local device
  device="$(findmnt -n -o SOURCE "$rootfs" 2>/dev/null)" || device=""

  if [[ -z "$device" ]]; then
    return 0
  fi

  # Resolve to absolute /dev/* path (handles dm-N, UUID, PARTUUID, bare names).
  device="$(_pf_fs_resolve_findmnt_source "$device")" || {
    debug "_pf_fs_active_verity_devices: could not resolve source '$device' to a block device"
    return 0
  }

  local rootfs_mm
  rootfs_mm="$(_pf_fs_resolve_device_major_minor "$device" 2>/dev/null)" || rootfs_mm=""

  # Strategy 1: If the rootfs device itself is a dm device, check its table type.
  # A dm device may appear as /dev/dm-N, /dev/mapper/<name>, or even a symlink.
  if [[ -b "$device" ]]; then
    local table_type
    table_type="$(_pf_fs_get_dm_table_type "$device" 2>/dev/null)" || table_type=""

    if [[ "$table_type" == "verity" ]]; then
      echo "$device"
      return 0
    fi
  fi

  # Strategy 2: Enumerate all dm devices and find verity targets whose
  # underlying data device matches rootfs (by major:minor).
  # This handles the SteamOS topology: rootfs.N (raw Btrfs) paired with
  # a separate verity.N slot that reads from it.
  local all_dm_devs
  all_dm_devs="$(dmsetup ls --target verity 2>/dev/null)" || all_dm_devs=""

  if [[ -n "$all_dm_devs" ]]; then
    while IFS= read -r line; do
      local dm_dev_name
      dm_dev_name="$(echo "$line" | awk '{print $1}')" || continue
      local dm_dev="/dev/mapper/${dm_dev_name}"

      if [[ ! -b "$dm_dev" ]]; then
        continue
      fi

      # Resolve the underlying data device's major:minor using table/deps.
      local data_dev_mm
      data_dev_mm="$(_pf_fs_resolve_dm_data_device_major_minor "$dm_dev_name" 2>/dev/null)" || data_dev_mm=""

      if [[ -n "$data_dev_mm" && -n "$rootfs_mm" && "$data_dev_mm" == "$rootfs_mm" ]]; then
        echo "$dm_dev"
      fi
    done <<<"$all_dm_devs"
    return 0
  fi

  # Strategy 3: Fallback — look for named dm devices in /dev/mapper/.
  # Check any dm device whose table type is "verity" and whose data device
  # matches rootfs major:minor.
  local mapper_dir="/dev/mapper"
  if [[ -d "$mapper_dir" ]]; then
    local dm_name
    for dm_name in "$mapper_dir"/*; do
      [[ -b "$dm_name" ]] || continue
      local dm_basename
      dm_basename="$(basename "$dm_name")"

      local table_type
      table_type="$(_pf_fs_get_dm_table_type "/dev/mapper/${dm_basename}" 2>/dev/null)" || continue

      if [[ "$table_type" != "verity" ]]; then
        continue
      fi

      # Resolve the underlying data device's major:minor using table/deps.
      local data_dev_mm
      data_dev_mm="$(_pf_fs_resolve_dm_data_device_major_minor "$dm_basename" 2>/dev/null)" || data_dev_mm=""

      if [[ -n "$data_dev_mm" && -n "$rootfs_mm" && "$data_dev_mm" == "$rootfs_mm" ]]; then
        echo "$dm_name"
      fi
    done
  fi
}

# _pf_fs_compute_sha256 FILE_PATH
#   Compute the SHA-256 hash of FILE_PATH.
#   Prints the hex-encoded hash string.
#   Returns non-zero if sha256sum is unavailable or the computation fails.
#   NOTE: The caller must check the return code.  This function does NOT
#   die() because die() inside a command substitution only exits the
#   subshell — the caller would silently continue with empty data.
_pf_fs_compute_sha256() {
  local file_path="${1:?_pf_fs_compute_sha256: missing file path}"

  if [[ ! -f "$file_path" ]]; then
    echo "_pf_fs_compute_sha256: file does not exist: $file_path" >&2
    return 1
  fi

  if ! command -v sha256sum &>/dev/null; then
    echo "_pf_fs_compute_sha256: sha256sum not available" >&2
    return 1
  fi

  local hash
  hash="$(sha256sum "$file_path" 2>/dev/null)" \
    || {
      echo "_pf_fs_compute_sha256: failed to compute hash for $file_path" >&2
      return 1
    }

  # sha256sum outputs "hash  filename" — extract the hash.
  echo "$hash" | awk '{print $1}'
}

# _pf_fs_locate_hash_file IMAGE_PATH
#   Find the companion hash file for IMAGE_PATH.
#   Convention: the hash file is IMAGE_PATH with .sha256 appended.
#   Prints the path if found, otherwise returns 1.
_pf_fs_locate_hash_file() {
  local image_path="${1:?_pf_fs_locate_hash_file: missing image path}"

  local hash_file="${image_path}.sha256"

  if [[ -f "$hash_file" ]]; then
    echo "$hash_file"
    return 0
  fi

  return 1
}

# _pf_fs_parse_hash_file HASH_FILE
#   Extract the SHA-256 hash from HASH_FILE.
#   Reads all non-empty, non-comment lines (lines starting with # are skipped).
#   Supports formats:
#     "hash  filename"   (sha256sum output format — first field is the hash)
#     "hash"             (bare hash, no filename)
#   Uses the first valid hash found (single-file .sha256 files typically
#   contain one line).  Validates the hash is exactly 64 hex characters.
#   Handles leading/trailing whitespace on each line.
#   Prints the hash string.
#   Dies if the file is empty, contains no valid hash, or the hash is malformed.
_pf_fs_parse_hash_file() {
  local hash_file="${1:?_pf_fs_parse_hash_file: missing hash file path}"

  if [[ ! -f "$hash_file" ]]; then
    die "_pf_fs_parse_hash_file: hash file does not exist: $hash_file"
  fi

  if [[ ! -s "$hash_file" ]]; then
    die "_pf_fs_parse_hash_file: hash file is empty: $hash_file"
  fi

  # Read the entire file, skip comments and empty lines, extract the first
  # valid hash from the first non-trivial line.
  local hash=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip leading/trailing whitespace.
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    # Skip empty lines and comment lines.
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue

    # Take the first whitespace-delimited field (handles "hash  filename"
    # sha256sum format as well as bare "hash" format).
    hash="$(echo "$line" | awk '{print $1}')"

    # Validate hash is hex and exactly 64 characters.
    if [[ ! "$hash" =~ ^[0-9a-fA-F]{64}$ ]]; then
      die "_pf_fs_parse_hash_file: invalid SHA-256 hash in $hash_file: '$hash'"
    fi

    echo "$hash"
    return 0
  done <"$hash_file"

  die "_pf_fs_parse_hash_file: hash file contains no valid hash: $hash_file"
}

# ---------------------------------------------------------------------------
# Individual checks — independently callable
# ---------------------------------------------------------------------------

# pf_fs_check_rootfs_device_identity ROOTFS TARGET_DEVICE
#   PF-59: Verify that ROOTFS is actually mounted from TARGET_DEVICE by
#   comparing their major:minor device numbers.  Path-based matching is
#   unreliable because device symlinks and names can change; major:minor
#   numbers are the stable kernel-level device identity.
#
#   Parameters:
#     ROOTFS        — mounted root filesystem path
#     TARGET_DEVICE — expected block device that ROOTFS should be mounted from
#
#   Dies if ROOTFS is not mounted from TARGET_DEVICE.
pf_fs_check_rootfs_device_identity() {
  local rootfs="${1:?pf_fs_check_rootfs_device_identity: missing rootfs path}"
  local target_device="${2:?pf_fs_check_rootfs_device_identity: missing target device}"

  if [[ -z "$target_device" ]]; then
    debug "PF-59: no TARGET_DEVICE provided — skipping rootfs device identity check"
    return 0
  fi

  # Resolve the actual device backing the rootfs mount.
  local actual_source
  actual_source="$(findmnt -n -o SOURCE "$rootfs" 2>/dev/null)" || actual_source=""

  if [[ -z "$actual_source" ]]; then
    die "PF-59: unable to determine the device backing rootfs mount at $rootfs"
  fi

  # Resolve to an absolute /dev/* path (handles dm-N, UUID, PARTUUID, bare names).
  actual_source="$(_pf_fs_resolve_findmnt_source "$actual_source")" \
    || die "PF-59: rootfs source '$actual_source' could not be resolved to a block device"

  if [[ ! -b "$actual_source" ]]; then
    die "PF-59: rootfs source $actual_source is not a block device"
  fi

  # Resolve major:minor for both devices.
  local actual_mm target_mm
  actual_mm="$(_pf_fs_resolve_device_major_minor "$actual_source" 2>/dev/null)" || actual_mm=""
  target_mm="$(_pf_fs_resolve_device_major_minor "$target_device" 2>/dev/null)" || target_mm=""

  if [[ -z "$actual_mm" ]]; then
    die "PF-59: unable to resolve major:minor for rootfs source device $actual_source"
  fi

  if [[ -z "$target_mm" ]]; then
    die "PF-59: unable to resolve major:minor for TARGET_DEVICE $target_device"
  fi

  if [[ "$actual_mm" != "$target_mm" ]]; then
    die "PF-59: rootfs at $rootfs is mounted from $actual_source (major:minor $actual_mm) but TARGET_DEVICE is $target_device (major:minor $target_mm) — device identity mismatch"
  fi

  debug "PF-59: rootfs device identity verified: $rootfs → $actual_source (major:minor $actual_mm) matches TARGET_DEVICE $target_device (major:minor $target_mm)"
}

# preflight_filesystem_state_no_btrfs_operations ROOTFS
#   PF-60: Ensure no active Btrfs balance, device-replace, or UUID-change
#   operation is in progress.  Active Btrfs operations can cause data
#   corruption or incomplete state if we proceed concurrently.
#
#   Each sub-check returns one of three statuses:
#     0 — active operation detected  → die
#     1 — no active operation (idle)  → continue
#     2 — unable to determine state   → die (fail closed)
pf_fs_check_no_btrfs_operations() {
  local rootfs="${1:?pf_fs_check_no_btrfs_operations: missing rootfs path}"
  local rc

  _pf_fs_acquire_btrfs_lock "$rootfs"

  _pf_fs_btrfs_balance_active "$rootfs"
  rc=$?
  if ((rc == 2)); then
    die "PF-60: unable to determine Btrfs balance state on $rootfs — btrfs balance status failed or produced unexpected output"
  fi
  if ((rc == 0)); then
    die "PF-60: active Btrfs balance operation detected on $rootfs — must complete before proceeding"
  fi
  debug "PF-60: no active Btrfs balance on $rootfs"

  _pf_fs_btrfs_replace_active "$rootfs"
  rc=$?
  if ((rc == 2)); then
    die "PF-60: unable to determine Btrfs replace state on $rootfs — btrfs replace status failed or produced unexpected output"
  fi
  if ((rc == 0)); then
    die "PF-60: active Btrfs device-replace operation detected on $rootfs — must complete before proceeding"
  fi
  debug "PF-60: no active Btrfs device-replace on $rootfs"

  _pf_fs_btrfs_uuid_change_active
  rc=$?
  if ((rc == 2)); then
    die "PF-60: unable to determine btrfstune UUID-change state — no reliable detection method available"
  fi
  if ((rc == 0)); then
    die "PF-60: active btrfstune UUID-change operation detected — must complete before proceeding"
  fi
  debug "PF-60: no active btrfstune UUID-change"

  debug "PF-60: no active Btrfs operations detected"
}

# preflight_filesystem_state_verity_inactive ROOTFS ROOTFS_DEVICE VERITY_DEVICE
#   PF-61: Verify that dm-verity devices are either inactive or consistent
#   with the expected state.  On systems without dm-verity, this check
#   gracefully skips.  Active verity devices that conflict with planned
#   modifications will cause a failure.
#
#   Parameters:
#     ROOTFS        — mounted root filesystem path
#     ROOTFS_DEVICE — expected rootfs block device (e.g., /dev/nvme0n1p3)
#     VERITY_DEVICE — expected verity device (e.g., /dev/mapper/rootfs.0-verity)
pf_fs_check_verity_inactive() {
  local rootfs="${1:?pf_fs_check_verity_inactive: missing rootfs path}"
  local rootfs_device="${2:-}"
  local verity_device="${3:-}"

  # Graceful skip: if dm-verity tooling is not present, this is not applicable.
  if ! command -v veritysetup &>/dev/null && ! command -v dmsetup &>/dev/null; then
    debug "PF-61: neither veritysetup nor dmsetup found — skipping (no verity support)"
    return 0
  fi

  local verity_devices
  verity_devices="$(_pf_fs_active_verity_devices "$rootfs")"

  if [[ -z "$verity_devices" ]]; then
    debug "PF-61: no active dm-verity devices for $rootfs"
    return 0
  fi

  # If specific devices were provided, verify them against the active list.
  if [[ -n "$rootfs_device" && -n "$verity_device" ]]; then
    # Verify that the rootfs is mounted from the expected device.
    local actual_rootfs_dev
    actual_rootfs_dev="$(findmnt -n -o SOURCE "$rootfs" 2>/dev/null)" || actual_rootfs_dev=""
    actual_rootfs_dev="$(_pf_fs_resolve_findmnt_source "$actual_rootfs_dev")" \
      || actual_rootfs_dev=""

    if [[ -n "$actual_rootfs_dev" ]]; then
      local rootfs_match
      if _pf_fs_check_device_identity "$actual_rootfs_dev" "$rootfs_device"; then
        rootfs_match=0
      else
        rootfs_match=1
      fi

      if ((rootfs_match != 0)); then
        die "PF-61: rootfs $rootfs is mounted from $actual_rootfs_dev, expected $rootfs_device"
      fi
      debug "PF-61: rootfs device verified: $actual_rootfs_dev matches $rootfs_device"
    fi

    # Check that the verity device matches the expected pair.
    local verity_found=0
    while IFS= read -r vdev; do
      if [[ -n "$vdev" ]] && _pf_fs_check_device_identity "$vdev" "$verity_device"; then
        verity_found=1
        break
      fi
    done <<<"$verity_devices"

    if ((verity_found == 0)); then
      # The expected verity device is not among the active devices — not a conflict.
      debug "PF-61: expected verity device $verity_device is not active (no conflict)"
      return 0
    fi

    # The expected verity device IS active — this is a conflict for modification.
    die "PF-61: expected verity device $verity_device is active and conflicts with planned modifications"
  fi

  # No specific devices provided — use legacy behavior: any active verity = fail.
  local verity_count
  verity_count="$(echo "$verity_devices" | wc -l)" || verity_count="0"

  # Verity devices are active — incompatible with planned modifications.
  die "PF-61: $verity_count active dm-verity device(s) detected for $rootfs — verity device is active"
}

# preflight_filesystem_state_verity_policy_defined ROOTFS ROOTFS_DEVICE VERITY_DEVICE VERITY_POLICY
#   PF-62: When the rootfs will be modified, verify that a dm-verity policy
#   is defined for the rootfs device.  This ensures that any modification
#   includes proper verity policy re-association.  Gracefully skips on
#   non-verity systems.
#
#   Parameters:
#     ROOTFS          — mounted root filesystem path
#     ROOTFS_DEVICE   — rootfs block device
#     VERITY_DEVICE   — verity device paired with rootfs
#     VERITY_POLICY   — policy for verity update: "regenerate", "disable",
#                       "leave-invalid", or "not-applicable"
pf_fs_check_verity_policy_defined() {
  local rootfs="${1:?pf_fs_check_verity_policy_defined: missing rootfs path}"
  local rootfs_device="${2:-}"
  local verity_device="${3:-}"
  local verity_policy="${4:-}"

  # Graceful skip: if dmsetup is not available, this is not applicable.
  if ! command -v dmsetup &>/dev/null; then
    debug "PF-62: dmsetup not found — skipping (no verity support)"
    return 0
  fi

  # Validate VERITY_POLICY if provided.
  if [[ -n "$verity_policy" ]]; then
    case "$verity_policy" in
      regenerate | disable | leave-invalid | not-applicable)
        debug "PF-62: VERITY_POLICY '$verity_policy' is valid"
        ;;
      *)
        die "PF-62: invalid VERITY_POLICY '$verity_policy' — must be one of: regenerate, disable, leave-invalid, not-applicable"
        ;;
    esac
  fi

  # If no specific devices provided, fall back to inspecting whatever is mounted.
  if [[ -z "$rootfs_device" && -z "$verity_device" ]]; then
    local device
    device="$(findmnt -n -o SOURCE "$rootfs" 2>/dev/null)" || device=""

    if [[ -z "$device" ]]; then
      debug "PF-62: could not resolve rootfs device — skipping verity policy check"
      return 0
    fi

    # Resolve to absolute /dev/* path (handles dm-N, UUID, PARTUUID, bare names).
    device="$(_pf_fs_resolve_findmnt_source "$device")" || {
      debug "PF-62: could not resolve rootfs device to a block device — skipping verity policy check"
      return 0
    }

    # Check if the device is a dm device that could have verity.
    if [[ ! -b "$device" ]]; then
      debug "PF-62: device $device is not a block device — skipping verity policy check"
      return 0
    fi

    local dev_name
    dev_name="$(basename "$device")"

    # Only check verity policy for dm devices.
    if [[ "$dev_name" != dm-* ]]; then
      debug "PF-62: device $device is not a dm device — no verity policy to verify"
      return 0
    fi

    # Check the dm table for verity targets.
    local table_type
    table_type="$(_pf_fs_get_dm_table_type "$device" 2>/dev/null)" || table_type=""

    if [[ -n "$table_type" && "$table_type" == "verity" ]]; then
      debug "PF-62: dm-verity policy is defined for $device"
      return 0
    fi

    # Device exists but has no verity policy.
    die "PF-62: dm device $device has no verity policy (table type: ${table_type:-<empty>}) — verity update policy not defined"
  fi

  # Specific devices provided — validate the verity device's table type.
  if [[ -n "$verity_device" ]]; then
    if [[ ! -b "$verity_device" ]]; then
      debug "PF-62: verity device $verity_device is not a block device — skipping table check"
      return 0
    fi

    local table_type
    table_type="$(_pf_fs_get_dm_table_type "$verity_device" 2>/dev/null)" || table_type=""

    if [[ -n "$table_type" && "$table_type" == "verity" ]]; then
      debug "PF-62: verity device $verity_device has correct table type 'verity'"
    else
      die "PF-62: verity device $verity_device has unexpected table type '${table_type:-<empty>}' — expected 'verity'"
    fi

    # Verify that the verity device's data device matches the rootfs device.
    if [[ -n "$rootfs_device" ]]; then
      local verity_mm rootfs_mm
      verity_mm="$(_pf_fs_resolve_device_major_minor "$verity_device" 2>/dev/null)" || verity_mm=""
      rootfs_mm="$(_pf_fs_resolve_device_major_minor "$rootfs_device" 2>/dev/null)" || rootfs_mm=""

      if [[ -n "$verity_mm" && -n "$rootfs_mm" && "$verity_mm" == "$rootfs_mm" ]]; then
        die "PF-62: verity device $verity_device has the same major:minor as rootfs $rootfs_device — topology mismatch"
      fi
      debug "PF-62: verity device $verity_device identity verified against rootfs $rootfs_device"
    fi
  fi

  debug "PF-62: verity policy check passed"
}

# _pf_fs_validate_boot_file FILE_PATH BOOT_DIR ROOTFS
#   Validate that a boot payload file (kernel or initramfs) satisfies
#   the safety and integrity requirements:
#     - Exists and is a regular file (not a directory, device, etc.)
#     - Is nonempty
#     - Resolves to a path that remains beneath ROOTFS (no symlink escape)
#   Prints the canonical absolute path of the file on success.
#   Dies with a descriptive error on failure.
_pf_fs_validate_boot_file() {
  local file_path="${1:?_pf_fs_validate_boot_file: missing file path}"
  local boot_dir="${2:?_pf_fs_validate_boot_file: missing boot dir}"
  local rootfs="${3:?_pf_fs_validate_boot_file: missing rootfs path}"

  # Must exist and be a regular file (follows symlinks via -L).
  if [[ ! -L "$file_path" && ! -f "$file_path" ]]; then
    die "PF-63: boot file is not a regular file: $file_path"
  fi

  # Resolve symlinks to their real target.
  local resolved
  resolved="$(realpath "$file_path" 2>/dev/null)" \
    || die "PF-63: unable to resolve boot file path: $file_path"

  # The resolved path must remain beneath the target rootfs.
  if [[ "$resolved" != "$rootfs"/* ]]; then
    die "PF-63: boot file escapes target root — $file_path resolves to $resolved which is outside $rootfs"
  fi

  # The resolved target must also be beneath the boot directory (or at least
  # the rootfs).  For extra safety, ensure it doesn't escape the boot dir.
  if [[ "$resolved" != "$boot_dir"/* ]]; then
    die "PF-63: boot file resolves outside boot directory — $file_path resolves to $resolved (expected under $boot_dir)"
  fi

  # The resolved file must be a regular file (not a dangling symlink target
  # pointing to a device, socket, etc.).
  if [[ ! -f "$resolved" ]]; then
    die "PF-63: resolved boot file is not a regular file: $resolved (from $file_path)"
  fi

  # Must be nonempty.
  if [[ ! -s "$resolved" ]]; then
    die "PF-63: boot file is empty: $file_path (resolved: $resolved)"
  fi

  echo "$resolved"
}

# _pf_fs_extract_kernel_version KERNEL_FILENAME
#   Extract the version suffix from a kernel filename for matching against
#   initramfs names.  The suffix is everything after the leading identifier
#   (vmlinuz-, vmlinux-, bzImage-).
#
#   Examples:
#     vmlinuz-linux-neptune-618          → linux-neptune-618
#     vmlinuz-6.1.52-valve-neptune-61    → 6.1.52-valve-neptune-61
#     vmlinuz                          →  (empty — no version)
#     vmlinux-foo                       → foo
#   Prints the extracted version suffix (may be empty).
_pf_fs_extract_kernel_version() {
  local kernel_name="${1:?_pf_fs_extract_kernel_version: missing kernel filename}"

  local version_suffix=""

  case "$kernel_name" in
    vmlinuz-*) version_suffix="${kernel_name#vmlinuz-}" ;;
    vmlinux-*) version_suffix="${kernel_name#vmlinux-}" ;;
    bzImage-*) version_suffix="${kernel_name#bzImage-}" ;;
    *) version_suffix="" ;;
  esac

  echo "$version_suffix"
}

# _pf_fs_extract_initrd_version INITRD_FILENAME
#   Extract the version suffix from an initramfs/initrd filename.
#   Strips the known prefixes (initramfs-, initrd-, initrd.img-) and
#   the trailing compression extension (.img, .zst, .xz, .gz, .lz4).
#
#   Examples:
#     initramfs-linux-neptune-618.img          → linux-neptune-618
#     initramfs-6.1.52-valve-neptune-61.img    → 6.1.52-valve-neptune-61
#     initrd-6.1.52.img                        → 6.1.52
#     initrd.img                               →  (empty — no version)
#   Prints the extracted version suffix (may be empty).
_pf_fs_extract_initrd_version() {
  local initrd_name="${1:?_pf_fs_extract_initrd_version: missing initrd filename}"

  local version_suffix=""

  # Strip the prefix.
  case "$initrd_name" in
    initramfs-*) version_suffix="${initrd_name#initramfs-}" ;;
    initrd.img-*) version_suffix="${initrd_name#initrd.img-}" ;;
    initrd-*) version_suffix="${initrd_name#initrd-}" ;;
    *) version_suffix="" ;;
  esac

  # Strip trailing compression extensions.
  version_suffix="${version_suffix%.img}"
  version_suffix="${version_suffix%.zst}"
  version_suffix="${version_suffix%.xz}"
  version_suffix="${version_suffix%.gz}"
  version_suffix="${version_suffix%.lz4}"
  version_suffix="${version_suffix%.cpio}"

  echo "$version_suffix"
}

# preflight_filesystem_state_coherent_boot_payload ROOTFS
#   PF-63: Verify that at least one matching kernel/initramfs pair exists
#   in the rootfs.  A boot system requires both a kernel image and a
#   matching initramfs to successfully boot.
#
#   Matching rule: the version suffix extracted from the kernel filename
#   (everything after vmlinuz-/vmlinux-/bzImage-) must equal the version
#   suffix extracted from the initramfs filename (everything after
#   initramfs-/initrd-/initrd.img- and before the compression extension).
#
#   Each candidate file is validated to be:
#     - A nonempty regular file (or a symlink to one)
#     - Resolved to a path that remains beneath the target root
#
#   Dies if no matching pair is found.
pf_fs_check_coherent_boot_payload() {
  local rootfs="${1:?pf_fs_check_coherent_boot_payload: missing rootfs path}"

  local boot_dir="$rootfs/boot"

  if [[ ! -d "$boot_dir" ]]; then
    die "PF-63: boot directory does not exist: $boot_dir"
  fi

  # Collect candidate kernel and initramfs files.
  # Use -L to follow symlinks for -type f check, then validate resolved path.
  local -a kernel_files=()
  local -a initrd_files=()

  while IFS= read -r f; do
    kernel_files+=("$f")
  done < <(find "$boot_dir" -maxdepth 1 \( \( -name 'vmlinuz*' -o -name 'vmlinux*' -o -name 'bzImage*' \) \( -type f -o -type l \) \) 2>/dev/null)

  while IFS= read -r f; do
    initrd_files+=("$f")
  done < <(find "$boot_dir" -maxdepth 1 \( \( -name 'initramfs*' -o -name 'initrd*' \) \( -type f -o -type l \) \) 2>/dev/null)

  if ((${#kernel_files[@]} == 0)); then
    die "PF-63: no kernel image found in $boot_dir (expected vmlinuz*, vmlinux*, or bzImage*)"
  fi

  if ((${#initrd_files[@]} == 0)); then
    die "PF-63: no initramfs/initrd found in $boot_dir (expected initramfs* or initrd*)"
  fi

  # Validate each candidate file and collect resolved paths.
  local -a valid_kernels=()
  local -a valid_initrds=()

  for f in "${kernel_files[@]}"; do
    local resolved
    resolved="$(_pf_fs_validate_boot_file "$f" "$boot_dir" "$rootfs")" || continue
    valid_kernels+=("$resolved")
  done

  for f in "${initrd_files[@]}"; do
    local resolved
    resolved="$(_pf_fs_validate_boot_file "$f" "$boot_dir" "$rootfs")" || continue
    valid_initrds+=("$resolved")
  done

  if ((${#valid_kernels[@]} == 0)); then
    die "PF-63: no valid kernel image found in $boot_dir (all candidates failed validation — must be nonempty regular files beneath $rootfs)"
  fi

  if ((${#valid_initrds[@]} == 0)); then
    die "PF-63: no valid initramfs/initrd found in $boot_dir (all candidates failed validation — must be nonempty regular files beneath $rootfs)"
  fi

  # Attempt to find at least one matching kernel/initramfs pair.
  local pair_found=0

  for kernel_path in "${valid_kernels[@]}"; do
    local kernel_basename
    kernel_basename="$(basename "$kernel_path")"
    local kernel_version
    kernel_version="$(_pf_fs_extract_kernel_version "$kernel_basename")"

    if [[ -z "$kernel_version" ]]; then
      debug "PF-63: kernel $kernel_basename has no extractable version suffix — skipping"
      continue
    fi

    for initrd_path in "${valid_initrds[@]}"; do
      local initrd_basename
      initrd_basename="$(basename "$initrd_path")"
      local initrd_version
      initrd_version="$(_pf_fs_extract_initrd_version "$initrd_basename")"

      if [[ -z "$initrd_version" ]]; then
        debug "PF-63: initramfs $initrd_basename has no extractable version suffix — skipping"
        continue
      fi

      if [[ "$kernel_version" == "$initrd_version" ]]; then
        pair_found=1
        debug "PF-63: matched kernel/initramfs pair: $kernel_basename ↔ $initrd_basename (version: $kernel_version)"
        break 2
      fi
    done
  done

  if ((pair_found == 0)); then
    # Build a diagnostic listing of what was found.
    local kernel_names=""
    for k in "${valid_kernels[@]}"; do
      local kn
      kn="$(basename "$k")"
      local kv
      kv="$(_pf_fs_extract_kernel_version "$kn")"
      kernel_names="${kernel_names:+$kernel_names, }${kn} (version: ${kv:-<none>})"
    done

    local initrd_names=""
    for i in "${valid_initrds[@]}"; do
      local in
      in="$(basename "$i")"
      local iv
      iv="$(_pf_fs_extract_initrd_version "$in")"
      initrd_names="${initrd_names:+$initrd_names, }${in} (version: ${iv:-<none>})"
    done

    die "PF-63: no matching kernel/initramfs pair found in $boot_dir
  kernels:    $kernel_names
  initramfs:  $initrd_names
  Expected at least one kernel version suffix to match an initramfs version suffix (e.g., vmlinuz-linux-neptune-618 ↔ initramfs-linux-neptune-618.img)"
  fi

  debug "PF-63: boot payload coherent — at least one matching kernel/initramfs pair verified in $boot_dir (${#valid_kernels[@]} valid kernel(s), ${#valid_initrds[@]} valid initramfs(s))"
}

# preflight_filesystem_state_source_integrity IMAGE_PATH EXPECTED_HASH
#   PF-64: Verify the source image integrity by computing its SHA-256 hash
#   and comparing it against EXPECTED_HASH.  If EXPECTED_HASH is provided,
#   a direct comparison is performed.  If EXPECTED_HASH is empty, the
#   companion hash file (.sha256) is located and parsed for the expected hash.
#   Dies on mismatch.
pf_fs_check_source_integrity() {
  local image_path="${1:?pf_fs_check_source_integrity: missing image path}"
  local expected_hash="${2:-}"

  if [[ ! -f "$image_path" ]]; then
    die "PF-64: source image does not exist: $image_path"
  fi

  # Compute the actual hash.
  # NOTE: die() inside a command substitution only exits the subshell, not
  # the calling function.  We must capture the exit code and call die()
  # from the parent context to ensure the script terminates properly.
  local actual_hash
  if ! actual_hash="$(_pf_fs_compute_sha256 "$image_path")"; then
    die "PF-64: could not hash source image: $image_path"
  fi

  # Resolve expected hash: use provided value or look for companion hash file.
  if [[ -z "$expected_hash" ]]; then
    local hash_file
    if hash_file="$(_pf_fs_locate_hash_file "$image_path")"; then
      expected_hash="$(_pf_fs_parse_hash_file "$hash_file")"
      debug "PF-64: loaded expected hash from $hash_file"
    else
      die "PF-64: no expected hash provided and no companion hash file found: ${image_path}.sha256"
    fi
  fi

  # Compare hashes (case-insensitive for hex).
  if [[ "${actual_hash,,}" != "${expected_hash,,}" ]]; then
    die "PF-64: source image integrity mismatch for $image_path
  expected: $expected_hash
  actual:   $actual_hash"
  fi

  debug "PF-64: source image integrity verified: $image_path (hash=$actual_hash)"
}

# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------

# preflight_filesystem_state_validate ROOTFS [TARGET_DEVICE] [IMAGE_PATH] [EXPECTED_HASH] [ROOTFS_MODIFIED] [ROOTFS_DEVICE] [VERITY_DEVICE] [VERITY_POLICY]
#   Run the full filesystem state validation sequence:
#     PF-59  Rootfs device identity (ROOTFS mounted from TARGET_DEVICE)
#     PF-60  No active Btrfs operations (balance/device-replace/UUID change)
#     PF-61  dm-verity device state (graceful skip if no verity)
#     PF-62  dm-verity policy defined (when ROOTFS_MODIFIED=true)
#     PF-63  Boot payload exists (kernel + initramfs)
#     PF-64  Source image integrity (SHA-256 verification)
#
#   Required arguments:
#     ROOTFS          — mounted root filesystem path
#
#   Optional arguments:
#     TARGET_DEVICE   — target block device; ROOTFS must be mounted from this
#                       device (verified via major:minor identity check)
#     IMAGE_PATH      — source image file to verify integrity
#     EXPECTED_HASH   — expected SHA-256 hash (if empty, looks for .sha256 file)
#     ROOTFS_MODIFIED — enum/boolean: "true", "false", "1", "0", "yes", "no"
#                       If rootfs changes, require an applicable verity policy
#     ROOTFS_DEVICE   — rootfs block device (for verity pair validation)
#     VERITY_DEVICE   — verity device paired with rootfs (for topology check)
#     VERITY_POLICY   — policy for verity update: "regenerate", "disable",
#                       "leave-invalid", or "not-applicable"
#
#   Dies on the first fatal check failure; returns 0 when all checks pass.
preflight_filesystem_state_validate() {
  local rootfs="${1:?preflight_filesystem_state_validate: missing ROOTFS}"
  local target_device="${2:-}"
  local image_path="${3:-}"
  local expected_hash="${4:-}"
  local rootfs_modified="${5:-}"
  local rootfs_device="${6:-}"
  local verity_device="${7:-}"
  local verity_policy="${8:-}"

  # Validate ROOTFS_MODIFIED as enum/boolean.
  local rootfs_modified_bool="false"
  if [[ -n "$rootfs_modified" ]]; then
    case "${rootfs_modified,,}" in
      true | 1 | yes)
        rootfs_modified_bool="true"
        ;;
      false | 0 | no)
        rootfs_modified_bool="false"
        ;;
      *)
        die "preflight_filesystem_state_validate: invalid ROOTFS_MODIFIED value '$rootfs_modified' — must be one of: true, false, 1, 0, yes, no"
        ;;
    esac
  fi

  # If rootfs is modified, require an applicable verity policy.
  if [[ "$rootfs_modified_bool" == "true" ]]; then
    if [[ -n "$verity_policy" ]]; then
      case "$verity_policy" in
        regenerate | disable | leave-invalid)
          debug "preflight_filesystem_state_validate: ROOTFS_MODIFIED=true with applicable policy '$verity_policy'"
          ;;
        not-applicable)
          die "preflight_filesystem_state_validate: ROOTFS_MODIFIED=true but VERITY_POLICY='not-applicable' — a modification requires an applicable verity policy"
          ;;
        *)
          die "preflight_filesystem_state_validate: invalid VERITY_POLICY '$verity_policy' — must be one of: regenerate, disable, leave-invalid, not-applicable"
          ;;
      esac
    elif [[ -n "$verity_device" ]]; then
      # A verity device was specified but no policy — this is an error for modifications.
      die "preflight_filesystem_state_validate: ROOTFS_MODIFIED=true with VERITY_DEVICE=$verity_device but no VERITY_POLICY specified"
    fi
  fi

  debug "preflight_filesystem_state_validate: rootfs=$rootfs device=${target_device:-<none>} image=${image_path:-<none>} rootfs_modified=$rootfs_modified_bool rootfs_device=${rootfs_device:-<none>} verity_device=${verity_device:-<none>} verity_policy=${verity_policy:-<none>}"

  # PF-59: Rootfs device identity — verify ROOTFS is mounted from TARGET_DEVICE.
  # This must run before any other checks to ensure we are operating on the
  # correct device.  Uses major:minor comparison (not path strings).
  if [[ -n "$target_device" ]]; then
    pf_fs_check_rootfs_device_identity "$rootfs" "$target_device"
  else
    debug "PF-59: no TARGET_DEVICE provided — skipping rootfs device identity check"
  fi

  # PF-60: No active Btrfs operations.
  pf_fs_check_no_btrfs_operations "$rootfs"

  # PF-61: Verity device state (graceful skip on non-verity systems).
  pf_fs_check_verity_inactive "$rootfs" "$rootfs_device" "$verity_device"

  # PF-62: Verity policy defined (only when rootfs will be modified).
  if [[ "$rootfs_modified_bool" == "true" ]]; then
    pf_fs_check_verity_policy_defined "$rootfs" "$rootfs_device" "$verity_device" "$verity_policy"
  else
    debug "PF-62: rootfs_modified is not true — skipping verity policy check"
  fi

  # PF-63: Boot payload exists.
  pf_fs_check_coherent_boot_payload "$rootfs"

  # PF-64: Source image integrity (only when IMAGE_PATH is provided).
  if [[ -n "$image_path" ]]; then
    pf_fs_check_source_integrity "$image_path" "$expected_hash"
  else
    debug "PF-64: no IMAGE_PATH provided — skipping source integrity check"
  fi

  debug "preflight_filesystem_state_validate: all filesystem state checks passed"
}
