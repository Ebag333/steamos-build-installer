#!/bin/bash
#
# steamos-build-installer — lib/flashless.sh
# Flashless install: write the built NVIDIA image directly to the inactive
# A/B slot without a USB stick.  Sourced by the wrapper — do not run directly.
#
# Requires: common.sh, common_system.sh, common_drivers.sh (for
# configure_update_channel), grub.sh (for reconcile_grub).

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/flashless.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

: "${FL_IMG_LOOP:=}"

# ── Slot detection ────────────────────────────────────────────────────────────

# Detect the currently booted and target (inactive) A/B slots.
# Cross-checks steamos-bootconf against RAUC — disagreement or ambiguity is
# fatal.  All target device paths are resolved to canonical /dev/... (not
# symlinks) so a later loop-mount cannot hijack the partset namespace.
_flashless_detect_slots() {
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

# ── Image extraction ──────────────────────────────────────────────────────────

# Loop-mount the built image and identify the source rootfs by GPT PARTLABEL.
# We explicitly select rootfs-A (the partition our builder modifies), then
# mount it read-only and verify it is actually our build.
# Sets: FL_IMG_LOOP, FL_IMG_ROOTFS
_flashless_extract_image() {
  local img="$1"

  [[ -f "$img" ]] || die "Built image not found: $img"

  # Create udev guard BEFORE the loop device exists so udisks2 never sees
  # the partitions as mountable.  Use a broad loop-partition pattern first;
  # the rule is removed on cleanup regardless of which loop device was used.
  local _flashless_udev_rule="/run/udev/rules.d/89-steamos-build-flashless.rules"
  mkdir -p /run/udev/rules.d
  cat "$(_heredoc_dir)/static/flashless-udev.rule" >"$_flashless_udev_rule"
  udevadm control --reload-rules 2>/dev/null || true

  log "Loop-mounting built image: $img"
  FL_IMG_LOOP="$(losetup -f --show --partscan "$img" 2>/dev/null)" \
    || die "Could not loop-mount image"
  cleanup_track_loop "$FL_IMG_LOOP" "$img" "flashless source image"
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
  cleanup_track_tempdir "$verify_mnt" "flashless-verify-src"
  cleanup_mount "$verify_mnt" "flashless-verify-src" -- -o ro "$FL_IMG_ROOTFS" \
    || die "Could not mount source rootfs for build verification"

  # Check manifest variant matches what we built.
  if ! verify_system_config variant "$verify_mnt" "${TARGET_VARIANT:-steamdeck}"; then
    die "Source rootfs-A variant does not match TARGET_VARIANT=${TARGET_VARIANT:-steamdeck}"
  fi

  # Check NVIDIA payload is present — verify the self-heal wrapper is installed.
  # The atomupd wrapper is installed into /usr/bin/ by update-strategy.sh and
  # is always present in an NVIDIA-patched build.
  if [[ ! -f "$verify_mnt/usr/bin/steamos-atomupd-client" ]]; then
    die "Source rootfs-A is not an NVIDIA-patched build (atomupd wrapper missing)"
  fi

  # Capture the source image's update branch so _flashless_restore_etc can
  # preserve it instead of falling back to the hardcoded default.
  local _src_manifest="$verify_mnt/usr/lib/steamos-atomupd/manifest.json"
  FL_SOURCE_BRANCH=""
  if [[ -f "$_src_manifest" ]]; then
    FL_SOURCE_BRANCH="$(
      python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('default_update_branch',''))" \
        "$_src_manifest" 2>/dev/null || true
    )"
  fi
  log "  Source verified: variant=${TARGET_VARIANT:-steamdeck}, branch=${FL_SOURCE_BRANCH:-<not set>}, NVIDIA payload present"

  strict_unmount "$verify_mnt" "flashless source verify"
  cleanup_release "$verify_mnt"
  rmdir "$verify_mnt" 2>/dev/null || true

  log "  Source rootfs: $FL_IMG_ROOTFS (verified as our build)"
}

# ── Size check ────────────────────────────────────────────────────────────────

_flashless_check_sizes() {
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

_flashless_format_target() {
  log "Formatting target EFI: $FL_TARGET_EFI"
  mkfs.vfat -F 32 -n "efi-$FL_TARGET" "$FL_TARGET_EFI" 2>/dev/null \
    || mkfs.vfat -F 32 "$FL_TARGET_EFI" \
    || die "Failed to format target EFI partition"

  log "Formatting target var: $FL_TARGET_VAR"
  mkfs.ext4 -q -F -L "var-$FL_TARGET" "$FL_TARGET_VAR" \
    || die "Failed to format target var partition"
}

# ── Rootfs write ──────────────────────────────────────────────────────────────

_flashless_write_rootfs() {
  local src_bytes tgt_bytes
  src_bytes="$(blockdev --getsize64 "$FL_IMG_ROOTFS" 2>/dev/null)" \
    || die "Could not determine source rootfs size for write"
  tgt_bytes="$(blockdev --getsize64 "$FL_TARGET_ROOTFS" 2>/dev/null)" \
    || die "Could not determine target rootfs size for write"

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
    cleanup_track_tempdir "$resize_mnt" "flashless-resize"
    cleanup_mount "$resize_mnt" "flashless-resize" -- -o compress-force=zstd:3 "$FL_TARGET_ROOTFS" \
      || die "Could not mount target rootfs for resize"
    btrfs filesystem resize max "$resize_mnt" \
      || die "Target rootfs resize failed"
    sync -f "$resize_mnt" 2>/dev/null || sync
    strict_unmount "$resize_mnt" "target after resize" || die "Could not unmount target after resize — aborting to prevent data corruption"
    cleanup_release "$resize_mnt"
    rmdir "$resize_mnt" 2>/dev/null || true
  fi

  log "Rootfs write complete"
}

# ── Partset verification ──────────────────────────────────────────────────────

# After detaching the loop image, verify that /dev/disk/by-partsets has
# returned to pointing at the real target partitions.
_flashless_verify_partsets() {
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
# ---------------------------------------------------------------------------
# Password Migration
# ---------------------------------------------------------------------------

# Copy a user's password hash from the running system to a target rootfs.
# Args: $1 = username, $2 = target root mount point
# Returns 0 on success, 1 on failure.
_flashless_copy_user_password() {
  local user="$1"
  local target_root="$2"
  local hash

  hash="$(getent shadow "$user" 2>/dev/null | cut -d: -f2)" || return 1

  case "$hash" in
    "")
      warn "  No shadow entry/password hash for $user"
      return 1
      ;;
    "!"* | "*"*)
      log "  $user: account is locked/locked — copying lock state"
      ;;
    *)
      log "  $user: copying password hash"
      ;;
  esac

  chroot "$target_root" usermod -p "$hash" "$user" 2>/dev/null
}

# Migrate passwords from the running system to the target rootfs.
# Primarily the deck account, but carries over any UID >= 1000 users.
# Args: $1 = target root mount point
_flashless_migrate_passwords() {
  local target_root="$1"

  log "Migrating user passwords to target slot"

  # Always migrate deck
  _flashless_copy_user_password "deck" "$target_root" || true

  # Migrate any other human users (UID >= 1000, not nobody)
  local user uid
  while IFS=: read -r user _ uid _ _ _ _; do
    [[ "$uid" -ge 1000 && "$user" != "nobody" && "$user" != "deck" ]] || continue
    _flashless_copy_user_password "$user" "$target_root" || true
  done <"/etc/passwd"
}

# The freshly formatted var has no overlay yet, so the rootfs lower /etc
# is authoritative until the first boot creates the runtime overlay.
_flashless_restore_etc() {
  local target_mnt
  target_mnt="$(mktemp -d /tmp/flashless-etc.XXXXXX)" \
    || die "Could not create temporary mount point"
  cleanup_track_tempdir "$target_mnt" "flashless-etc-restore"

  cleanup_mount "$target_mnt" "flashless-etc-restore" -- -o rw "$FL_TARGET_ROOTFS" \
    || die "Could not mount target rootfs for /etc restoration"

  # Clear ro if set — but do NOT restore it here.  reconcile_grub still
  # needs to write to the rootfs.  Restored in _flashless_restore_rootfs_ro()
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

  # Preserve the source image's update branch instead of falling back to
  # the hardcoded default (stable).  FL_SOURCE_BRANCH was captured from the
  # source manifest during _flashless_extract_image.
  if [[ -n "${FL_SOURCE_BRANCH:-}" ]]; then
    UPDATE_BRANCH="$FL_SOURCE_BRANCH"
    log "  Preserving source branch: $UPDATE_BRANCH"
  fi

  configure_update_channel
  MNT="$_saved_mnt"

  # Migrate user passwords from current slot to target slot.
  # Primarily the deck account, but carries over any non-system users.
  _flashless_migrate_passwords "$target_mnt"

  cleanup_disk_space "$target_mnt" "repatch"

  # Persist project files to /home so scripts stay current
  ensure_project_persisted

  sync -f "$target_mnt" 2>/dev/null || sync
  strict_unmount "$target_mnt" "target after etc restore" || die "Could not unmount target after etc restore — aborting to prevent data corruption"
  cleanup_release "$target_mnt"
  rmdir "$target_mnt" 2>/dev/null || true

  log "Target /etc state restored"
}

# ── Boot environment ──────────────────────────────────────────────────────────

_flashless_rebuild_boot() {
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
  cleanup_track_tempdir "$grub_root" "flashless-grub"

  cleanup_mount "$grub_root" "flashless-grub" -- -o rw "$FL_TARGET_ROOTFS" \
    || die "Could not mount target rootfs for GRUB reconciliation"

  log "  Running reconcile_grub for $FL_TARGET"
  reconcile_grub "$grub_root" "$FL_TARGET_EFI" "$FL_TARGET" \
    || die "reconcile_grub failed — kernel command line may be incomplete"

  strict_unmount "$grub_root" "target after grub reconcile" || die "Could not unmount target after grub reconcile — aborting to prevent data corruption"
  cleanup_release "$grub_root"
  rmdir "$grub_root" 2>/dev/null || true

  log "Boot environment rebuilt for slot $FL_TARGET"
}

# ── Restore Btrfs ro ──────────────────────────────────────────────────────────

# Restore the target rootfs's original Btrfs ro property after all
# modifications are complete.  Called once, after reconcile_grub succeeds.
_flashless_restore_rootfs_ro() {
  ((${FL_ROOTFS_WAS_RO:-0})) || return 0

  local mnt
  mnt="$(mktemp -d /tmp/flashless-ro.XXXXXX)" \
    || die "Could not create mountpoint for ro restore"
  cleanup_track_tempdir "$mnt" "flashless-ro-restore"

  cleanup_mount "$mnt" "flashless-ro-restore" -- -o rw "$FL_TARGET_ROOTFS" \
    || die "Could not mount target rootfs to restore ro property"

  btrfs property set -ts "$mnt" ro true \
    || die "Could not restore target Btrfs ro property"

  sync -f "$mnt" 2>/dev/null || sync
  strict_unmount "$mnt" "target after ro restore" || die "Could not unmount target after restoring ro"
  cleanup_release "$mnt"
  rmdir "$mnt" 2>/dev/null || true

  log "Target Btrfs ro property restored"
}

# ── Slot activation ───────────────────────────────────────────────────────────

_flashless_activate_slot() {
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

_flashless_verify_final() {
  log "Final verification before activation"

  local target_mnt
  target_mnt="$(mktemp -d /tmp/flashless-final-verify.XXXXXX)"
  cleanup_track_tempdir "$target_mnt" "flashless-final-verify"
  cleanup_mount "$target_mnt" "flashless-final-verify" -- -o ro "$FL_TARGET_ROOTFS" \
    || die "Could not mount target rootfs for final verification"

  local verify_failed=0

  # variant — manifest.json (both lib paths) + os-release
  if ! verify_system_config variant "$target_mnt" "${TARGET_VARIANT:-steamdeck}"; then
    verify_failed=1
  fi

  strict_unmount "$target_mnt" "flashless final verify"
  cleanup_release "$target_mnt"
  rmdir "$target_mnt" 2>/dev/null || true

  # Boot artifacts on EFI partition — all three must exist.
  local efi_mnt
  efi_mnt="$(mktemp -d /tmp/flashless-final-efi.XXXXXX)"
  cleanup_track_tempdir "$efi_mnt" "flashless-final-efi"
  cleanup_mount "$efi_mnt" "flashless-final-efi" -- -o ro "$FL_TARGET_EFI" \
    || die "Could not mount target EFI for verification"

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
    log "  OK SteamOS/partsets directory present"
    # Verify expected partset entries exist and resolve to correct devices
    local -a _expected_partsets=(rootfs efi var)
    local _partset _resolved
    for _partset in "${_expected_partsets[@]}"; do
      if [[ ! -e "$efi_mnt/SteamOS/partsets/$_partset" ]]; then
        warn "  VERIFY FAILED: SteamOS/partsets/$_partset missing from target EFI"
        verify_failed=1
      else
        # Resolve the symlink and check it points to the expected device
        _resolved="$(readlink -f "$efi_mnt/SteamOS/partsets/$_partset" 2>/dev/null)" || true
        case "$_partset" in
          rootfs)
            if [[ "$_resolved" != "$FL_TARGET_ROOTFS" ]]; then
              warn "  VERIFY FAILED: SteamOS/partsets/$_partset resolves to $_resolved (expected $FL_TARGET_ROOTFS)"
              verify_failed=1
            else
              log "  OK SteamOS/partsets/$_partset resolves to correct device"
            fi
            ;;
          efi)
            if [[ "$_resolved" != "$FL_TARGET_EFI" ]]; then
              warn "  VERIFY FAILED: SteamOS/partsets/$_partset resolves to $_resolved (expected $FL_TARGET_EFI)"
              verify_failed=1
            else
              log "  OK SteamOS/partsets/$_partset resolves to correct device"
            fi
            ;;
          var)
            if [[ "$_resolved" != "$FL_TARGET_VAR" ]]; then
              warn "  VERIFY FAILED: SteamOS/partsets/$_partset resolves to $_resolved (expected $FL_TARGET_VAR)"
              verify_failed=1
            else
              log "  OK SteamOS/partsets/$_partset resolves to correct device"
            fi
            ;;
        esac
      fi
    done
  fi

  strict_unmount "$efi_mnt" "flashless final EFI verify"
  cleanup_release "$efi_mnt"
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

  trap 'rm -f "${_flashless_udev_rule:-}" 2>/dev/null; udevadm control --reload-rules 2>/dev/null || true; cleanup_environment' EXIT

  # Greenfield tracking: set workspace boundary
  cleanup_set_workspace "/tmp" 2>/dev/null || true

  # Ledger: recover from previous run, then initialize
  pipeline_recover || warn "Ledger recovery failed — proceeding without crash recovery"
  pipeline_init "" "/home/.steamos-build" || warn "Ledger initialization failed — proceeding without crash recovery"

  # Phase 1: detect + safety.
  stage_header "preparing & validating"
  _flashless_detect_slots

  # Preflight safety checks
  preflight_validate \
    --scenario "flashless" \
    --rootfs "/" \
    --efi "" \
    --esp "" \
    --slot "$FL_TARGET" \
    --variant "${TARGET_VARIANT:-}"

  # Phase 2: attach built image, identify source rootfs, verify it's our build.
  _flashless_extract_image "$img"
  _flashless_check_sizes

  # Phase 3: reset target partitions.
  stage_header "deploying image to target"
  _flashless_format_target

  # Phase 4: write rootfs (dd → flush → SHA256 verify → btrfstune → btrfs check → resize).
  _flashless_write_rootfs

  # Phase 5: detach source image — its partitions may be competing with
  # /dev/disk/by-partsets.  Must succeed; if detach fails, abort.
  strict_detach_loop "$FL_IMG_LOOP"
  FL_IMG_LOOP=""

  udevadm trigger --action=change \
    "$FL_TARGET_ROOTFS" \
    "$FL_TARGET_EFI" \
    "$FL_TARGET_VAR" \
    || die "Could not retrigger udev for target partitions"

  udevadm settle --timeout=10 \
    || die "udev did not settle after source loop detach"

  # Phase 6: verify partset symlinks returned to the real target partitions.
  _flashless_verify_partsets

  # Phase 7: restore /etc state (manifest, os-release).
  stage_header "configuring target system"
  _flashless_restore_etc

  # Phase 8: rebuild boot environment via steamos-chroot.
  _flashless_rebuild_boot

  # Phase 9: restore original Btrfs ro state (after all rootfs writes).
  _flashless_restore_rootfs_ro

  # Phase 10: final verification before activation.
  stage_header "verification & activation"
  _flashless_verify_final

  # Phase 11: activate target slot.
  _flashless_activate_slot

  trap - EXIT

  log "=== Flashless install complete — slot $FL_TARGET is ready ==="

  local out
  if out="$(steamos-bootconf selected-image 2>&1)"; then
    log "  selected-image: $out"
  else
    log "  selected-image: (unavailable)"
  fi

  if command -v rauc >/dev/null 2>&1; then
    log "  RAUC status:"
    rauc status --detailed 2>&1 | while IFS="" read -r line; do
      log "    $line"
    done
  fi

  log "Reboot to activate.  If the new slot fails to boot, SteamOS will"
  log "automatically fall back to slot $FL_CURRENT."
}
