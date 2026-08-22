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

# Use the shared common.sh logging/failure framework with repatch-specific
# presentation and diagnostics.
LOG_TAG="repatch"
LOGGER_TAG="steamos-nvidia-repatch"
LOG_COLOR=0
CURRENT_STEP="startup"
FAILURE_REPORTED=0

# May not exist yet if failure happens very early.
NEWROOT=""

failure_journal_context() {
  printf "partset='%s' kver='%s'" \
    "${PARTSET:-unknown}" \
    "${KVER:-unknown}"
}

failure_snapshot_extra() {
  local _slot

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

# common.sh owns log/warn/step/die, ERR handling, and the low-level mount/loop
# helpers used transitively by overlay.sh and common_system.sh.
if [[ ! -r "$SCRIPT_DIR/common.sh" ]]; then
  echo "[repatch] ERROR: missing helper: $SCRIPT_DIR/common.sh" >&2
  exit 1
fi
source "$SCRIPT_DIR/common.sh"

# Ensure the full .steamos-nvidia tree exists (logs already created above;
# this also creates recovery/ with world-writable perms).
ensure_steamos_nvidia_dirs

for helper in overlay common_system common_modules common_drivers install-hw-libs grub; do
  [[ -r "$SCRIPT_DIR/$helper.sh" ]] \
    || die "missing helper: $SCRIPT_DIR/$helper.sh"
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

repatch_cleanup() {
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
trap 'set +e; repatch_cleanup; set -e' EXIT

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

# Canonical HID bundle location.  Older self-heal state wrote to /home.
HID_BUNDLE_DIR="/usr/lib/steamos-nvidia/hid"
[[ -d "$HID_BUNDLE_DIR" ]] || HID_BUNDLE_DIR="/home/.driver-packages/hid"

# Determine whether the custom Logitech modules need to be rebuilt.
HID_EXPECTED=0
if [[ -n "${GAMING_ITEMS:-}" ]]; then
  [[ " ${GAMING_ITEMS} " == *" logitech-hid "* ]] && HID_EXPECTED=1
elif [[ -d "$HID_BUNDLE_DIR" ]]; then
  # Compatibility with older self-heal state that used HW_SUPPORT_ITEMS.
  HID_EXPECTED=1
fi

if (( HID_EXPECTED )); then
  [[ -d "$HID_BUNDLE_DIR" ]] \
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
  cp -a "$HID_BUNDLE_DIR/." "$MERGED/tmp/hid-kmod/"

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

# Reconcile gamemode group membership + user service (idempotent).
if [[ -n "${GAMING_ITEMS:-}" ]]; then
  if [[ " $GAMING_ITEMS " == *" gamemode "* ]]; then
    log "Checking gamemode group membership"
    if chroot "$NEWROOT" getent group gamemode >/dev/null 2>&1; then
      chroot "$NEWROOT" usermod -aG gamemode deck \
        || warn "Failed to add deck to gamemode group (non-fatal)"
    else
      warn "gamemode group not found in image — skipping"
    fi
    log "Enabling gamemoded user service"
    mkdir -p "$NEWROOT/etc/systemd/user/graphical-session.target.wants"
    ln -sf /usr/lib/systemd/user/gamemoded.service \
      "$NEWROOT/etc/systemd/user/graphical-session.target.wants/gamemoded.service" \
      || warn "Failed to enable gamemoded user service (non-fatal)"
  fi

  # Re-clobber /etc/profile.d/libva.sh — OS updates restore Valve's file
  # that forces LIBVA_DRIVER_NAME=radeonsi.
  if [[ " $GAMING_ITEMS " == *" unset-libva-driver "* ]]; then
    if [[ -e "$NEWROOT/etc/profile.d/libva.sh" ]]; then
      log "Removing /etc/profile.d/libva.sh (OS update restored it)"
      rm -f "$NEWROOT/etc/profile.d/libva.sh"
    fi
  fi

  # Re-apply scx_lavd config — OS updates may restore stock scx_loader config.
  if [[ " $GAMING_ITEMS " == *" scx-lavd "* ]]; then
    if [[ -x "$NEWROOT/usr/bin/scx_lavd" ]]; then
      log "Reconciling scx_lavd scheduler (autopilot) via scx_loader"
      mkdir -p "$NEWROOT/etc/scx_loader"
      cp "$SCRIPT_DIR/configs/scx_loader_config.toml" \
        "$NEWROOT/etc/scx_loader/config.toml"
      mkdir -p "$NEWROOT/etc/systemd/system/multi-user.target.wants"
      ln -sf /usr/lib/systemd/system/scx.service \
        "$NEWROOT/etc/systemd/system/multi-user.target.wants/scx.service" \
        || warn "Failed to enable scx.service (non-fatal)"
    else
      warn "scx-lavd selected but /usr/bin/scx_lavd not found — skipping"
    fi
  fi

  # Re-apply vm.swappiness — OS updates may restore stock sysctl defaults.
  if [[ " $GAMING_ITEMS " == *" vm-tunables "* ]]; then
    local _has_zram=0 _target_swappiness
    if [[ -e "$NEWROOT/usr/lib/systemd/zram-generator.conf" ]] \
      || [[ -e "$NEWROOT/etc/systemd/zram-generator.conf" ]] \
      || [[ -e "$NEWROOT/usr/lib/systemd/zram-generator.conf.d" ]] \
      || [[ -e "$NEWROOT/etc/systemd/zram-generator.conf.d" ]]; then
      _has_zram=1
    fi
    _target_swappiness="$(cat "$NEWROOT/proc/sys/vm/swappiness" 2>/dev/null || echo 60)"
    if (( _has_zram )) && (( _target_swappiness < 100 )); then
      log "Re-applying vm.swappiness=180 (zram present)"
      mkdir -p "$NEWROOT/etc/sysctl.d"
      cp "$SCRIPT_DIR/configs/swappiness-zram.conf" \
        "$NEWROOT/etc/sysctl.d/99-vm-swappiness.conf"
    elif (( ! _has_zram )) && (( _target_swappiness > 10 )); then
      log "Re-applying vm.swappiness=10 (no zram)"
      mkdir -p "$NEWROOT/etc/sysctl.d"
      cp "$SCRIPT_DIR/configs/swappiness-disk.conf" \
        "$NEWROOT/etc/sysctl.d/99-vm-swappiness.conf"
    fi
  fi

  # Re-install boot-time performance hooks — OS updates restore the rootfs.
  if [[ " $GAMING_ITEMS " == *" cpu-performance "* ]] \
    || [[ " $GAMING_ITEMS " == *" gpu-power-limit "* ]]; then
    log "Reconciling steam-perf boot framework"
    local _boot_src="$SCRIPT_DIR/configs/boot"
    local _boot_dst="$NEWROOT/usr/lib/steam-perf"

    mkdir -p "$_boot_dst/boot.d"
    cp "$_boot_src/apply-boot" "$_boot_dst/apply-boot"
    chmod 755 "$_boot_dst/apply-boot"
    mkdir -p "$NEWROOT/etc/steam-perf"
    cp "$_boot_src/config.conf" "$NEWROOT/etc/steam-perf/config.conf"

    if [[ " $GAMING_ITEMS " == *" cpu-performance "* ]]; then
      cp "$_boot_src/30-cpu" "$_boot_dst/boot.d/30-cpu"
      chmod 755 "$_boot_dst/boot.d/30-cpu"
    fi
    if [[ " $GAMING_ITEMS " == *" gpu-power-limit "* ]]; then
      cp "$_boot_src/20-nvidia-gpu" "$_boot_dst/boot.d/20-nvidia-gpu"
      chmod 755 "$_boot_dst/boot.d/20-nvidia-gpu"
      cp "$_boot_src/25-amd-gpu" "$_boot_dst/boot.d/25-amd-gpu"
      chmod 755 "$_boot_dst/boot.d/25-amd-gpu"
    fi

    mkdir -p "$NEWROOT/etc/systemd/system/multi-user.target.wants"
    cp "$_boot_src/steam-perf.service" \
      "$NEWROOT/etc/systemd/system/steam-perf.service"
    ln -sf ../steam-perf.service \
      "$NEWROOT/etc/systemd/system/multi-user.target.wants/steam-perf.service" \
      || warn "Failed to enable steam-perf.service (non-fatal)"
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

# Ensure persistent desktop session variant is selected.
if chroot "$NEWROOT" command -v steamos-session-select >/dev/null 2>&1; then
  log "Selecting persistent desktop session"
  chroot "$NEWROOT" steamos-session-select plasma-wayland-persistent 2>/dev/null \
    || warn "steamos-session-select failed (non-fatal)"
fi

# Reconcile persistent defaults + authoritative EFI GRUB through grub.sh.
step "Regenerating grub config for $PARTSET"
reconcile_grub "$NEWROOT" "$EFIDEV" "$PARTSET"

# Run user-provided custom script if present (fail open).
_custom="/home/.steamos-nvidia/recovery/custom.sh"
if [[ -x "$_custom" ]]; then
  step "Running custom script"
  if bash "$_custom" 2>&1; then
    log "Custom script completed successfully"
  else
    warn "Custom script exited with non-zero status (non-fatal)"
  fi
else
  log "No custom script at $_custom — skipping"
fi

# Reconcile persistent defaults + authoritative EFI GRUB through grub.sh.
step "Regenerating grub config for $PARTSET"
reconcile_grub "$NEWROOT" "$EFIDEV" "$PARTSET"

log "Final boot state before returning success"
diagnose_boot_state

step "OK — $PARTSET is NVIDIA-ready ($KVER)"
