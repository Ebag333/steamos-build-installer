#!/bin/bash
#
# Build, validate, and clean up test images for all branch configs.
# Usage: ./tools/tests/bin/run-tests.sh /path/to/steamdeck-repair.img
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONF_DIR="$SCRIPT_DIR/.."
OUTPUT_DIR="$SCRIPT_DIR/../output"
STEAMOS_BUILD="$PROJECT_DIR/steamos-build.sh"

mkdir -p "$OUTPUT_DIR"

echo "Starting test run..."

# ── Clean up stale build state ────────────────────────────────────────────
# /dev/shm/steamos-build may contain root-owned mounts/loop devices from
# previous (possibly killed) builds.  Mirrors the cleanup order from
# lib/overlay.sh overlay_cleanup() and lib/common.sh cleanup().
cleanup_stale_state() {
  local workdir="/dev/shm/steamos-build"
  [[ -d "$workdir" ]] || return 0

  echo "Cleaning up stale build state: $workdir"

  local merged="$workdir/merged"
  local ovl_mnt="$workdir/overlay-mnt"

  # 1. Kill chroot daemons (gpg-agent holds mounts open)
  if [[ -d "$merged/etc/pacman.d/gnupg" ]]; then
    gpgconf --homedir "$merged/etc/pacman.d/gnupg" --kill gpg-agent 2>/dev/null || true
  fi

  # 2. Unmount tracked mounts from the tracking file (reverse order)
  local mounts_file="$workdir/mounts"
  if [[ -f "$mounts_file" ]]; then
    tac "$mounts_file" 2>/dev/null | while IFS= read -r m; do
      [[ -n "$m" ]] || continue
      if mountpoint -q "$m" 2>/dev/null; then
        echo "  Unmounting tracked: $m"
        sudo umount "$m" 2>/dev/null || sudo umount -l "$m" 2>/dev/null || true
      fi
    done
  fi

  # 3. Unmount chroot children inside MERGED (children before parents)
  if [[ -d "$merged" ]]; then
    local m
    for m in \
      "$merged/tmp/pkgcache" \
      "$merged/dev/pts" \
      "$merged/dev/shm" \
      "$merged/dev" \
      "$merged/sys" \
      "$merged/proc" \
      "$merged/tmp"; do
      if mountpoint -q "$m" 2>/dev/null; then
        echo "  Unmounting chroot child: $m"
        sudo umount "$m" 2>/dev/null || sudo umount -l "$m" 2>/dev/null || true
      fi
    done
  fi

  # 4. Unmount MERGED (overlay)
  if mountpoint -q "$merged" 2>/dev/null; then
    echo "  Unmounting overlay: $merged"
    sudo umount "$merged" 2>/dev/null || sudo umount -l "$merged" 2>/dev/null || true
  fi

  # 5. Sync before unmounting overlay workspace
  sync 2>/dev/null || true

  # 6. Unmount overlay workspace (OVL_MNT)
  if mountpoint -q "$ovl_mnt" 2>/dev/null; then
    echo "  Unmounting overlay workspace: $ovl_mnt"
    sudo umount "$ovl_mnt" 2>/dev/null || sudo umount -l "$ovl_mnt" 2>/dev/null || true
  fi

  # 7. Unmount main image filesystems (efi, home, mnt)
  local m
  for m in "$workdir/home" "$workdir/efi" "$workdir/mnt"; do
    if mountpoint -q "$m" 2>/dev/null; then
      echo "  Unmounting: $m"
      sudo umount "$m" 2>/dev/null || sudo umount -l "$m" 2>/dev/null || true
    fi
  done

  # 8. Detach loop devices backed by files in the stale workdir.
  #    Must happen BEFORE deleting the backing image files.
  #    Kill jbd2 journal threads that hold ext4 superblocks alive.
  local loop_dev loop_name jbd2_pid local_backing
  while IFS= read -r loop_dev; do
    [[ -n "$loop_dev" ]] || continue
    local_backing="$(losetup "$loop_dev" 2>/dev/null | grep -oP '(?<=\().*(?=\))' || true)"
    if [[ "$local_backing" == *"$workdir"* ]]; then
      echo "  Detaching stale loop: $loop_dev ($local_backing)"
      sudo blockdev --flushbufs "$loop_dev" 2>/dev/null || true
      sudo losetup -d "$loop_dev" 2>/dev/null || true

      # Kill the jbd2 journal thread that holds the ext4 superblock alive.
      loop_name="${loop_dev##/dev/}"
      jbd2_pid="$(pgrep -f "jbd2/${loop_name}-" 2>/dev/null || true)"
      if [[ -n "$jbd2_pid" ]]; then
        echo "  Killing jbd2 thread for $loop_dev (pid $jbd2_pid)"
        sudo kill "$jbd2_pid" 2>/dev/null || true
        sleep 0.5
      fi

      # Wait briefly for the loop to fully detach
      local _i
      for _i in $(seq 1 20); do
        losetup "$loop_dev" >/dev/null 2>&1 || break
        sleep 0.1
      done
    fi
  done < <(losetup -J 2>/dev/null | jq -r '.loopdevices[].name' 2>/dev/null || losetup -a 2>/dev/null | awk -F: '{print $1}')

  # 9. Remove the stale workdir (after loops are detached)
  sudo rm -rf "$workdir"
  echo "  ✓ Stale state cleaned"
}

# Clean up any stale state before starting
cleanup_stale_state

# Load defaults from config file if present
if [[ -f "$SCRIPT_DIR/run-tests.conf" ]]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/run-tests.conf"
fi

if [[ $# -ge 1 ]]; then
  SOURCE_IMG="$(realpath "$1")"
elif [[ -z "${SOURCE_IMG:-}" ]]; then
  echo "Usage: $0 <source-image> [steamos-build.sh]" >&2
  echo "" >&2
  echo "  source-image      Clean SteamOS repair image (.img or compressed)" >&2
  echo "  steamos-build.sh  Path to steamos-build.sh (default: auto-detect)" >&2
  echo "" >&2
  echo "Or set SOURCE_IMG in run-tests.conf." >&2
  exit 1
fi

if [[ ! -f "$SOURCE_IMG" ]]; then
  echo "Source image not found: $SOURCE_IMG" >&2
  exit 1
fi

if [[ $# -ge 2 ]]; then
  STEAMOS_BUILD="$(realpath "$2")"
fi

if [[ ! -x "$STEAMOS_BUILD" ]]; then
  echo "steamos-build.sh not found or not executable: $STEAMOS_BUILD" >&2
  exit 1
fi

# Derive output image naming convention from backend.sh
SOURCE_BASE="$(basename "$SOURCE_IMG")"
SOURCE_BASE="${SOURCE_BASE%.bz2}"
SOURCE_BASE="${SOURCE_BASE%.gz}"
SOURCE_BASE="${SOURCE_BASE%.xz}"
SOURCE_BASE="${SOURCE_BASE%.zst}"
SOURCE_BASE="${SOURCE_BASE%.img}"
OUTPUT_SUFFIX="-nvidia-usbinstall.img"
BUILD_OUTPUT_DIR="$PROJECT_DIR/tools/tests/build"
mkdir -p "$BUILD_OUTPUT_DIR"

passed=0
failed=0
skipped=0

for conf in "$CONF_DIR"/*.conf; do
  [[ -f "$conf" ]] || continue
  [[ "$(basename "$conf")" == "run-tests.conf" ]] && continue

  branch="$(basename "$conf" .conf)"
  branch="${branch#valve-}"

  log_file="$OUTPUT_DIR/${branch}.log"
  json_file="$OUTPUT_DIR/${branch}.json"

  # Derive expected output image path
  out_img="$BUILD_OUTPUT_DIR/${SOURCE_BASE}${OUTPUT_SUFFIX}"

  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "  $branch"
  echo "═══════════════════════════════════════════════════════════"

  # ── Build ──────────────────────────────────────────────────────────────
  echo "  Building... (log: $log_file)"
  if ! sudo "$STEAMOS_BUILD" \
    --action build \
    --image "$SOURCE_IMG" \
    --config "$conf" \
    --output-dir "$BUILD_OUTPUT_DIR" \
    2>&1 | sudo tee "$log_file" >/dev/null; then
    echo "  ✗ BUILD FAILED — see $log_file"
    ((++failed))
    # Clean up stale state left by the failed build before the next test
    cleanup_stale_state
    continue
  fi

  # Verify the output image was actually produced (build may exit 0 on partial failure)
  if [[ ! -f "$out_img" ]]; then
    echo "  ✗ BUILD FAILED — output image not produced (DKMS/driver build error?) — see $log_file"
    ((++failed))
    cleanup_stale_state
    continue
  fi
  echo "  ✓ Build complete"

  # ── Validate ───────────────────────────────────────────────────────────
  echo "  Validating..."
  if [[ -f "$out_img" ]]; then
    echo "  Running: sudo $STEAMOS_BUILD --action validate --image $out_img --config $conf --output $json_file"
    if sudo "$STEAMOS_BUILD" \
      --action validate \
      --image "$out_img" \
      --config "$conf" \
      --output "$json_file" \
      2>&1 | sudo tee -a "$log_file" >/dev/null; then
      echo "  ✓ Validation complete — $json_file"
      ((++passed))
    else
      echo "  ✗ VALIDATION FAILED — see $log_file"
      ((++failed))
    fi

    # ── Cleanup ────────────────────────────────────────────────────────────
    echo "  Cleaning up..."
    rm -f "$BUILD_OUTPUT_DIR/${SOURCE_BASE}${OUTPUT_SUFFIX}"*
    # Also clean up the workdir
    rm -rf "$BUILD_OUTPUT_DIR/.nvidia-usb-work"
    echo "  ✓ Cleaned up"
  else
    echo "  ✗ Output image not found: $out_img"
    ((++failed))
  fi
done

# Clean up any stale state left by the last test
cleanup_stale_state

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Results: $passed passed, $failed failed, $skipped skipped"
echo "═══════════════════════════════════════════════════════════"

[[ $failed -eq 0 ]]
