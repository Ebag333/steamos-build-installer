#!/bin/bash
# steamos-nvidia repatch — reconcile the NVIDIA driver + boot config into
# another partition set (normally "other", right after an OS update).
# Run as root.  Reconciles the configured Valve/Arch package manifests,
# rebuilds target-kernel modules as needed, and always runs
# GRUB/initramfs/gamemode reconciliation.  Logs to stdout
# (the update wrapper redirects).
set -Eeuo pipefail

PERSIST_LOG_DIR="/home/.steamos-nvidia/logs"
mkdir -p "$PERSIST_LOG_DIR"

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RUN_LOG="$PERSIST_LOG_DIR/repatch-$RUN_ID.log"

ln -sfn "$(basename "$RUN_LOG")" \
  "$PERSIST_LOG_DIR/repatch-latest.log"

# Keep stdout/stderr flowing to the caller, but independently retain
# everything on the persistent /home filesystem.
exec > >(tee -a "$RUN_LOG") 2>&1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log()  { echo "[repatch] $*"; }
warn() { echo "[repatch] WARNING: $*" >&2; }

CURRENT_STEP="startup"
FAILURE_REPORTED=0

# May not exist yet if failure happens very early.
NEWROOT=""

step() {
  CURRENT_STEP="$*"
  log "STEP: $CURRENT_STEP"
  logger -t steamos-nvidia-repatch -- "STEP: $CURRENT_STEP" 2>/dev/null || true
}

failure_snapshot() {
  local rc="$1"
  local line="$2"
  local cmd="$3"
  local reason="${4:-}"
  local _slot

  warn "FAILURE"
  warn "  rc:      $rc"
  warn "  step:    ${CURRENT_STEP:-unknown}"
  warn "  line:    $line"
  warn "  command: $cmd"
  [[ -n "$reason" ]] && warn "  reason:  $reason"

  local journal_cmd="${cmd//$'\n'/ }"
  local journal_reason="${reason//$'\n'/ }"

  # Keep the journal headline readable even if BASH_COMMAND is enormous.
  journal_cmd="${journal_cmd:0:300}"
  journal_reason="${journal_reason:0:300}"

  logger -t steamos-nvidia-repatch -- \
    "FAIL rc=$rc step='${CURRENT_STEP:-unknown}' line=$line partset='${PARTSET:-unknown}' kver='${KVER:-unknown}' command='$journal_cmd' reason='${journal_reason:-unspecified}' log='$RUN_LOG'" \
    2>/dev/null || true

  echo
  echo "=== SLOT STATE ==="
  rauc status --detailed 2>&1 || true
  steamos-bootconf list-images 2>&1 || true

  for _slot in A B; do
    echo "--- $_slot ---"
    steamos-bootconf --image "$_slot" config \
      --get boot-attempts \
      --get boot-requested-at \
      --get image-invalid \
      --get comment 2>&1 || true
  done

  echo
  echo "=== MOUNTS ==="
  findmnt 2>&1 || true

  echo
  echo "=== LOOP DEVICES ==="
  losetup -a 2>&1 || true

  echo
  echo "=== SPACE ==="
  df -h /home 2>&1 || true

  if [[ -n "${NEWROOT:-}" ]] && mountpoint -q "$NEWROOT" 2>/dev/null; then
    echo
    echo "=== TARGET ROOTFS ==="
    findmnt "$NEWROOT" 2>&1 || true
    btrfs filesystem usage "$NEWROOT" 2>&1 || true

    if [[ -n "${KVER:-}" ]]; then
      echo
      echo "=== TARGET DRIVER STATE ==="
      chroot "$NEWROOT" dkms status 2>&1 || true
      chroot "$NEWROOT" pacman -Q nvidia-utils 2>&1 || true
    fi
  fi
}

report_failure() {
  local rc="$1"
  local line="$2"
  local cmd="$3"
  local reason="${4:-}"

  # A manually invoked die() might follow a command that returned 0.
  (( rc != 0 )) || rc=1

  # Prevent ERR + die or failures inside diagnostics from producing
  # multiple snapshots.
  if (( FAILURE_REPORTED )); then
    exit "$rc"
  fi
  FAILURE_REPORTED=1

  trap - ERR
  set +e

  failure_snapshot "$rc" "$line" "$cmd" "$reason"
  exit "$rc"
}

on_err() {
  local rc=$?
  local line="${BASH_LINENO[0]:-${LINENO}}"
  local cmd="$BASH_COMMAND"

  report_failure \
    "$rc" \
    "$line" \
    "$cmd" \
    "unhandled command failure"
}

die() {
  # Capture $? immediately so `cmd || die "..."` retains cmd's exit code.
  local rc=$?
  local reason="$*"
  local line="${BASH_LINENO[0]:-${LINENO}}"

  (( rc != 0 )) || rc=1

  report_failure \
    "$rc" \
    "$line" \
    "die: $reason" \
    "$reason"
}

trap on_err ERR

for helper in overlay common_system common_modules common_drivers install-hw-libs grub; do
  [[ -r "$SCRIPT_DIR/$helper.sh" ]]     || die "missing helper: $SCRIPT_DIR/$helper.sh"
done
source "$SCRIPT_DIR/overlay.sh"
source "$SCRIPT_DIR/common_system.sh"
source "$SCRIPT_DIR/common_modules.sh"
source "$SCRIPT_DIR/common_drivers.sh"
source "$SCRIPT_DIR/install-hw-libs.sh"
source "$SCRIPT_DIR/grub.sh"

PARTSET="${1:-other}"

ROOTDEV="/dev/disk/by-partsets/$PARTSET/rootfs"
EFIDEV="/dev/disk/by-partsets/$PARTSET/efi"
[[ -b "$ROOTDEV" && -b "$EFIDEV" ]] || die "partset '$PARTSET' not found (single-slot system?)"

# Capture enough boot/partset state to diagnose SteamOS EFI alias problems
# without making the repatch depend on steamos-bootconf succeeding.
diagnose_boot_layout() {
  local slot kind path resolved mnt info out rc

  log "Boot/partset diagnostics:"
  log "  requested partset: $PARTSET"
  log "  kernel cmdline: $(cat /proc/cmdline 2>/dev/null || echo '<unavailable>')"

  for slot in A B self other; do
    for kind in rootfs efi var; do
      path="/dev/disk/by-partsets/$slot/$kind"
      if [[ -e "$path" || -L "$path" ]]; then
        resolved="$(readlink -f "$path" 2>/dev/null || true)"
        log "  $slot/$kind -> ${resolved:-<unresolved>}"
      else
        log "  $slot/$kind -> <missing>"
      fi
    done
  done

  for mnt in /efi /esp; do
    if mountpoint -q "$mnt" 2>/dev/null; then
      info="$(findmnt -rn -o SOURCE,FSTYPE,OPTIONS,TARGET "$mnt" 2>/dev/null || true)"
      log "  mount $mnt: ${info:-<unknown>}"
    else
      log "  mount $mnt: <not mounted>"
    fi

    if [[ -d "$mnt/SteamOS/partsets" ]]; then
      log "  $mnt/SteamOS/partsets:"
      while IFS= read -r out; do
        log "    $out"
      done < <(ls -la "$mnt/SteamOS/partsets" 2>&1)
    else
      log "  $mnt/SteamOS/partsets: <missing>"
    fi

    if [[ -d "$mnt/SteamOS/conf" ]]; then
      log "  $mnt/SteamOS/conf:"
      while IFS= read -r out; do
        log "    $out"
      done < <(ls -la "$mnt/SteamOS/conf" 2>&1)
    else
      log "  $mnt/SteamOS/conf: <missing>"
    fi
  done

  if command -v steamos-bootconf >/dev/null 2>&1; then
    if out="$(steamos-bootconf this-image 2>&1)"; then
      log "  steamos-bootconf this-image: $out"
    else
      rc=$?
      warn "steamos-bootconf this-image failed (rc=$rc): $out"
    fi

    if out="$(steamos-bootconf list-images 2>&1)"; then
      while IFS= read -r path; do
        log "  steamos-bootconf list-images: $path"
      done <<< "$out"
    else
      rc=$?
      warn "steamos-bootconf list-images failed (rc=$rc): $out"
    fi
  else
    warn "steamos-bootconf not found"
  fi
}

diagnose_boot_state() {
  local slot out rc

  log "SteamOS boot state:"

  for slot in A B; do
    if out="$(steamos-bootconf --image "$slot" config \
        --get boot-attempts \
        --get boot-requested-at \
        --get image-invalid \
        --get comment 2>&1)"; then

      log "  [$slot]"
      while IFS= read -r line; do
        log "    $line"
      done <<< "$out"
    else
      rc=$?
      warn "Could not read boot state for $slot (rc=$rc): $out"
    fi
  done
}

diagnose_boot_layout
diagnose_boot_state

NEWROOT="$(mktemp -d /tmp/repatch-root.XXXXXX)"
# SteamOS /home is ext4 with casefold enabled, which OverlayFS rejects as an
# upperdir.  Build inside a temporary plain-ext4 loopback filesystem stored on
# /home, where there is enough space for DKMS/toolchain work.
WORKIMG=/home/.steamos-nvidia-work.img
WORK="$(mktemp -d /tmp/repatch-work.XXXXXX)"
WORK_LOOPDEV=""

cleanup() {
  local _had_e=0
  [[ -o errexit ]] && _had_e=1
  set +e

  # overlay_cleanup tears down MERGED and its chroot bind mounts.  repatch
  # uses overlay_mount() on our own ext4 workspace, so the workspace itself
  # is deliberately torn down here afterwards.
  overlay_cleanup
  umount_chroot_fs "$NEWROOT"
  if mountpoint -q "$NEWROOT/efi" 2>/dev/null; then
    umount -R "$NEWROOT/efi" 2>/dev/null || umount -Rl "$NEWROOT/efi" 2>/dev/null
  fi

  if mountpoint -q "$WORK" 2>/dev/null; then
    umount "$WORK" 2>/dev/null || umount -l "$WORK" 2>/dev/null
  fi
  if [[ -n "$WORK_LOOPDEV" ]]; then
    losetup -d "$WORK_LOOPDEV" 2>/dev/null || true
    WORK_LOOPDEV=""
  fi

  if mountpoint -q "$NEWROOT" 2>/dev/null; then
    umount -R "$NEWROOT" 2>/dev/null || umount -Rl "$NEWROOT" 2>/dev/null
  fi

  rmdir "$NEWROOT" "$WORK" 2>/dev/null || true
  if [[ -z "$(losetup -j "$WORKIMG" 2>/dev/null)" ]]; then
    rm -f "$WORKIMG"
  else
    warn "workspace image is still attached; leaving $WORKIMG in place"
  fi

  if [[ $_had_e -eq 1 ]]; then
    set -e
  else
    set +e
  fi
}
trap 'set +e; cleanup; set -e' EXIT

step "Mounting $ROOTDEV"
mount -o rw,compress-force=zstd:3 "$ROOTDEV" "$NEWROOT" \
  || die "Could not mount $PARTSET rootfs"

# A freshly staged SteamOS Btrfs image can have the root tree's subvolume-level
# ro property set even while the VFS mount itself reports "rw".  findmnt alone
# therefore cannot prove that the rootfs is writable.
vfs_opts="$(findmnt -no OPTIONS "$NEWROOT" 2>/dev/null || true)"
btrfs_ro="$(btrfs property get -ts "$NEWROOT" ro 2>/dev/null | awk -F= '/^ro=/{print $2}' || true)"
log "Rootfs write state: VFS='${vfs_opts:-<unknown>}' Btrfs-ro='${btrfs_ro:-<unknown>}'"

# Handle a genuinely read-only VFS mount first.
if printf '%s\n' "$vfs_opts" | tr ',' '\n' | grep -qx ro; then
  log "Remounting $PARTSET rootfs rw"
  mount -o remount,rw "$NEWROOT" \
    || die "Could not remount $PARTSET rootfs read-write"
fi

# Handle the independent Btrfs subvolume property.  On the staged Valve image
# we observed subvolid=5 mounted rw while this property was ro=true.
if [[ "$btrfs_ro" == "true" ]]; then
  log "Clearing Btrfs read-only property on staged rootfs"
  btrfs property set -ts "$NEWROOT" ro false \
    || die "Could not clear Btrfs read-only property on $PARTSET rootfs"

  btrfs_ro="$(btrfs property get -ts "$NEWROOT" ro 2>/dev/null | awk -F= '/^ro=/{print $2}' || true)"
  [[ "$btrfs_ro" == "false" ]] \
    || die "Btrfs rootfs still reports ro=${btrfs_ro:-<unknown>} after clearing property"
fi

if ! touch "$NEWROOT/.rw-test"; then
  warn "Rootfs diagnostics after failed write:"
  warn "  mount: $(findmnt -rn -o SOURCE,FSTYPE,OPTIONS,TARGET "$NEWROOT" 2>/dev/null || echo '<unknown>')"
  warn "  blockdev-ro: $(blockdev --getro "$ROOTDEV" 2>/dev/null || echo '<unknown>')"
  warn "  btrfs-ro: $(btrfs property get -ts "$NEWROOT" ro 2>/dev/null || echo '<unknown>')"
  die "$PARTSET rootfs is not writable"
fi
rm -f "$NEWROOT/.rw-test"

# Expand rootfs early — before driver install or anything else that needs
# disk space.  A raw SteamOS update can restore Valve's smaller filesystem
# image inside our larger GPT partition.
log "Checking rootfs size"
part_bytes="$(blockdev --getsize64 "$ROOTDEV" 2>/dev/null || echo 0)"
fs_bytes="$(btrfs filesystem usage -b "$NEWROOT" 2>/dev/null | grep -oP '^\s+Device size:\s+\K[0-9]+' || echo 0)"

(( part_bytes > 0 )) || die "Could not determine rootfs partition size"
(( fs_bytes > 0 ))   || die "Could not determine rootfs filesystem size"
(( fs_bytes <= part_bytes )) \
  || die "rootfs reports larger than its backing partition (${fs_bytes} > ${part_bytes})"

if (( part_bytes > fs_bytes )); then
  log "Expanding rootfs to fill partition (${fs_bytes} → ${part_bytes} bytes)"
  btrfs filesystem resize max "$NEWROOT" \
    || die "rootfs resize failed"

  fs_bytes_after="$(btrfs filesystem usage -b "$NEWROOT" 2>/dev/null | grep -oP '^\s+Device size:\s+\K[0-9]+' || echo 0)"
  log "Rootfs size after resize: ${fs_bytes_after:-<unknown>} bytes"
  (( fs_bytes_after > 0 )) || die "Could not verify rootfs size after resize"
  (( fs_bytes_after >= part_bytes )) \
    || die "rootfs resize did not consume the full partition (${fs_bytes_after} < ${part_bytes})"
else
  log "Rootfs already fills partition"
fi

step "Discovering target kernel"
discover_neptune_kver "$NEWROOT"
log "Target kernel: $KVER"

# Load persisted build selections.  Package source/version policy itself lives
# in the bundled hw-packages-{valve,arch}.conf manifests; "latest" is resolved
# again on every self-heal.
[[ -r /usr/lib/steamos-nvidia/driver.conf ]] \
  || die "driver.conf is missing"
source /usr/lib/steamos-nvidia/driver.conf

: "${INITRAMFS_MODULES:=}"
: "${GAMING_ITEMS:=}"
: "${DEBUG_BOOT:=0}"
: "${HW_SUPPORT_ITEMS:=}"
: "${BUILD_HW_SUPPORT:=0}"
: "${SKIP_SIG:=0}"
: "${FIX_KEYRING:=0}"
: "${EXTRA_CMDLINE_ADD:=}"

# Determine whether the custom Logitech modules need to be rebuilt.
HID_EXPECTED=0
if [[ -n "${HW_SUPPORT_ITEMS:-}" ]]; then
  [[ " ${HW_SUPPORT_ITEMS} " == *" logitech-hid "* ]] && HID_EXPECTED=1
elif [[ "${BUILD_HW_SUPPORT:-0}" -eq 1 ]]; then
  HID_EXPECTED=1
elif [[ -d /home/.driver-packages/hid ]]; then
  # Compatibility with older self-heal state that did not persist
  # BUILD_HW_SUPPORT.
  HID_EXPECTED=1
fi

if (( HID_EXPECTED )); then
  [[ -d /home/.driver-packages/hid ]] \
    || die "logitech-hid selected but HID source bundle is missing"
fi

discover_kernel_pkg "$NEWROOT"
construct_hdr_url "$NEWROOT"
log "Headers: $(basename "$HDR_URL")"
curl -sfIL "$HDR_URL" -o /dev/null \
  || die "matching headers not in Valve's pool: $HDR_URL"

log "Preparing temporary ext4 overlay workspace"
# Recover from an interrupted previous repatch before replacing the fixed
# workspace image path.  Never unlink an image that is still attached/mounted.
while IFS= read -r stale_loop; do
  [[ -n "$stale_loop" ]] || continue
  while IFS= read -r stale_mnt; do
    [[ -n "$stale_mnt" ]] || continue
    umount -R "$stale_mnt" 2>/dev/null \
      || umount -Rl "$stale_mnt" 2>/dev/null \
      || true
  done < <(findmnt -rn -o TARGET -S "$stale_loop" 2>/dev/null)
  losetup -d "$stale_loop" 2>/dev/null || true
done < <(losetup -j "$WORKIMG" 2>/dev/null | cut -d: -f1)

[[ -z "$(losetup -j "$WORKIMG" 2>/dev/null)" ]] \
  || die "stale repatch workspace is still attached: $WORKIMG"

rm -f "$WORKIMG"
truncate -s 8G "$WORKIMG"
mkfs.ext4 -q -F "$WORKIMG"
WORK_LOOPDEV="$(losetup -f --show "$WORKIMG")" \
  || die "Could not allocate loop device for repatch workspace"
mount "$WORK_LOOPDEV" "$WORK" \
  || die "Could not mount repatch workspace"

step "Reconciling driver and hardware packages in overlay chroot"
overlay_mount "$NEWROOT" "$WORK" "$WORK/merged"

# Shared build helpers expect the build-time names for the target root and
# workspace.  Point them at the staged slot/repatch workspace.
# shellcheck disable=SC2034
MNT="$NEWROOT"
# shellcheck disable=SC2034
WORKDIR="$WORK"

if [[ "${SKIP_SIG:-0}" -eq 1 ]]; then
  warn "pacman signature verification DISABLED for repatch"
  setup_pacman_conf "$MERGED/tmp/pacman-repatch.conf" "Never"
else
  setup_pacman_conf "$MERGED/tmp/pacman-repatch.conf" "Required DatabaseOptional"
fi

if [[ "${FIX_KEYRING:-0}" -eq 1 ]]; then
  log "Force-initialising pacman keyring with Arch Linux + Holo keys"
  overlay_init_keyring "archlinux holo"
else
  overlay_init_keyring
fi

# Snapshot package state before any overlay transaction so payload calculation
# sees upgrades as well as newly-added packages.
snapshot_driver_packages "$WORK/before.txt"

log "Downloading exact-match kernel headers"
in_chroot "curl -sfL '$HDR_URL' -o /tmp/headers.pkg.tar.zst"

log "Refreshing Valve package database for header dependencies"
in_chroot "pacman --config '$PACCONF' -Sy"

log "Installing exact-match kernel headers"
in_chroot "pacman --config '$PACCONF' -U $PACOPTS /tmp/headers.pkg.tar.zst"

# This is now the same package path as the initial build:
#   Valve manifest -> Valve repositories
#   Arch manifest  -> official Arch repositories
# Versions marked "latest" are refreshed on every heal.  nvidia-open-dkms
# builds via its normal DKMS pacman hook; install_hw_libs() verifies/falls back
# to dkms autoinstall before returning.
install_hw_libs

# Add Thunderbolt support files to the overlay after bolt has been reconciled.
# They are included in the payload rsync below.
if [[ -d /usr/lib/steamos-nvidia/thunderbolt ]]; then
  log "Adding thunderbolt support to overlay"
  _install_thunderbolt_files /usr/lib/steamos-nvidia/thunderbolt "$MERGED"
fi

# Build upstream Logitech HID modules if selected.
if (( HID_EXPECTED )); then
  log "Building upstream Logitech receiver and HID++ modules"

  rm -rf "$MERGED/tmp/hid-kmod"
  mkdir -p "$MERGED/tmp/hid-kmod"
  cp -a /home/.driver-packages/hid/. "$MERGED/tmp/hid-kmod/"

  in_chroot "make -C /usr/lib/modules/$KVER/build M=/tmp/hid-kmod clean"
  in_chroot "make -C /usr/lib/modules/$KVER/build M=/tmp/hid-kmod modules"

  in_chroot "install -Dm644 /tmp/hid-kmod/hid-logitech-dj.ko /usr/lib/modules/$KVER/updates/logitech/hid-logitech-dj.ko"
  in_chroot "install -Dm644 /tmp/hid-kmod/hid-logitech-hidpp.ko /usr/lib/modules/$KVER/updates/logitech/hid-logitech-hidpp.ko"

  in_chroot "modinfo -F alias /tmp/hid-kmod/hid-logitech-dj.ko | grep -qi 'v0000046Dp0000C547'" \
    || die "upstream hid-logitech-dj module lacks the 046d:c547 alias"

  register_built_module "updates/logitech/hid-logitech-dj.ko"
  register_built_module "updates/logitech/hid-logitech-hidpp.ko"
  verify_built_modules "$MERGED" "$KVER" die

  log "Built upstream Logitech modules for $KVER"
fi

step "Copying reconciled payload into $PARTSET rootfs"
copy_driver_payload "$NEWROOT" "$WORK/before.txt" "$WORK"

# ── Always-run reconciliation ─────────────────────────────────────────────────
# These steps are idempotent and keep boot/runtime configuration aligned with
# the package/module payload just reconciled above.

# Reconcile initramfs modules through the shared module helper.
step "Restoring module autoloading in initramfs"
reconcile_initramfs "$NEWROOT" "$KVER" "${INITRAMFS_MODULES:-}"

step "Reconciling target system configuration"

# Reconcile gamemode group membership (idempotent).
if [[ -n "${GAMING_ITEMS:-}" ]]; then
  if [[ " $GAMING_ITEMS " == *" gamemode "* ]]; then
    log "Checking gamemode group membership"
    if chroot "$NEWROOT" getent group gamemode >/dev/null 2>&1; then
      chroot "$NEWROOT" usermod -aG gamemode deck \
        || warn "Failed to add deck to gamemode group (non-fatal)"
    else
      warn "gamemode group not found in image — skipping"
    fi
  fi
fi

enable_nvidia_power_services "$NEWROOT"

# Register persisted kernel parameters with grub.sh.
# Base nvidia params (rd.driver.blacklist, nvidia-drm.modeset, etc.) are
# already in NVIDIA_CMDLINE_ADD which _build_all_params() includes
# automatically.  EXTRA_CMDLINE_ADD carries the additional resolved
# canonical params from the original build.
if [[ -n "${EXTRA_CMDLINE_ADD:-}" ]]; then
  step "Restoring persisted kernel params: $EXTRA_CMDLINE_ADD"
  for _param in $EXTRA_CMDLINE_ADD; do
    add_kernel_param "$_param"
  done
fi

# Propagate the self-healing machinery, package manifests/configs, and
# persisted selections so the NEXT update is covered too.
mkdir -p "$NEWROOT/usr/lib/steamos-nvidia"
cp -a /usr/lib/steamos-nvidia/. "$NEWROOT/usr/lib/steamos-nvidia/"

# Restore modprobe config from bundle.
cp /usr/lib/steamos-nvidia/configs/99-nvidia-patch.conf "$NEWROOT/etc/modprobe.d/99-nvidia-patch.conf"
backup_original_updater "$NEWROOT"
cp -a /usr/bin/steamos-update "$NEWROOT/usr/bin/steamos-update"
[[ -f "$NEWROOT/usr/lib/systemd/system/steamos-finish-oobe-migration.service" ]] \
  && ln -sf /dev/null "$NEWROOT/etc/systemd/system/steamos-finish-oobe-migration.service"
[[ -f /etc/sudoers.d/zz-deck-nopasswd ]] \
  && install -m 440 /etc/sudoers.d/zz-deck-nopasswd "$NEWROOT/etc/sudoers.d/zz-deck-nopasswd"
[[ -f /usr/local/bin/nvidia-install-run ]] \
  && install -m 755 /usr/local/bin/nvidia-install-run "$NEWROOT/usr/local/bin/nvidia-install-run"

# Rootfs was already expanded above. The invariant holds.

# Reconcile persistent defaults + authoritative EFI GRUB through grub.sh.
step "Regenerating grub config for $PARTSET"
reconcile_grub "$NEWROOT" "$EFIDEV" "$PARTSET"

log "Final boot state before returning success"
diagnose_boot_state

step "OK — $PARTSET is NVIDIA-ready ($KVER)"
