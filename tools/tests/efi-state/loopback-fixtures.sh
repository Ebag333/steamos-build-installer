#!/bin/bash
#
# tools/tests/efi-state/loopback-fixtures.sh
# Loopback-based real GPT image fixtures for EFI state application tests.
#
# Creates real sparse GPT images with loop devices, real filesystems
# (vfat for ESP/EFI, btrfs for rootfs/var), and deterministic UUIDs
# derived from the topology system. This provides higher-fidelity fixtures
# than the directory-based mock fixtures in fixture-factory.sh.
#
# Usage:
#   source tools/tests/efi-state/loopback-fixtures.sh
#   create_loopback_fixture "$TEST_ID" "dual-slot"
#   # ... run tests against real block devices ...
#   destroy_loopback_fixture
#
# Dependencies:
#   - topology.sh (deterministic UUID/PARTUUID generation)
#   - fixture-factory.sh (populate_mock_grub_cfg, populate_mock_grubx64_efi)
#
# Design constraints:
#   - All cleanup registered BEFORE losetup/mount (exception-safe)
#   - Deterministic PARTUUIDs and filesystem UUIDs from topology.sh
#   - Support single-slot (Build) and dual-slot topologies
#   - Private mount namespace isolation via unshare
#   - Parent harness cleanup integration
#   - Idempotent teardown functions

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "loopback-fixtures.sh is a library — source it, don't run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Guard: ensure required libraries are loaded
# ---------------------------------------------------------------------------
if ! declare -f generate_deterministic_uuid >/dev/null 2>&1; then
  echo "ERROR: loopback-fixtures.sh requires topology.sh (source it first)." >&2
  # shellcheck disable=SC2317  # return/exit fallback: works sourced (return) or executed directly (exit)
  return 1 2>/dev/null || exit 1
fi

if ! declare -f populate_mock_grub_cfg >/dev/null 2>&1; then
  echo "ERROR: loopback-fixtures.sh requires fixture-factory.sh (source it first)." >&2
  # shellcheck disable=SC2317  # return/exit fallback: works sourced (return) or executed directly (exit)
  return 1 2>/dev/null || exit 1
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # reserved for future use; total size is computed dynamically
LOOPBACK_IMAGE_SIZE_MB=128
LOOPBACK_SECTOR_SIZE=512

# Partition sizes in MiB
LOOPBACK_ESP_SIZE_MB=8
LOOPBACK_EFI_SIZE_MB=8
LOOPBACK_ROOTFS_SIZE_MB=32
LOOPBACK_VAR_SIZE_MB=32

# Mount base directory — all mounts go under MOUNT_BASE/$TEST_ID/
LOOPBACK_MOUNT_BASE="${TMPDIR:-/tmp}/loopback-fixture"

# Default kernel version for rootfs boot content
LOOPBACK_KERNEL_VERSION="6.1.52-neptune-61"

# ============================================================================
# Global state
# ============================================================================
LOOPBACK_IMAGE_PATH=""
LOOPBACK_LOOP_DEVICE=""
LOOPBACK_TEST_ID=""
LOOPBACK_TOPOLOGY=""
LOOPBACK_MOUNT_BASE=""
LOOPBACK_IS_PRIVATE_NS=0

# Registry of mount points and loop devices for cleanup
_LOOPBACK_MOUNT_POINTS=()
_LOOPBACK_LOOP_DEVICES=()
_LOOPBACK_IMAGE_PATHS=()
_LOOPBACK_CREATED_DIRS=()

# ============================================================================
# loopback_check_prerequisites
#
# Verify that all required tools are available for loopback fixture creation.
#
# Checks for:
#   - losetup     (loop device management)
#   - sfdisk      (GPT partitioning)
#   - mkfs.vfat   (EFI/ESP filesystem creation)
#   - mkfs.btrfs  (rootfs/var filesystem creation)
#   - blkid       (filesystem UUID query)
#   - root        (required for losetup/mount)
#
# Returns:
#   0 - All prerequisites satisfied
#   1 - One or more prerequisites missing
# ============================================================================
loopback_check_prerequisites() {
  local rc=0
  local -a missing=()

  # Check for required commands
  local cmd
  for cmd in losetup sfdisk mkfs.vfat mkfs.btrfs blkid; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
      rc=1
    fi
  done

  # Check for root privileges
  if [[ $EUID -ne 0 ]]; then
    # Not fatal — some operations may work without root in certain
    # environments (e.g. fakeroot, user namespaces). Record warning.
    echo "WARNING: loopback_check_prerequisites: not running as root (some operations may fail)" >&2
  fi

  if [[ "$rc" -ne 0 ]]; then
    echo "ERROR: loopback_check_prerequisites: missing commands: ${missing[*]}" >&2
    return 1
  fi

  return 0
}

# ============================================================================
# Internal: _loopback_register_cleanup
#
# Register a cleanup handler. Cleanup handlers are called in reverse
# registration order during destroy_loopback_fixture.
# ============================================================================
_loopback_register_cleanup() {
  local handler="${1:?_loopback_register_cleanup: missing handler}"
  if declare -f "$handler" >/dev/null 2>&1; then
    _LOOPBACK_CLEANUP_HANDLERS+=("$handler")
  fi
}

# ============================================================================
# Internal: _loopback_run_cleanup
#
# Run all registered cleanup handlers in reverse registration order.
# Safe to call multiple times (idempotent).
# ============================================================================
_LOOPBACK_CLEANUP_HANDLERS=()

_loopback_run_cleanup() {
  local i handler
  for ((i = ${#_LOOPBACK_CLEANUP_HANDLERS[@]} - 1; i >= 0; i--)); do
    handler="${_LOOPBACK_CLEANUP_HANDLERS[$i]}"
    if declare -f "$handler" >/dev/null 2>&1; then
      "$handler" 2>/dev/null || true
    fi
  done
  _LOOPBACK_CLEANUP_HANDLERS=()
}

# ============================================================================
# Internal: _loopback_cleanup_handler_unmount
#
# Cleanup handler: unmount all registered mount points in reverse order.
# ============================================================================
_loopback_cleanup_handler_unmount() {
  local i
  for ((i = ${#_LOOPBACK_MOUNT_POINTS[@]} - 1; i >= 0; i--)); do
    local mp="${_LOOPBACK_MOUNT_POINTS[$i]}"
    if mountpoint -q "$mp" 2>/dev/null; then
      umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
    fi
  done
  _LOOPBACK_MOUNT_POINTS=()
}

# ============================================================================
# Internal: _loopback_cleanup_handler_loop_detach
#
# Cleanup handler: detach all registered loop devices.
# ============================================================================
_loopback_cleanup_handler_loop_detach() {
  local i
  for ((i = ${#_LOOPBACK_LOOP_DEVICES[@]} - 1; i >= 0; i--)); do
    local dev="${_LOOPBACK_LOOP_DEVICES[$i]}"
    if [[ -b "$dev" ]]; then
      losetup -d "$dev" 2>/dev/null || true
    fi
  done
  _LOOPBACK_LOOP_DEVICES=()
}

# ============================================================================
# Internal: _loopback_cleanup_handler_remove_images
#
# Cleanup handler: remove all registered image files.
# ============================================================================
_loopback_cleanup_handler_remove_images() {
  local i
  for ((i = ${#_LOOPBACK_IMAGE_PATHS[@]} - 1; i >= 0; i--)); do
    local img="${_LOOPBACK_IMAGE_PATHS[$i]}"
    if [[ -f "$img" ]]; then
      rm -f "$img" 2>/dev/null || true
    fi
  done
  _LOOPBACK_IMAGE_PATHS=()
}

# ============================================================================
# Internal: _loopback_cleanup_handler_remove_dirs
#
# Cleanup handler: remove all registered directories.
# ============================================================================
_loopback_cleanup_handler_remove_dirs() {
  local i
  for ((i = ${#_LOOPBACK_CREATED_DIRS[@]} - 1; i >= 0; i--)); do
    local dir="${_LOOPBACK_CREATED_DIRS[$i]}"
    if [[ -d "$dir" ]]; then
      rm -rf "$dir" 2>/dev/null || true
    fi
  done
  _LOOPBACK_CREATED_DIRS=()
}

# ============================================================================
# create_loopback_image
#
# Create a sparse GPT image file with the correct partition layout for the
# specified topology.
#
# Usage:
#   create_loopback_image TEST_ID TOPOLOGY_TYPE
#
# Arguments:
#   TEST_ID        - Test identifier for deterministic UUIDs
#   TOPOLOGY_TYPE  - "single-slot" or "dual-slot"
#
# The image is created at LOOPBACK_MOUNT_BASE/<TEST_ID>/image.raw
# and registered for cleanup.
#
# Returns:
#   0 - Image created successfully
#   1 - Image creation failed
# ============================================================================
create_loopback_image() {
  local test_id="${1:?create_loopback_image: missing TEST_ID}"
  local topology_type="${2:?create_loopback_image: missing TOPOLOGY_TYPE}"

  # Determine partition layout based on topology
  local -a partitions=()
  case "$topology_type" in
    single-slot)
      partitions=(esp efi-A rootfs-A var-A)
      ;;
    dual-slot)
      partitions=(esp efi-A rootfs-A var-A efi-B rootfs-B var-B)
      ;;
    *)
      echo "ERROR: create_loopback_image: unknown topology type: $topology_type" >&2
      return 1
      ;;
  esac

  # Create working directory
  local work_dir="$LOOPBACK_MOUNT_BASE/$test_id"
  mkdir -p "$work_dir"
  _LOOPBACK_CREATED_DIRS+=("$work_dir")

  local image_path="$work_dir/image.raw"

  # Calculate total image size (sum of partition sizes + GPT overhead)
  local total_size_mb=0
  local part
  for part in "${partitions[@]}"; do
    case "$part" in
      esp) total_size_mb=$((total_size_mb + LOOPBACK_ESP_SIZE_MB)) ;;
      efi-*) total_size_mb=$((total_size_mb + LOOPBACK_EFI_SIZE_MB)) ;;
      rootfs-*) total_size_mb=$((total_size_mb + LOOPBACK_ROOTFS_SIZE_MB)) ;;
      var-*) total_size_mb=$((total_size_mb + LOOPBACK_VAR_SIZE_MB)) ;;
    esac
  done
  # Add GPT overhead (2 MiB for primary + backup GPT headers)
  total_size_mb=$((total_size_mb + 4))

  # Create sparse image
  if ! dd if=/dev/zero of="$image_path" bs=1M count=0 seek="$total_size_mb" 2>/dev/null; then
    echo "ERROR: create_loopback_image: failed to create sparse image" >&2
    return 1
  fi

  # Register image for cleanup (before any further operations)
  _LOOPBACK_IMAGE_PATHS+=("$image_path")

  # Build sfdisk script to partition the image
  local sfdisk_script=""
  local offset_sectors=2048 # Start after 1 MiB (GPT header area)
  local part_num=1

  for part in "${partitions[@]}"; do
    local size_mb=0
    local part_type=""
    local part_label="$part"

    case "$part" in
      esp)
        size_mb=$LOOPBACK_ESP_SIZE_MB
        part_type="C12A7328-F81F-11D2-BA4B-00A0C93EC93B" # EFI System Partition
        ;;
      efi-*)
        size_mb=$LOOPBACK_EFI_SIZE_MB
        part_type="C12A7328-F81F-11D2-BA4B-00A0C93EC93B" # EFI System Partition
        ;;
      rootfs-*)
        size_mb=$LOOPBACK_ROOTFS_SIZE_MB
        part_type="933AC7E1-2EB4-4F13-B844-0E14E2AEF915" # Linux filesystem
        ;;
      var-*)
        size_mb=$LOOPBACK_VAR_SIZE_MB
        part_type="933AC7E1-2EB4-4F13-B844-0E14E2AEF915" # Linux filesystem
        ;;
    esac

    local size_sectors=$(((size_mb * 1024 * 1024) / LOOPBACK_SECTOR_SIZE))
    local end_sectors=$((offset_sectors + size_sectors - 1))

    # Generate deterministic PARTUUID for sfdisk
    local partuuid
    partuuid="$(generate_deterministic_partuuid "$test_id" "$part")"

    sfdisk_script+="${offset_sectors},${size_sectors},T=${part_type},L=${part_label},UUID=${partuuid}
"
    offset_sectors=$((end_sectors + 1))
    part_num=$((part_num + 1))
  done

  # Apply partition table
  if ! printf '%s' "$sfdisk_script" | sfdisk --quiet --no-reread "$image_path" >/dev/null 2>&1; then
    echo "ERROR: create_loopback_image: sfdisk partitioning failed" >&2
    return 1
  fi

  LOOPBACK_IMAGE_PATH="$image_path"
  return 0
}

# ============================================================================
# attach_loopback_image
#
# Attach the image to a loop device with partition scanning.
#
# Usage:
#   attach_loopback_image [IMAGE_PATH]
#
# Arguments:
#   IMAGE_PATH - Path to the image file (default: LOOPBACK_IMAGE_PATH)
#
# Uses losetup -fP to find the next free loop device and scan partitions.
# Registers the loop device for cleanup.
#
# Sets LOOPBACK_LOOP_DEVICE to the allocated loop device path.
#
# Returns:
#   0 - Loop device attached successfully
#   1 - Attachment failed
# ============================================================================
# shellcheck disable=SC2120  # attach_loopback_image takes an optional argument with a default
attach_loopback_image() {
  local image_path="${1:-$LOOPBACK_IMAGE_PATH}"

  if [[ -z "$image_path" || ! -f "$image_path" ]]; then
    echo "ERROR: attach_loopback_image: image not found: $image_path" >&2
    return 1
  fi

  # Find next available loop device
  local loop_dev
  loop_dev="$(losetup -f)" 2>/dev/null
  if [[ -z "$loop_dev" ]]; then
    echo "ERROR: attach_loopback_image: no free loop device available" >&2
    return 1
  fi

  # Attach with partition scanning
  if ! losetup -fP "$image_path" 2>/dev/null; then
    echo "ERROR: attach_loopback_image: losetup failed for $image_path" >&2
    return 1
  fi

  # Verify attachment
  loop_dev="$(losetup -j "$image_path" 2>/dev/null | head -1 | cut -d: -f1)"
  if [[ -z "$loop_dev" || ! -b "$loop_dev" ]]; then
    echo "ERROR: attach_loopback_image: loop device not found after attach" >&2
    return 1
  fi

  # Register for cleanup BEFORE proceeding
  _LOOPBACK_LOOP_DEVICES+=("$loop_dev")

  # Wait for partition devices to appear
  local wait_count=0
  local max_wait=50
  while [[ $wait_count -lt $max_wait ]]; do
    # Check if any partition devices exist
    if ls "${loop_dev}"* >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
    wait_count=$((wait_count + 1))
  done

  LOOPBACK_LOOP_DEVICE="$loop_dev"
  return 0
}

# ============================================================================
# detach_loopback_image
#
# Detach the loop device, unmounting any mounted partitions first.
#
# Usage:
#   detach_loopback_image [LOOP_DEVICE]
#
# Arguments:
#   LOOP_DEVICE - Loop device to detach (default: LOOPBACK_LOOP_DEVICE)
#
# Returns:
#   0 - Loop device detached successfully
#   1 - Detach failed (best-effort)
# ============================================================================
detach_loopback_image() {
  local loop_dev="${1:-$LOOPBACK_LOOP_DEVICE}"

  if [[ -z "$loop_dev" ]]; then
    return 0
  fi

  # Unmount any partitions on this loop device
  if [[ -b "$loop_dev" ]]; then
    local part_dev
    for part_dev in "${loop_dev}"*; do
      if [[ -b "$part_dev" && "$part_dev" != "$loop_dev" ]]; then
        umount "$part_dev" 2>/dev/null || umount -l "$part_dev" 2>/dev/null || true
      fi
    done
  fi

  # Detach loop device
  if [[ -b "$loop_dev" ]]; then
    losetup -d "$loop_dev" 2>/dev/null || true
  fi

  return 0
}

# ============================================================================
# format_loopback_partitions
#
# Format all partitions on the loop device with deterministic UUIDs.
#
# Usage:
#   format_loopback_partitions TEST_ID TOPOLOGY_TYPE [LOOP_DEVICE]
#
# Arguments:
#   TEST_ID        - Test identifier for deterministic UUIDs
#   TOPOLOGY_TYPE  - "single-slot" or "dual-slot"
#   LOOP_DEVICE    - Loop device (default: LOOPBACK_LOOP_DEVICE)
#
# Partition formats:
#   esp, efi-*  → vfat (FAT32) with deterministic UUID
#   rootfs-*, var-* → btrfs with deterministic UUID
#
# Returns:
#   0 - All partitions formatted successfully
#   1 - Formatting failed
# ============================================================================
format_loopback_partitions() {
  local test_id="${1:?format_loopback_partitions: missing TEST_ID}"
  local topology_type="${2:?format_loopback_partitions: missing TOPOLOGY_TYPE}"
  local loop_dev="${3:-$LOOPBACK_LOOP_DEVICE}"

  if [[ -z "$loop_dev" || ! -b "$loop_dev" ]]; then
    echo "ERROR: format_loopback_partitions: invalid loop device: $loop_dev" >&2
    return 1
  fi

  # Determine partition list
  local -a partitions=()
  case "$topology_type" in
    single-slot) partitions=(esp efi-A rootfs-A var-A) ;;
    dual-slot) partitions=(esp efi-A rootfs-A var-A efi-B rootfs-B var-B) ;;
    *)
      echo "ERROR: format_loopback_partitions: unknown topology: $topology_type" >&2
      return 1
      ;;
  esac

  local rc=0
  local part_num=1
  local part
  for part in "${partitions[@]}"; do
    local part_dev="${loop_dev}p${part_num}"
    if [[ ! -b "$part_dev" ]]; then
      echo "ERROR: format_loopback_partitions: partition device not found: $part_dev" >&2
      rc=1
      part_num=$((part_num + 1))
      continue
    fi

    # Get deterministic filesystem UUID from topology
    local fs_uuid
    fs_uuid="$(generate_deterministic_uuid "$test_id" "$part")"

    case "$part" in
      esp | efi-*)
        # Format as FAT32 with deterministic volume ID
        # Convert UUID to FAT32 volume ID (32-bit, use first 8 hex chars)
        local vol_id="${fs_uuid//-/}"
        vol_id="${vol_id:0:8}"
        if ! mkfs.vfat -F 32 -i "$vol_id" -n "${part^^}" "$part_dev" >/dev/null 2>&1; then
          echo "ERROR: format_loopback_partitions: mkfs.vfat failed for $part" >&2
          rc=1
        fi
        ;;
      rootfs-* | var-*)
        # Format as btrfs with deterministic UUID
        if ! mkfs.btrfs -f -U "$fs_uuid" -L "$part" "$part_dev" >/dev/null 2>&1; then
          echo "ERROR: format_loopback_partitions: mkfs.btrfs failed for $part" >&2
          rc=1
        fi
        ;;
    esac

    part_num=$((part_num + 1))
  done

  return $rc
}

# ============================================================================
# mount_loopback_partitions
#
# Mount all partitions under MOUNT_BASE/<TEST_ID>/.
#
# Usage:
#   mount_loopback_partitions TEST_ID TOPOLOGY_TYPE [LOOP_DEVICE]
#
# Arguments:
#   TEST_ID        - Test identifier
#   TOPOLOGY_TYPE  - "single-slot" or "dual-slot"
#   LOOP_DEVICE    - Loop device (default: LOOPBACK_LOOP_DEVICE)
#
# Mount layout:
#   MOUNT_BASE/<TEST_ID>/esp     ← esp partition
#   MOUNT_BASE/<TEST_ID>/efi-A   ← efi-A partition
#   MOUNT_BASE/<TEST_ID>/rootfs-A ← rootfs-A partition
#   MOUNT_BASE/<TEST_ID>/var-A   ← var-A partition (mounted under rootfs-A/var)
#   ... (similarly for B partitions)
#
# All mount points are registered for cleanup.
#
# Returns:
#   0 - All partitions mounted successfully
#   1 - Mounting failed
# ============================================================================
mount_loopback_partitions() {
  local test_id="${1:?mount_loopback_partitions: missing TEST_ID}"
  local topology_type="${2:?mount_loopback_partitions: missing TOPOLOGY_TYPE}"
  local loop_dev="${3:-$LOOPBACK_LOOP_DEVICE}"

  if [[ -z "$loop_dev" || ! -b "$loop_dev" ]]; then
    echo "ERROR: mount_loopback_partitions: invalid loop device: $loop_dev" >&2
    return 1
  fi

  # Determine partition list
  local -a partitions=()
  case "$topology_type" in
    single-slot) partitions=(esp efi-A rootfs-A var-A) ;;
    dual-slot) partitions=(esp efi-A rootfs-A var-A efi-B rootfs-B var-B) ;;
    *)
      echo "ERROR: mount_loopback_partitions: unknown topology: $topology_type" >&2
      return 1
      ;;
  esac

  # Create mount base
  local mount_base="$LOOPBACK_MOUNT_BASE/$test_id"
  mkdir -p "$mount_base"

  local rc=0
  local part_num=1
  local part
  for part in "${partitions[@]}"; do
    local part_dev="${loop_dev}p${part_num}"
    if [[ ! -b "$part_dev" ]]; then
      echo "ERROR: mount_loopback_partitions: partition device not found: $part_dev" >&2
      rc=1
      part_num=$((part_num + 1))
      continue
    fi

    local mount_point="$mount_base/$part"
    mkdir -p "$mount_point"

    # Determine mount options based on partition type
    local mount_opts=""
    case "$part" in
      esp | efi-*)
        mount_opts="-o rw,uid=0,gid=0,umask=0077"
        ;;
      rootfs-* | var-*)
        mount_opts="-o rw"
        ;;
    esac

    # Register mount point for cleanup BEFORE mounting
    _LOOPBACK_MOUNT_POINTS+=("$mount_point")

    # Mount the partition
    # shellcheck disable=SC2086
    if ! mount $mount_opts "$part_dev" "$mount_point" 2>/dev/null; then
      echo "ERROR: mount_loopback_partitions: mount failed for $part ($part_dev → $mount_point)" >&2
      rc=1
    fi

    part_num=$((part_num + 1))
  done

  # For var-A and var-B, if rootfs is also mounted, create symlinks
  # so that rootfs/var resolves to the var partition mount
  if mountpoint -q "$mount_base/rootfs-A" 2>/dev/null \
    && mountpoint -q "$mount_base/var-A" 2>/dev/null; then
    # Bind-mount var-A into rootfs-A/var
    if ! mount --bind "$mount_base/var-A" "$mount_base/rootfs-A/var" 2>/dev/null; then
      echo "WARNING: mount_loopback_partitions: bind mount var-A into rootfs-A/var failed" >&2
    else
      _LOOPBACK_MOUNT_POINTS+=("$mount_base/rootfs-A/var")
    fi
  fi

  if [[ "$topology_type" == "dual-slot" ]]; then
    if mountpoint -q "$mount_base/rootfs-B" 2>/dev/null \
      && mountpoint -q "$mount_base/var-B" 2>/dev/null; then
      if ! mount --bind "$mount_base/var-B" "$mount_base/rootfs-B/var" 2>/dev/null; then
        echo "WARNING: mount_loopback_partitions: bind mount var-B into rootfs-B/var failed" >&2
      else
        _LOOPBACK_MOUNT_POINTS+=("$mount_base/rootfs-B/var")
      fi
    fi
  fi

  LOOPBACK_MOUNT_BASE="$mount_base"
  return $rc
}

# ============================================================================
# unmount_loopback_partitions
#
# Unmount all partitions in reverse order (deepest first).
#
# Usage:
#   unmount_loopback_partitions [TEST_ID]
#
# Arguments:
#   TEST_ID - Test identifier (default: LOOPBACK_TEST_ID)
#
# Returns:
#   0 - All partitions unmounted successfully
#   1 - Some unmounts failed (best-effort)
# ============================================================================
unmount_loopback_partitions() {
  local test_id="${1:-$LOOPBACK_TEST_ID}"

  if [[ -z "$test_id" ]]; then
    echo "WARNING: unmount_loopback_partitions: no test ID" >&2
    return 0
  fi

  local mount_base="$LOOPBACK_MOUNT_BASE/$test_id"
  if [[ ! -d "$mount_base" ]]; then
    return 0
  fi

  local rc=0

  # Unmount in reverse order (var before rootfs, etc.)
  # First unmount bind mounts (rootfs-A/var, rootfs-B/var)
  local -a bind_targets=()
  if [[ -d "$mount_base/rootfs-A/var" ]] && mountpoint -q "$mount_base/rootfs-A/var" 2>/dev/null; then
    bind_targets+=("$mount_base/rootfs-A/var")
  fi
  if [[ -d "$mount_base/rootfs-B/var" ]] && mountpoint -q "$mount_base/rootfs-B/var" 2>/dev/null; then
    bind_targets+=("$mount_base/rootfs-B/var")
  fi

  local target
  for target in "${bind_targets[@]}"; do
    umount "$target" 2>/dev/null || umount -l "$target" 2>/dev/null || {
      rc=1
      true
    }
  done

  # Now unmount regular mounts in reverse order
  local -a regular_mounts=()
  if mountpoint -q "$mount_base/var-B" 2>/dev/null; then
    regular_mounts+=("$mount_base/var-B")
  fi
  if mountpoint -q "$mount_base/rootfs-B" 2>/dev/null; then
    regular_mounts+=("$mount_base/rootfs-B")
  fi
  if mountpoint -q "$mount_base/efi-B" 2>/dev/null; then
    regular_mounts+=("$mount_base/efi-B")
  fi
  if mountpoint -q "$mount_base/var-A" 2>/dev/null; then
    regular_mounts+=("$mount_base/var-A")
  fi
  if mountpoint -q "$mount_base/rootfs-A" 2>/dev/null; then
    regular_mounts+=("$mount_base/rootfs-A")
  fi
  if mountpoint -q "$mount_base/efi-A" 2>/dev/null; then
    regular_mounts+=("$mount_base/efi-A")
  fi
  if mountpoint -q "$mount_base/esp" 2>/dev/null; then
    regular_mounts+=("$mount_base/esp")
  fi

  for target in "${regular_mounts[@]}"; do
    umount "$target" 2>/dev/null || umount -l "$target" 2>/dev/null || {
      rc=1
      true
    }
  done

  # Clear the mount point registry
  _LOOPBACK_MOUNT_POINTS=()

  return $rc
}

# ============================================================================
# populate_loopback_esp
#
# Create bootconf files (A.conf, B.conf) on the ESP partition.
#
# Usage:
#   populate_loopback_esp TEST_ID TOPOLOGY_TYPE
#
# Arguments:
#   TEST_ID        - Test identifier
#   TOPOLOGY_TYPE  - "single-slot" or "dual-slot"
#
# Creates:
#   esp/SteamOS/conf/A.conf  (always present)
#   esp/SteamOS/conf/B.conf  (only for dual-slot)
#
# Returns:
#   0 - ESP populated successfully
#   1 - Population failed
# ============================================================================
populate_loopback_esp() {
  local test_id="${1:?populate_loopback_esp: missing TEST_ID}"
  local topology_type="${2:?populate_loopback_esp: missing TOPOLOGY_TYPE}"

  local esp_dir="$LOOPBACK_MOUNT_BASE/$test_id/esp"
  if [[ ! -d "$esp_dir" ]]; then
    echo "ERROR: populate_loopback_esp: ESP directory not mounted: $esp_dir" >&2
    return 1
  fi

  local conf_dir="$esp_dir/SteamOS/conf"
  mkdir -p "$conf_dir"

  # Create A.conf (always present)
  cat >"$conf_dir/A.conf" <<BOOTCONF_A_EOF
# Bootconf for slot A
title=SteamOS (slot A)
image-invalid=0
boot-attempts=0
BOOTCONF_A_EOF

  # Create B.conf (only for dual-slot)
  if [[ "$topology_type" == "dual-slot" ]]; then
    cat >"$conf_dir/B.conf" <<BOOTCONF_B_EOF
# Bootconf for slot B
title=SteamOS (slot B)
image-invalid=1
boot-attempts=0
BOOTCONF_B_EOF
  fi

  return 0
}

# ============================================================================
# populate_loopback_efi
#
# Create EFI partition content: grub.cfg, grubx64.efi, and partset files.
#
# Usage:
#   populate_loopback_efi TEST_ID TOPOLOGY_TYPE SLOT [TARGET_SLOT]
#
# Arguments:
#   TEST_ID        - Test identifier
#   TOPOLOGY_TYPE  - "single-slot" or "dual-slot"
#   SLOT           - Which EFI partition to populate ("A" or "B")
#   TARGET_SLOT    - Optional target slot for UUID embedding (defaults to SLOT)
#
# Creates for the specified slot's EFI partition:
#   efi-<SLOT>/EFI/steamos/grub.cfg
#   efi-<SLOT>/EFI/steamos/grubx64.efi
#   efi-<SLOT>/SteamOS/partsets/A, B, self, other, all, shared
#
# Returns:
#   0 - EFI partition populated successfully
#   1 - Population failed
# ============================================================================
populate_loopback_efi() {
  local test_id="${1:?populate_loopback_efi: missing TEST_ID}"
  local topology_type="${2:?populate_loopback_efi: missing TOPOLOGY_TYPE}"
  local slot="${3:?populate_loopback_efi: missing SLOT}"
  local target_slot="${4:-$slot}"

  local efi_dir="$LOOPBACK_MOUNT_BASE/$test_id/efi-${slot}"
  if [[ ! -d "$efi_dir" ]]; then
    echo "ERROR: populate_loopback_efi: EFI directory not mounted: $efi_dir" >&2
    return 1
  fi

  # Determine the rootfs UUID for grub.cfg (use target slot's rootfs UUID)
  local rootfs_uuid
  rootfs_uuid="$(generate_deterministic_uuid "$test_id" "rootfs-${target_slot}")"

  # Create directory structure
  mkdir -p "$efi_dir/EFI/steamos"
  mkdir -p "$efi_dir/SteamOS/partsets"

  # Generate grub.cfg
  populate_mock_grub_cfg "$efi_dir/EFI/steamos/grub.cfg" "$rootfs_uuid"

  # Generate grubx64.efi with embedded UUID
  populate_mock_grubx64_efi "$efi_dir/EFI/steamos/grubx64.efi" "$rootfs_uuid"

  # Generate partset files
  local -a slot_list=()
  case "$topology_type" in
    single-slot) slot_list=(A) ;;
    dual-slot) slot_list=(A B) ;;
  esac

  # Per-slot partsets (A and/or B)
  local s
  for s in "${slot_list[@]}"; do
    local rootfs_partuuid efi_partuuid var_partuuid
    rootfs_partuuid="$(generate_deterministic_partuuid "$test_id" "rootfs-${s}")"
    efi_partuuid="$(generate_deterministic_partuuid "$test_id" "efi-${s}")"
    var_partuuid="$(generate_deterministic_partuuid "$test_id" "var-${s}")"

    cat >"$efi_dir/SteamOS/partsets/$s" <<PARTSET_SLOT_EOF
rootfs ${rootfs_partuuid}
efi ${efi_partuuid}
var ${var_partuuid}
PARTSET_SLOT_EOF
  done

  # Semantic partsets (self, other, all, shared)
  local slot_count
  if [[ "$topology_type" == "dual-slot" ]]; then
    slot_count=2
  else
    slot_count=1
  fi
  create_mock_partset_semantics "$efi_dir" "$test_id" "$target_slot" "$slot_count"

  return 0
}

# ============================================================================
# populate_loopback_rootfs
#
# Create rootfs content: kernel, initramfs, GRUB configs, os-release.
#
# Usage:
#   populate_loopback_rootfs TEST_ID SLOT [KERNEL_VERSION]
#
# Arguments:
#   TEST_ID         - Test identifier
#   SLOT            - Which rootfs to populate ("A" or "B")
#   KERNEL_VERSION  - Kernel version string (default: LOOPBACK_KERNEL_VERSION)
#
# Creates:
#   rootfs-<SLOT>/boot/vmlinuz-<KV>
#   rootfs-<SLOT>/boot/initramfs-<KV>.img
#   rootfs-<SLOT>/boot/amd-ucode.img
#   rootfs-<SLOT>/etc/default/grub
#   rootfs-<SLOT>/etc/default/grub-steamos
#   rootfs-<SLOT>/usr/lib/os-release
#   rootfs-<SLOT>/etc/os-release (symlink)
#
# Returns:
#   0 - Rootfs populated successfully
#   1 - Population failed
# ============================================================================
populate_loopback_rootfs() {
  local test_id="${1:?populate_loopback_rootfs: missing TEST_ID}"
  local slot="${2:?populate_loopback_rootfs: missing SLOT}"
  local kernel_version="${3:-$LOOPBACK_KERNEL_VERSION}"

  local rootfs_dir="$LOOPBACK_MOUNT_BASE/$test_id/rootfs-${slot}"
  if [[ ! -d "$rootfs_dir" ]]; then
    echo "ERROR: populate_loopback_rootfs: rootfs directory not mounted: $rootfs_dir" >&2
    return 1
  fi

  # Use the create_mock_rootfs function from fixture-factory.sh
  # but with our deterministic UUID
  local rootfs_uuid
  rootfs_uuid="$(generate_deterministic_uuid "$test_id" "rootfs-${slot}")"

  create_mock_rootfs "$rootfs_dir" "$rootfs_uuid" "$kernel_version"

  return 0
}

# ============================================================================
# create_loopback_fixture
#
# High-level orchestrator: create a complete loopback fixture with real
# GPT image, filesystems, and populated content.
#
# Usage:
#   create_loopback_fixture TEST_ID TOPOLOGY_TYPE [TARGET_SLOT]
#
# Arguments:
#   TEST_ID        - Test identifier for deterministic UUIDs
#   TOPOLOGY_TYPE  - "single-slot" or "dual-slot"
#   TARGET_SLOT    - Target slot (default: "A" for single-slot, "B" for dual-slot)
#
# Performs:
#   1. Check prerequisites
#   2. Register cleanup handlers (BEFORE any resource creation)
#   3. Create sparse GPT image
#   4. Attach loop device
#   5. Format partitions with deterministic UUIDs
#   6. Mount partitions
#   7. Populate ESP, EFI, and rootfs content
#
# Sets global variables:
#   LOOPBACK_IMAGE_PATH  - Path to the image file
#   LOOPBACK_LOOP_DEVICE - Loop device path
#   LOOPBACK_TEST_ID     - Test identifier
#   LOOPBACK_TOPOLOGY    - Topology type
#   LOOPBACK_MOUNT_BASE  - Mount base directory
#
# Returns:
#   0 - Fixture created successfully
#   1 - Fixture creation failed
# ============================================================================
create_loopback_fixture() {
  local test_id="${1:?create_loopback_fixture: missing TEST_ID}"
  local topology_type="${2:?create_loopback_fixture: missing TOPOLOGY_TYPE}"
  local target_slot="${3:-}"

  # Determine default target slot
  if [[ -z "$target_slot" ]]; then
    case "$topology_type" in
      single-slot) target_slot="A" ;;
      dual-slot) target_slot="B" ;;
    esac
  fi

  # Check prerequisites
  if ! loopback_check_prerequisites; then
    return 1
  fi

  # Reset state
  _LOOPBACK_MOUNT_POINTS=()
  _LOOPBACK_LOOP_DEVICES=()
  _LOOPBACK_IMAGE_PATHS=()
  _LOOPBACK_CREATED_DIRS=()
  _LOOPBACK_CLEANUP_HANDLERS=()

  # Register cleanup handlers FIRST (before any resource creation)
  # Order matters: handlers run in reverse, so register in dependency order
  _loopback_register_cleanup "_loopback_cleanup_handler_unmount"
  _loopback_register_cleanup "_loopback_cleanup_handler_loop_detach"
  _loopback_register_cleanup "_loopback_cleanup_handler_remove_images"
  _loopback_register_cleanup "_loopback_cleanup_handler_remove_dirs"

  # Set global state
  LOOPBACK_TEST_ID="$test_id"
  # shellcheck disable=SC2034  # LOOPBACK_TOPOLOGY is part of the public API (read by consumers)
  LOOPBACK_TOPOLOGY="$topology_type"

  # 1. Create sparse GPT image
  if ! create_loopback_image "$test_id" "$topology_type"; then
    echo "ERROR: create_loopback_fixture: image creation failed" >&2
    _loopback_run_cleanup
    return 1
  fi

  # 2. Attach loop device
  # shellcheck disable=SC2119  # attach_loopback_image intentionally uses default (LOOPBACK_IMAGE_PATH)
  if ! attach_loopback_image; then
    echo "ERROR: create_loopback_fixture: loop device attachment failed" >&2
    _loopback_run_cleanup
    return 1
  fi

  # 3. Format partitions with deterministic UUIDs
  if ! format_loopback_partitions "$test_id" "$topology_type"; then
    echo "ERROR: create_loopback_fixture: partition formatting failed" >&2
    _loopback_run_cleanup
    return 1
  fi

  # 4. Mount partitions
  if ! mount_loopback_partitions "$test_id" "$topology_type"; then
    echo "ERROR: create_loopback_fixture: partition mounting failed" >&2
    _loopback_run_cleanup
    return 1
  fi

  # 5. Populate ESP (bootconf files)
  if ! populate_loopback_esp "$test_id" "$topology_type"; then
    echo "ERROR: create_loopback_fixture: ESP population failed" >&2
    _loopback_run_cleanup
    return 1
  fi

  # 6. Populate EFI partitions
  if ! populate_loopback_efi "$test_id" "$topology_type" "A" "$target_slot"; then
    echo "ERROR: create_loopback_fixture: EFI-A population failed" >&2
    _loopback_run_cleanup
    return 1
  fi

  if [[ "$topology_type" == "dual-slot" ]]; then
    if ! populate_loopback_efi "$test_id" "$topology_type" "B" "$target_slot"; then
      echo "ERROR: create_loopback_fixture: EFI-B population failed" >&2
      _loopback_run_cleanup
      return 1
    fi
  fi

  # 7. Populate rootfs partitions
  if ! populate_loopback_rootfs "$test_id" "A"; then
    echo "ERROR: create_loopback_fixture: rootfs-A population failed" >&2
    _loopback_run_cleanup
    return 1
  fi

  if [[ "$topology_type" == "dual-slot" ]]; then
    if ! populate_loopback_rootfs "$test_id" "B"; then
      echo "ERROR: create_loopback_fixture: rootfs-B population failed" >&2
      _loopback_run_cleanup
      return 1
    fi
  fi

  return 0
}

# ============================================================================
# destroy_loopback_fixture
#
# High-level cleanup: unmount, detach, remove image, remove directories.
#
# Usage:
#   destroy_loopback_fixture [TEST_ID]
#
# Arguments:
#   TEST_ID - Test identifier (default: LOOPBACK_TEST_ID)
#
# This function is idempotent — safe to call multiple times.
# Designed to be used as a cleanup handler or trap target.
#
# Returns:
#   0 - Cleanup completed (best-effort)
# ============================================================================
destroy_loopback_fixture() {
  local test_id="${1:-$LOOPBACK_TEST_ID}"

  # Run all registered cleanup handlers in reverse order
  _loopback_run_cleanup

  # Reset global state
  LOOPBACK_IMAGE_PATH=""
  LOOPBACK_LOOP_DEVICE=""
  LOOPBACK_TEST_ID=""
  # shellcheck disable=SC2034  # LOOPBACK_TOPOLOGY is part of the public API (set in create_loopback_fixture)
  LOOPBACK_TOPOLOGY=""
  LOOPBACK_MOUNT_BASE=""
  # shellcheck disable=SC2034  # LOOPBACK_IS_PRIVATE_NS is part of the public API (set in enter_private_mount_namespace)
  LOOPBACK_IS_PRIVATE_NS=0

  return 0
}

# ============================================================================
# enter_private_mount_namespace
#
# Enter a private mount namespace using unshare. This isolates mount
# operations from the parent process, preventing test mounts from
# leaking into the host system.
#
# Usage:
#   enter_private_mount_namespace
#
# After calling this function, all mount/unmount operations are confined
# to the new namespace and will not affect the parent's mount table.
#
# The function sets LOOPBACK_IS_PRIVATE_NS=1 to indicate that the
# current process is running in a private mount namespace.
#
# Returns:
#   0 - Entered private mount namespace successfully
#   1 - Failed to enter private mount namespace
#
# Note: This function calls exec to replace the current process.
#       It does not return on success.
# ============================================================================
enter_private_mount_namespace() {
  if ! command -v unshare >/dev/null 2>&1; then
    echo "ERROR: enter_private_mount_namespace: unshare not found" >&2
    return 1
  fi

  # Verify that unshare supports mount namespace
  if ! unshare --mount --propagation private echo test >/dev/null 2>&1; then
    echo "ERROR: enter_private_mount_namespace: unshare --mount not supported" >&2
    return 1
  fi

  # shellcheck disable=SC2034  # LOOPBACK_IS_PRIVATE_NS is part of the public API (read by consumers)
  LOOPBACK_IS_PRIVATE_NS=1

  # Replace current process with one in a new mount namespace
  # The shell re-executes itself inside the namespace
  exec unshare --mount --propagation private "$0" "$@"
}
