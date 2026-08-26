#!/bin/bash
#
# steamos-nvidia-installer — lib/flashless.sh
# Flashless install: write the built NVIDIA image directly to the inactive
# A/B slot without a USB stick.  Sourced by the wrapper — do not run directly.
#
# Requires: common.sh, common_system.sh, common_drivers.sh (for
# configure_update_channel), grub.sh (for reconcile_grub).

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/flashless.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ── Cleanup machinery ─────────────────────────────────────────────────────────
# Every temporary mountpoint and directory created during the flashless flow is
# registered here so a single EXIT trap tears everything down in reverse order.
# Normal phase completion unmounts explicitly; this is the failure safety net.

_FL_CLEANUP_MOUNTS=()
_FL_CLEANUP_DIRS=()
_FL_CLEANUP_CMDS=()
FL_IMG_LOOP=""

flashless_register_mount() { _FL_CLEANUP_MOUNTS+=("$1"); }
flashless_register_dir() { _FL_CLEANUP_DIRS+=("$1"); }
flashless_register_cleanup() { _FL_CLEANUP_CMDS+=("$1"); }

flashless_unregister_mount() {
  local target="$1"
  local -a kept=()
  local m
  for m in "${_FL_CLEANUP_MOUNTS[@]}"; do
    [[ "$m" != "$target" ]] && kept+=("$m")
  done
  _FL_CLEANUP_MOUNTS=("${kept[@]}")
}

flashless_cleanup() {
  local _had_e=0
  [[ -o errexit ]] && _had_e=1
  set +e

  # Unmount in reverse registration order.
  local i
  for ((i = ${#_FL_CLEANUP_MOUNTS[@]} - 1; i >= 0; i--)); do
    local m="${_FL_CLEANUP_MOUNTS[$i]}"
    if mountpoint -q "$m" 2>/dev/null; then
      umount -R "$m" 2>/dev/null || umount -Rl "$m" 2>/dev/null
    fi
  done

  # Execute registered cleanup commands (e.g. udev rule removal).
  local cmd
  for cmd in "${_FL_CLEANUP_CMDS[@]}"; do
    eval "$cmd" 2>/dev/null || true
  done

  # Detach loop device last.
  if [[ -n "$FL_IMG_LOOP" ]]; then
    losetup -d "$FL_IMG_LOOP" 2>/dev/null || true
    FL_IMG_LOOP=""
    FL_ROOTFS_WAS_RO=0
  fi

  # Remove temporary directories in reverse order (children before parents).
  for ((i = ${#_FL_CLEANUP_DIRS[@]} - 1; i >= 0; i--)); do
    rmdir "${_FL_CLEANUP_DIRS[$i]}" 2>/dev/null || true
  done

  [[ "$_had_e" -eq 1 ]] && set -e
}

# ── Slot detection ────────────────────────────────────────────────────────────

# Detect the currently booted and target (inactive) A/B slots.
# Cross-checks steamos-bootconf against RAUC — disagreement or ambiguity is
# fatal.  All target device paths are resolved to canonical /dev/... (not
# symlinks) so a later loop-mount cannot hijack the partset namespace.
flashless_detect_slots() {
  local bootconf_slot rauc_slot rauc_booted

  bootconf_slot="$(steamos-bootconf this-image 2>/dev/null)" \
    || die "Cannot determine current boot slot (steamos-bootconf this-image failed)"

  rauc_booted="$(rauc status --output-format=json 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("booted",""))' 2>/dev/null)" || true

  case "$rauc_booted" in
    A | rootfs.0) rauc_slot=A ;;
    B | rootfs.1) rauc_slot=B ;;
    dev) rauc_slot="$bootconf_slot" ;; # dev = running from development; trust bootconf
    *) rauc_slot="" ;;
  esac

  # Require RAUC to return a recognizable slot — no silent bypass.
  [[ -n "$rauc_slot" ]] \
    || die "Cannot determine booted slot from RAUC (got '$rauc_booted') — refusing to proceed"

  if [[ "$rauc_slot" != "$bootconf_slot" ]]; then
    die "RAUC booted=$rauc_slot but steamos-bootconf=$bootconf_slot — slot identity ambiguous, refusing to proceed"
  fi

  FL_CURRENT="$bootconf_slot"
  case "$FL_CURRENT" in
    A) FL_TARGET=B ;;
    B) FL_TARGET=A ;;
    *) die "Unexpected current slot: $FL_CURRENT" ;;
  esac

  # Freeze canonical block device paths NOW, before any losetup that could
  # create competing /dev/disk/by-partsets symlinks.
  FL_TARGET_ROOTFS="$(readlink -f "/dev/disk/by-partsets/$FL_TARGET/rootfs" 2>/dev/null)" \
    || die "Cannot resolve target rootfs device"
  FL_TARGET_EFI="$(readlink -f "/dev/disk/by-partsets/$FL_TARGET/efi" 2>/dev/null)" \
    || die "Cannot resolve target EFI device"
  FL_TARGET_VAR="$(readlink -f "/dev/disk/by-partsets/$FL_TARGET/var" 2>/dev/null)" \
    || die "Cannot resolve target var device — unexpected disk layout"

  [[ -b "$FL_TARGET_ROOTFS" ]] || die "Target rootfs not a block device: $FL_TARGET_ROOTFS"
  [[ -b "$FL_TARGET_EFI" ]] || die "Target EFI not a block device: $FL_TARGET_EFI"
  [[ -b "$FL_TARGET_VAR" ]] || die "Target var not a block device: $FL_TARGET_VAR"

  log "Flashless: current=$FL_CURRENT target=$FL_TARGET"
  log "  rootfs: $FL_TARGET_ROOTFS"
  log "  efi:    $FL_TARGET_EFI"
  log "  var:    $FL_TARGET_VAR"
}

# ── Safety checks ─────────────────────────────────────────────────────────────

flashless_safety_checks() {
  local real_current
  real_current="$(readlink -f "/dev/disk/by-partsets/$FL_CURRENT/rootfs" 2>/dev/null)" \
    || die "Cannot resolve current rootfs device"

  if [[ "$real_current" == "$FL_TARGET_ROOTFS" ]]; then
    die "Current and target rootfs resolve to the same device — refusing to overwrite"
  fi

  # The currently booted slot must also be the next-boot slot.  If a pending
  # transition exists, overwriting the target could strand the system.
  local selected
  selected="$(steamos-bootconf selected-image 2>/dev/null)" \
    || die "Cannot determine selected boot slot"
  if [[ "$selected" != "$FL_CURRENT" ]]; then
    die "Current slot is $FL_CURRENT but selected-image is $selected — pending slot transition, refusing flashless install"
  fi

  local dev
  for dev in "$FL_TARGET_ROOTFS" "$FL_TARGET_EFI" "$FL_TARGET_VAR"; do
    [[ -b "$dev" ]] || continue
    local mnt
    mnt="$(findmnt -rn -S "$dev" -o TARGET 2>/dev/null | head -n1)" || true
    if [[ -n "$mnt" ]]; then
      die "Target partition $dev is mounted at $mnt — unmount before flashless install"
    fi
  done

  log "Flashless safety checks passed"
}

# ── Image extraction ──────────────────────────────────────────────────────────

# Loop-mount the built image and identify the source rootfs by GPT PARTLABEL.
# We explicitly select rootfs-A (the partition our builder modifies), then
# mount it read-only and verify it is actually our build.
# Sets: FL_IMG_LOOP, FL_IMG_ROOTFS
flashless_extract_image() {
  local img="$1"

  [[ -f "$img" ]] || die "Built image not found: $img"

  # Create udev guard BEFORE the loop device exists so udisks2 never sees
  # the partitions as mountable.  Use a broad loop-partition pattern first;
  # the rule is removed on cleanup regardless of which loop device was used.
  local _flashless_udev_rule="/run/udev/rules.d/89-steamos-nvidia-flashless.rules"
  mkdir -p /run/udev/rules.d
  cat >"$_flashless_udev_rule" <<'EOF'
# steamos-nvidia flashless-loop quarantine.
SUBSYSTEM=="block", KERNEL=="loop[0-9]*p*", ENV{UDISKS_IGNORE}="1", ENV{SYSTEMD_READY}="0"
EOF
  udevadm control --reload-rules 2>/dev/null || true
  flashless_register_cleanup "rm -f '$_flashless_udev_rule'; udevadm control --reload-rules 2>/dev/null || true"

  log "Loop-mounting built image: $img"
  FL_IMG_LOOP="$(losetup -f --show --partscan "$img" 2>/dev/null)" \
    || die "Could not loop-mount image"
  log "  Loop device: $FL_IMG_LOOP"

  udevadm settle --timeout=10 2>/dev/null || true

  # Identify source rootfs by PARTLABEL — select rootfs-A specifically.
  # NOTE: --partscan temporarily exposes image partitions in the global
  # /dev/disk/by-partsets namespace.  We detach the loop immediately after
  # dd + verification, before any partset-dependent commands run.
  FL_IMG_ROOTFS=""
  local part label
  for part in "$FL_IMG_LOOP"p*; do
    [[ -b "$part" ]] || continue
    label="$(blkid -s PARTLABEL -o value "$part" 2>/dev/null)" || true
    log "  $part: partlabel=${label:-<none>}"
    if [[ "$label" == "rootfs-A" ]]; then
      FL_IMG_ROOTFS="$part"
    fi
  done

  [[ -n "$FL_IMG_ROOTFS" ]] \
    || die "rootfs-A partition not found in image (available: $(lsblk -lnpo PARTLABEL "$FL_IMG_LOOP"p* 2>/dev/null | tr '\n' ' '))"

  # Verify this is actually our build — mount read-only and check markers.
  local verify_mnt
  verify_mnt="$(mktemp -d /tmp/flashless-verify-src.XXXXXX)"
  flashless_register_dir "$verify_mnt"
  mount -o ro "$FL_IMG_ROOTFS" "$verify_mnt" \
    || die "Could not mount source rootfs for build verification"
  flashless_register_mount "$verify_mnt"

  # Check manifest variant matches what we built.
  local manifest="$verify_mnt/usr/lib/steamos-atomupd/manifest.json"
  if [[ ! -f "$manifest" ]]; then
    die "Source rootfs-A missing manifest.json — not a valid SteamOS image"
  fi
  if ! grep -q "\"variant\"[[:space:]]*:[[:space:]]*\"${TARGET_VARIANT:-steamdeck}\"" "$manifest"; then
    die "Source rootfs-A variant does not match TARGET_VARIANT=${TARGET_VARIANT:-steamdeck}"
  fi

  # Check NVIDIA payload is present (repatch.sh is installed by update-strategy).
  if [[ ! -f "$verify_mnt/usr/lib/steamos-nvidia/repatch.sh" ]]; then
    die "Source rootfs-A is not an NVIDIA-patched build (repatch.sh missing)"
  fi

  log "  Source verified: variant=${TARGET_VARIANT:-steamdeck}, NVIDIA payload present"

  umount "$verify_mnt" 2>/dev/null || umount -l "$verify_mnt" 2>/dev/null
  flashless_unregister_mount "$verify_mnt"
  rmdir "$verify_mnt" 2>/dev/null || true

  log "  Source rootfs: $FL_IMG_ROOTFS (verified as our build)"
}

# ── Size check ────────────────────────────────────────────────────────────────

flashless_check_sizes() {
  local src_bytes tgt_bytes
  src_bytes="$(blockdev --getsize64 "$FL_IMG_ROOTFS" 2>/dev/null)" \
    || die "Could not determine source rootfs size"
  tgt_bytes="$(blockdev --getsize64 "$FL_TARGET_ROOTFS" 2>/dev/null)" \
    || die "Could not determine target rootfs size"

  log "Size check: source=$src_bytes target=$tgt_bytes"
  if ((src_bytes > tgt_bytes)); then
    die "Source rootfs ($src_bytes bytes) is larger than target partition ($tgt_bytes bytes)"
  fi
}

# ── Target reset ──────────────────────────────────────────────────────────────

flashless_format_target() {
  log "Formatting target EFI: $FL_TARGET_EFI"
  mkfs.vfat -F 32 -n "efi-$FL_TARGET" "$FL_TARGET_EFI" 2>/dev/null \
    || mkfs.vfat -F 32 "$FL_TARGET_EFI" \
    || die "Failed to format target EFI partition"

  log "Formatting target var: $FL_TARGET_VAR"
  mkfs.ext4 -q -F -L "var-$FL_TARGET" "$FL_TARGET_VAR" \
    || die "Failed to format target var partition"
}

# ── Rootfs write ──────────────────────────────────────────────────────────────

flashless_write_rootfs() {
  local src_bytes tgt_bytes
  src_bytes="$(blockdev --getsize64 "$FL_IMG_ROOTFS" 2>/dev/null)"
  tgt_bytes="$(blockdev --getsize64 "$FL_TARGET_ROOTFS" 2>/dev/null)"

  # Pre-compute source hash for post-dd verification.
  log "Computing source rootfs SHA256 ($src_bytes bytes)"
  local src_hash
  src_hash="$(
    dd if="$FL_IMG_ROOTFS" bs=1M count="$src_bytes" iflag=count_bytes status=none \
      | sha256sum | awk '{print $1}'
  )" || die "Failed to hash source rootfs"
  log "  Source SHA256: $src_hash"

  log "Writing rootfs: $FL_IMG_ROOTFS -> $FL_TARGET_ROOTFS ($src_bytes bytes)"
  dd if="$FL_IMG_ROOTFS" of="$FL_TARGET_ROOTFS" \
    bs=128M conv=fsync status=progress \
    || die "Failed to write rootfs to target partition"

  sync -f "$FL_TARGET_ROOTFS" 2>/dev/null || sync
  blockdev --flushbufs "$FL_TARGET_ROOTFS" 2>/dev/null || true
  udevadm settle --timeout=10 2>/dev/null || true

  # Raw SHA256 verification — MUST happen BEFORE btrfstune -u.
  log "Verifying written rootfs ($src_bytes bytes)"
  local tgt_hash
  tgt_hash="$(
    dd if="$FL_TARGET_ROOTFS" bs=1M count="$src_bytes" iflag=count_bytes status=none \
      | sha256sum | awk '{print $1}'
  )" || die "Failed to read back target for verification"

  if [[ "$src_hash" != "$tgt_hash" ]]; then
    die "Rootfs verification FAILED — source=$src_hash target=$tgt_hash"
  fi
  log "  Verification passed: $tgt_hash"

  # Randomize Btrfs UUID AFTER verification (rewrites metadata in-place).
  log "Randomizing target Btrfs UUID"
  btrfstune -f -u "$FL_TARGET_ROOTFS" \
    || die "btrfstune -u failed — target rootfs may share source UUID"

  log "Checking target Btrfs filesystem"
  btrfs check --readonly "$FL_TARGET_ROOTFS" \
    || die "btrfs check failed on target rootfs"

  # Expand to fill partition if the source was smaller.
  if ((src_bytes < tgt_bytes)); then
    log "Expanding target rootfs to fill partition"
    local resize_mnt
    resize_mnt="$(mktemp -d /tmp/flashless-resize.XXXXXX)"
    flashless_register_dir "$resize_mnt"
    mount -o compress-force=zstd:3 "$FL_TARGET_ROOTFS" "$resize_mnt" \
      || die "Could not mount target rootfs for resize"
    flashless_register_mount "$resize_mnt"
    btrfs filesystem resize max "$resize_mnt" \
      || die "Target rootfs resize failed"
    sync -f "$resize_mnt" 2>/dev/null || sync
    umount "$resize_mnt" 2>/dev/null || umount -l "$resize_mnt" 2>/dev/null
    flashless_unregister_mount "$resize_mnt"
    rmdir "$resize_mnt" 2>/dev/null || true
  fi

  log "Rootfs write complete"
}

# ── Partset verification ──────────────────────────────────────────────────────

# After detaching the loop image, verify that /dev/disk/by-partsets has
# returned to pointing at the real target partitions.
flashless_verify_partsets() {
  log "Verifying partset symlinks point to real target devices"

  local resolved
  resolved="$(readlink -f "/dev/disk/by-partsets/$FL_TARGET/rootfs" 2>/dev/null)" \
    || die "Cannot resolve partset $FL_TARGET/rootfs after loop detach"
  if [[ "$resolved" != "$FL_TARGET_ROOTFS" ]]; then
    die "Partset rootfs hijacked: expected $FL_TARGET_ROOTFS, got $resolved"
  fi

  resolved="$(readlink -f "/dev/disk/by-partsets/$FL_TARGET/efi" 2>/dev/null)" \
    || die "Cannot resolve partset $FL_TARGET/efi after loop detach"
  if [[ "$resolved" != "$FL_TARGET_EFI" ]]; then
    die "Partset efi hijacked: expected $FL_TARGET_EFI, got $resolved"
  fi

  resolved="$(readlink -f "/dev/disk/by-partsets/$FL_TARGET/var" 2>/dev/null)" \
    || die "Cannot resolve partset $FL_TARGET/var after loop detach"
  if [[ "$resolved" != "$FL_TARGET_VAR" ]]; then
    die "Partset var hijacked: expected $FL_TARGET_VAR, got $resolved"
  fi

  log "  All partset symlinks verified"
}

# ── /etc overlay state ────────────────────────────────────────────────────────

# Write update channel configuration into the target rootfs.
# The freshly formatted var has no overlay yet, so the rootfs lower /etc
# is authoritative until the first boot creates the runtime overlay.
flashless_restore_etc() {
  local target_mnt
  target_mnt="$(mktemp -d /tmp/flashless-etc.XXXXXX)" \
    || die "Could not create temporary mount point"
  flashless_register_dir "$target_mnt"

  mount -o rw "$FL_TARGET_ROOTFS" "$target_mnt" \
    || die "Could not mount target rootfs for /etc restoration"
  flashless_register_mount "$target_mnt"

  # Clear ro if set — but do NOT restore it here.  reconcile_grub still
  # needs to write to the rootfs.  Restored in flashless_restore_rootfs_ro()
  # after all modifications are complete.
  local btrfs_ro
  btrfs_ro="$(
    btrfs property get -ts "$target_mnt" ro 2>/dev/null \
      | awk -F= '/^ro=/{print $2}' || true
  )"
  if [[ "$btrfs_ro" == "true" ]]; then
    btrfs property set -ts "$target_mnt" ro false \
      || die "Could not clear Btrfs ro on target"
    FL_ROOTFS_WAS_RO=1
  fi

  local _saved_mnt="${MNT:-}"
  MNT="$target_mnt"
  configure_update_channel
  MNT="$_saved_mnt"

  # Persist project files to /home so scripts stay current
  ensure_project_persisted

  sync -f "$target_mnt" 2>/dev/null || sync
  umount "$target_mnt" 2>/dev/null || umount -l "$target_mnt" 2>/dev/null
  flashless_unregister_mount "$target_mnt"
  rmdir "$target_mnt" 2>/dev/null || true

  log "Target /etc state restored"
}

# ── Boot environment ──────────────────────────────────────────────────────────

flashless_rebuild_boot() {
  log "Rebuilding boot environment for slot $FL_TARGET"

  local -a chroot_cmd=(
    steamos-chroot
    --no-overlay
    --partset "$FL_TARGET"
    --
  )

  # Create the directory structure that steamos-partsets and steamos-bootconf
  # expect.  The target EFI was just formatted blank; don't depend on these
  # utilities to implicitly create their parent directories.
  log "  Creating EFI directory structure"
  "${chroot_cmd[@]}" mkdir -p /efi/SteamOS \
    || die "Could not create /efi/SteamOS in target"
  "${chroot_cmd[@]}" mkdir -p /esp/SteamOS/conf \
    || die "Could not create /esp/SteamOS/conf in target"

  # steamos-partsets: create /efi/SteamOS/partsets symlinks.
  log "  Creating partset symlinks"
  "${chroot_cmd[@]}" steamos-partsets /efi/SteamOS/partsets \
    || die "steamos-partsets failed — boot environment will be invalid"

  # steamos-bootconf create: write the slot's boot configuration.
  # Remove any stale config file first — the inactive slot may have a leftover
  # config from a previous installation.  create refuses to overwrite.
  log "  Creating boot configuration for $FL_TARGET"
  rm -f "/esp/SteamOS/conf/${FL_TARGET}.conf" 2>/dev/null || true
  "${chroot_cmd[@]}" steamos-bootconf create \
    --image "$FL_TARGET" \
    --conf-dir /esp/SteamOS/conf \
    --efi-dir /efi \
    --set "title" "$FL_TARGET" \
    || die "steamos-bootconf create failed — slot has no boot entry"

  # GRUB binary rebuild.
  log "  Rebuilding GRUB image"
  "${chroot_cmd[@]}" grub-mkimage \
    || die "grub-mkimage failed — EFI bootloader will be missing"

  # update-grub: best-effort (direct EFI patch is authoritative).
  log "  Running update-grub"
  "${chroot_cmd[@]}" update-grub 2>/dev/null \
    || log "  update-grub failed — will rely on direct EFI patch"

  # reconcile_grub expects a mounted rootfs, not a block device.
  # Mount target rootfs, run the authoritative GRUB/kernel-param flow,
  # then unmount cleanly.
  local grub_root
  grub_root="$(mktemp -d /tmp/flashless-grub.XXXXXX)" \
    || die "Could not create GRUB root mountpoint"
  flashless_register_dir "$grub_root"

  mount -o rw "$FL_TARGET_ROOTFS" "$grub_root" \
    || die "Could not mount target rootfs for GRUB reconciliation"
  flashless_register_mount "$grub_root"

  log "  Running reconcile_grub for $FL_TARGET"
  reconcile_grub "$grub_root" "$FL_TARGET_EFI" "$FL_TARGET" \
    || die "reconcile_grub failed — kernel command line may be incomplete"

  umount "$grub_root" 2>/dev/null || umount -l "$grub_root" 2>/dev/null
  flashless_unregister_mount "$grub_root"
  rmdir "$grub_root" 2>/dev/null || true

  log "Boot environment rebuilt for slot $FL_TARGET"
}

# ── Restore Btrfs ro ──────────────────────────────────────────────────────────

# Restore the target rootfs's original Btrfs ro property after all
# modifications are complete.  Called once, after reconcile_grub succeeds.
flashless_restore_rootfs_ro() {
  ((${FL_ROOTFS_WAS_RO:-0})) || return 0

  local mnt
  mnt="$(mktemp -d /tmp/flashless-ro.XXXXXX)" \
    || die "Could not create mountpoint for ro restore"
  flashless_register_dir "$mnt"

  mount -o rw "$FL_TARGET_ROOTFS" "$mnt" \
    || die "Could not mount target rootfs to restore ro property"
  flashless_register_mount "$mnt"

  btrfs property set -ts "$mnt" ro true \
    || die "Could not restore target Btrfs ro property"

  sync -f "$mnt" 2>/dev/null || sync
  umount "$mnt" || die "Could not unmount target after restoring ro"
  flashless_unregister_mount "$mnt"
  rmdir "$mnt" 2>/dev/null || true

  log "Target Btrfs ro property restored"
}

# ── Slot activation ───────────────────────────────────────────────────────────

flashless_activate_slot() {
  local rauc_slot
  case "$FL_TARGET" in
    A) rauc_slot="rootfs.0" ;;
    B) rauc_slot="rootfs.1" ;;
    *) die "Cannot map slot $FL_TARGET to RAUC identifier" ;;
  esac

  log "Activating slot $FL_TARGET via RAUC ($rauc_slot)"
  rauc status mark-active "$rauc_slot" \
    || die "rauc status mark-active $rauc_slot failed"

  # Verify selected-image (not booted — we haven't rebooted yet).
  local selected
  selected="$(steamos-bootconf selected-image 2>/dev/null)" || true
  if [[ "$selected" != "$FL_TARGET" ]]; then
    die "Post-activation check: selected-image=$selected, expected $FL_TARGET"
  fi
  log "Verified: next boot will use slot $FL_TARGET (selected-image=$selected)"
}

# ── Final verification ────────────────────────────────────────────────────────

flashless_verify_final() {
  log "Final verification before activation"

  local target_mnt
  target_mnt="$(mktemp -d /tmp/flashless-final-verify.XXXXXX)"
  flashless_register_dir "$target_mnt"
  mount -o ro "$FL_TARGET_ROOTFS" "$target_mnt" \
    || die "Could not mount target rootfs for final verification"
  flashless_register_mount "$target_mnt"

  local verify_failed=0

  # manifest.json — must exist and match.
  local manifest="$target_mnt/usr/lib/steamos-atomupd/manifest.json"
  if [[ ! -f "$manifest" ]]; then
    warn "  VERIFY FAILED: manifest.json missing"
    verify_failed=1
  elif ! grep -q "\"variant\"[[:space:]]*:[[:space:]]*\"${TARGET_VARIANT:-steamdeck}\"" "$manifest"; then
    warn "  VERIFY FAILED: manifest.json variant mismatch"
    verify_failed=1
  else
    log "  OK manifest.json variant=${TARGET_VARIANT:-steamdeck}"
  fi

  # os-release — must exist and match.  Check both canonical paths;
  # configure_update_channel writes to whichever /etc/os-release resolves to.
  local os_release=""
  local _candidate
  for _candidate in "$target_mnt/usr/lib/os-release" "$target_mnt/etc/os-release"; do
    if [[ -f "$_candidate" ]] && grep -q "^VARIANT_ID=" "$_candidate" 2>/dev/null; then
      os_release="$_candidate"
      break
    fi
  done
  # Fall back to whichever exists even without VARIANT_ID (will fail the check).
  if [[ -z "$os_release" ]]; then
    for _candidate in "$target_mnt/usr/lib/os-release" "$target_mnt/etc/os-release"; do
      [[ -f "$_candidate" ]] && {
        os_release="$_candidate"
        break
      }
    done
  fi
  if [[ ! -f "$os_release" ]]; then
    warn "  VERIFY FAILED: os-release missing"
    verify_failed=1
  elif ! grep -q "^VARIANT_ID=${TARGET_VARIANT:-steamdeck}$" "$os_release"; then
    warn "  VERIFY FAILED: os-release VARIANT_ID mismatch"
    verify_failed=1
  else
    log "  OK os-release VARIANT_ID=${TARGET_VARIANT:-steamdeck}"
  fi

  # preferences.conf — must exist and match.
  local prefs="$target_mnt/etc/steamos-atomupd/preferences.conf"
  if [[ ! -f "$prefs" ]]; then
    warn "  VERIFY FAILED: preferences.conf missing"
    verify_failed=1
  else
    if ! grep -q "^Variant=${TARGET_VARIANT:-steamdeck}$" "$prefs"; then
      warn "  VERIFY FAILED: preferences.conf Variant mismatch"
      verify_failed=1
    else
      log "  OK preferences.conf Variant=${TARGET_VARIANT:-steamdeck}"
    fi
    if ! grep -q "^Branch=${UPDATE_BRANCH:-stable}$" "$prefs"; then
      warn "  VERIFY FAILED: preferences.conf Branch mismatch"
      verify_failed=1
    else
      log "  OK preferences.conf Branch=${UPDATE_BRANCH:-stable}"
    fi
  fi

  umount "$target_mnt" 2>/dev/null || umount -l "$target_mnt" 2>/dev/null
  flashless_unregister_mount "$target_mnt"
  rmdir "$target_mnt" 2>/dev/null || true

  # Boot artifacts on EFI partition — all three must exist.
  local efi_mnt
  efi_mnt="$(mktemp -d /tmp/flashless-final-efi.XXXXXX)"
  flashless_register_dir "$efi_mnt"
  mount -o ro "$FL_TARGET_EFI" "$efi_mnt" \
    || die "Could not mount target EFI for verification"
  flashless_register_mount "$efi_mnt"

  if [[ ! -f "$efi_mnt/EFI/steamos/grub.cfg" ]]; then
    warn "  VERIFY FAILED: grub.cfg missing from target EFI"
    verify_failed=1
  else
    log "  OK grub.cfg present"
  fi

  if [[ ! -f "$efi_mnt/EFI/steamos/grubx64.efi" ]]; then
    warn "  VERIFY FAILED: grubx64.efi missing from target EFI"
    verify_failed=1
  else
    log "  OK grubx64.efi present"
  fi

  if [[ ! -d "$efi_mnt/SteamOS/partsets" ]]; then
    warn "  VERIFY FAILED: SteamOS/partsets missing from target EFI"
    verify_failed=1
  else
    log "  OK SteamOS/partsets present"
  fi

  umount "$efi_mnt" 2>/dev/null || umount -l "$efi_mnt" 2>/dev/null
  flashless_unregister_mount "$efi_mnt"
  rmdir "$efi_mnt" 2>/dev/null || true

  # Shared ESP bootconf.
  if [[ ! -f "/esp/SteamOS/conf/$FL_TARGET.conf" ]]; then
    warn "  VERIFY FAILED: /esp/SteamOS/conf/$FL_TARGET.conf missing"
    verify_failed=1
  else
    log "  OK /esp/SteamOS/conf/$FL_TARGET.conf present"
  fi

  if ((verify_failed)); then
    die "Final verification failed — do not reboot until issues are resolved"
  fi

  log "Final verification passed"
}

# ── Orchestrator ──────────────────────────────────────────────────────────────

flashless_install() {
  local img="${1:?flashless_install: missing image path}"

  [[ $EUID -eq 0 ]] || die "Flashless install requires root"

  log "=== Flashless install: $img ==="

  trap 'flashless_cleanup' EXIT

  # Phase 1: detect + safety.
  flashless_detect_slots
  flashless_safety_checks

  # Phase 2: attach built image, identify source rootfs, verify it's our build.
  flashless_extract_image "$img"
  flashless_check_sizes

  # Phase 3: reset target partitions.
  flashless_format_target

  # Phase 4: write rootfs (dd → flush → SHA256 verify → btrfstune → btrfs check → resize).
  flashless_write_rootfs

  # Phase 5: detach source image — its partitions may be competing with
  # /dev/disk/by-partsets.  Must succeed; if detach fails, abort.
  losetup -d "$FL_IMG_LOOP" \
    || die "Could not detach source image loop $FL_IMG_LOOP"
  FL_IMG_LOOP=""

  udevadm trigger --action=change \
    "$FL_TARGET_ROOTFS" \
    "$FL_TARGET_EFI" \
    "$FL_TARGET_VAR" \
    || die "Could not retrigger udev for target partitions"

  udevadm settle --timeout=10 \
    || die "udev did not settle after source loop detach"

  # Phase 6: verify partset symlinks returned to the real target partitions.
  flashless_verify_partsets

  # Phase 7: restore /etc state (preferences.conf, manifest, os-release).
  flashless_restore_etc

  # Phase 8: rebuild boot environment via steamos-chroot.
  flashless_rebuild_boot

  # Phase 9: restore original Btrfs ro state (after all rootfs writes).
  flashless_restore_rootfs_ro

  # Phase 10: final verification before activation.
  flashless_verify_final

  # Phase 11: activate target slot.
  flashless_activate_slot

  trap - EXIT

  log "=== Flashless install complete — slot $FL_TARGET is ready ==="
  log "Reboot to activate.  If the new slot fails to boot, SteamOS will"
  log "automatically fall back to slot $FL_CURRENT."
}
