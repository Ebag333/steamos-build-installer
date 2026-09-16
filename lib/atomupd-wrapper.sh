#!/bin/bash
# steamos-atomupd-client wrapper (steamos-build self-healing updates).
#
# This is the authoritative OS-update interception point. Both Steam/Game Mode
# and KDE Discover ultimately reach steamos-atomupd-client through atomupd.
# Run Valve's real client first; if it actually stages a new OTHER-slot image,
# rebuild the NVIDIA/hardware payload there before reporting success.
#
# If rebuild fails, invalidate the staged slot and keep booting the current
# known-good image.

# lint-ignore: strict-mode  # captures child exit codes; rollback logic must execute on failure
REAL=/usr/bin/steamos-atomupd-client.orig

# Resolve script directory
: "${_NVIDIA_DIR:=}"
if [[ -d "/home/.steamos-build/build_cache/lib" ]]; then
  _NVIDIA_DIR="/home/.steamos-build/build_cache"
fi

BACKEND="$_NVIDIA_DIR/lib/backend.sh"
SELF_BUNDLE="$_NVIDIA_DIR/lib/atomupd-wrapper.sh"

if [[ $EUID -eq 0 ]]; then
  LOGDIR=/home/.steamos-build/logs
else
  LOGDIR="${XDG_STATE_HOME:-$HOME/.local/state}/steamos-build/logs"
fi
mkdir -p "$LOGDIR" /home/.steamos-build/recovery
chmod 777 /home/.steamos-build/recovery 2>/dev/null || true

LOG="$LOGDIR/atomupd-$(date +%Y%m%d-%H%M%S)-$$.log"
ln -sfn "$(basename "$LOG")" "$LOGDIR/atomupd-latest.log"

# Source structured logging library.
# _NVIDIA_DIR is resolved above; logging.sh lives alongside this script.
# shellcheck source=lib/logging.sh
source "${_NVIDIA_DIR:+$_NVIDIA_DIR/}lib/logging.sh" 2>/dev/null || {
  # Fallback shim if logging.sh is unavailable (e.g. minimal chroot).
  log_info() {                                                     # lint-ignore: no-shadow
    printf '[steamos-build-atomupd] %s\n' "$3" | tee -a "$LOG" >&2 # lint-ignore: tee-redirect
    logger -t steamos-build-atomupd -- "$3" 2>/dev/null || true
  }
  log_warn() {                                                           # lint-ignore: no-shadow
    printf '[steamos-build-atomupd] WARN: %s\n' "$3" | tee -a "$LOG" >&2 # lint-ignore: tee-redirect
    logger -t steamos-build-atomupd -- "$3" 2>/dev/null || true
  }
  log_error() {                                                           # lint-ignore: no-shadow
    printf '[steamos-build-atomupd] ERROR: %s\n' "$3" | tee -a "$LOG" >&2 # lint-ignore: tee-redirect
    logger -t steamos-build-atomupd -- "$3" 2>/dev/null || true
  }
}

log_init --log-file "$LOG" --console-level info --no-color 2>/dev/null || true

_slot_other() {
  case "$1" in
    A) printf 'B\n' ;;
    B) printf 'A\n' ;;
    *) return 1 ;;
  esac
}

_boot_value() {
  local slot="${1:?_boot_value: missing slot}"
  local key="${2:?_boot_value: missing key}"
  local conf="/esp/SteamOS/conf/$slot.conf"

  [[ -f "$conf" ]] || return 1
  local val
  val="$(sed -n "s/^${key}:[[:space:]]*//p" "$conf")" || return 1
  [[ -n "$val" ]] || return 1
  printf '%s\n' "$val" | tail -n1
}

_read_build_id_from_root() {
  local root="${1:?_read_build_id_from_root: missing root}"
  local osr value=""

  # /usr/lib/os-release is canonical and avoids accidentally following an
  # absolute /etc/os-release symlink outside a temporary slot mount.
  if [[ -r "$root/usr/lib/os-release" ]]; then
    osr="$root/usr/lib/os-release"
  elif [[ -f "$root/etc/os-release" && ! -L "$root/etc/os-release" ]]; then
    osr="$root/etc/os-release"
  else
    return 1
  fi

  value="$(sed -n 's/^BUILD_ID=//p' "$osr" | head -n1)"
  value="${value#\"}"
  value="${value%\"}"
  value="${value#\'}"
  value="${value%\'}"

  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

_read_slot_build_id() {
  local slot="${1:?_read_slot_build_id: missing slot}"
  local dev="/dev/disk/by-partsets/$slot/rootfs"
  local realdev existing mnt value rc=1

  [[ -e "$dev" ]] || return 1
  realdev="$(readlink -f "$dev" 2>/dev/null || printf '%s' "$dev")"

  # Reuse an existing mount if the inactive rootfs is already mounted.
  existing="$(findmnt -rn -S "$realdev" -o TARGET 2>/dev/null | head -n1)"
  if [[ -n "$existing" ]]; then
    _read_build_id_from_root "$existing"
    return $?
  fi

  # Reading the raw staged rootfs requires root. Non-root callers still get
  # normal Valve-client behaviour; they simply cannot trigger self-heal.
  ((EUID == 0)) || return 1

  mnt="$(mktemp -d /tmp/steamos-build-slot.XXXXXX)" || return 1
  if mount -o ro "$dev" "$mnt" 2>/dev/null; then
    if value="$(_read_build_id_from_root "$mnt")"; then
      printf '%s\n' "$value"
      rc=0
    fi
    umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
  fi
  rmdir "$mnt" 2>/dev/null || true
  return "$rc"
}

_dump_boot_state() {
  local slot
  {
    echo "=== SteamOS boot state ==="
    echo "this-image: $(steamos-bootconf this-image 2>&1 || true)"
    echo "selected-image: $(steamos-bootconf selected-image 2>&1 || true)"

    for slot in A B; do
      echo "--- $slot ---"
      steamos-bootconf --image "$slot" config \
        --get boot-attempts \
        --get boot-requested-at \
        --get image-invalid \
        --get comment 2>&1 || true
    done

    rauc status 2>&1 || true
  } >>"$LOG"
}

_edit_slot_conf() {
  local slot="${1:?_edit_slot_conf: missing slot}"
  shift
  local conf="/esp/SteamOS/conf/$slot.conf"

  [[ -f "$conf" ]] || {
    log_error update missing_boot_config "Boot config missing for target slot" slot "$slot" conf "$conf"
    return 1
  }

  log_info update edit_slot_conf "Editing boot config for target slot" slot "$slot" conf "$conf"
  sed -i "$@" "$conf" || {
    log_error update edit_slot_conf_failed "Failed editing boot config" conf "$conf"
    return 1
  }

  sync -f "$conf" 2>/dev/null || sync
}

_verify_slot_boot_value() {
  local slot="${1:?_verify_slot_boot_value: missing slot}"
  local key="${2:?_verify_slot_boot_value: missing key}"
  local expected="${3-}"
  local actual

  actual="$(_boot_value "$slot" "$key" 2>/dev/null)" || return 1
  [[ "$actual" == "$expected" ]]
}

_rollback_target() {
  local slot="${1:?_rollback_target: missing slot}"
  local ok=1

  log_info update rollback "Cancelling staged update in slot" slot "$slot"

  if ! _edit_slot_conf "$slot" \
    -e 's/^boot-requested-at:.*/boot-requested-at: 0/' \
    -e 's/^boot-attempts:.*/boot-attempts: 0/' \
    -e 's/^image-invalid:.*/image-invalid: 1/'; then
    log_error update rollback_failed "Failed to invalidate updated slot" slot "$slot"
    ok=0
  fi

  if ! _verify_slot_boot_value "$slot" image-invalid 1 \
    || ! _verify_slot_boot_value "$slot" boot-attempts 0 \
    || ! _verify_slot_boot_value "$slot" boot-requested-at 0; then
    log_error update rollback_state_failed "Target slot did not reach rollback state" slot "$slot"
    ok=0
  fi

  if steamos-bootconf set-mode booted 2>/dev/null; then
    log_info update boot_ok_restored "Restored currently booted slot as boot-ok"
  else
    log_warn update set_mode_booted_failed "steamos-bootconf set-mode booted failed"
  fi

  _dump_boot_state
  ((ok == 1))
}

_install_self_into_target() {
  local slot="${1:?_install_self_into_target: missing slot}"
  local dev="/dev/disk/by-partsets/$slot/rootfs"
  local mnt btrfs_ro

  [[ -x "$SELF_BUNDLE" ]] || {
    log_error update self_bundle_missing "Self-heal atomupd wrapper bundle is missing" path "$SELF_BUNDLE"
    return 1
  }
  [[ -e "$dev" ]] || {
    log_error update rootfs_missing "Target rootfs device is missing" device "$dev"
    return 1
  }

  mnt="$(mktemp -d /tmp/steamos-build-propagate.XXXXXX)" || return 1
  if ! mount "$dev" "$mnt" 2>/dev/null; then
    log_error update mount_failed "Could not mount rootfs to propagate atomupd wrapper" slot "$slot"
    rmdir "$mnt" 2>/dev/null || true
    return 1
  fi

  # rebuild normally clears this already, but keep propagation independently
  # safe if Valve stages the root tree with the Btrfs ro property set.
  btrfs_ro="$(btrfs property get -ts "$mnt" ro 2>/dev/null | awk -F= '/^ro=/{print $2}' || true)"
  if [[ "$btrfs_ro" == "true" ]]; then
    btrfs property set -ts "$mnt" ro false || {
      log_error update btrfs_ro_clear_failed "Could not clear Btrfs ro property on slot during wrapper propagation" slot "$slot"
      umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
      rmdir "$mnt" 2>/dev/null || true
      return 1
    }
  fi

  if [[ ! -e "$mnt/usr/bin/steamos-atomupd-client.orig" ]]; then
    [[ -e "$mnt/usr/bin/steamos-atomupd-client" || -L "$mnt/usr/bin/steamos-atomupd-client" ]] || {
      log_error update valve_client_missing "Valve steamos-atomupd-client is missing from staged slot" slot "$slot"
      umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
      rmdir "$mnt" 2>/dev/null || true
      return 1
    }
    mv "$mnt/usr/bin/steamos-atomupd-client" \
      "$mnt/usr/bin/steamos-atomupd-client.orig" || {
      log_error update preserve_client_failed "Could not preserve Valve atomupd client in slot" slot "$slot"
      umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
      rmdir "$mnt" 2>/dev/null || true
      return 1
    }
  fi

  install -m 755 "$SELF_BUNDLE" "$mnt/usr/bin/steamos-atomupd-client" || {
    log_error update install_wrapper_failed "Could not install atomupd self-heal wrapper into slot" slot "$slot"
    umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
    rmdir "$mnt" 2>/dev/null || true
    return 1
  }

  sync -f "$mnt/usr/bin/steamos-atomupd-client" 2>/dev/null || sync
  umount "$mnt" 2>/dev/null || {
    log_error update unmount_failed "Could not cleanly unmount after wrapper propagation" slot "$slot"
    log_warn update lazy_unmount_fallback "Falling back to lazy unmount; data integrity may be compromised"
    umount -l "$mnt" 2>/dev/null || true
    # Wait briefly for lazy unmount to release the mount point, then clean up
    local _retries=0
    while ((_retries < 5)); do
      rmdir "$mnt" 2>/dev/null && break
      sleep 1
      _retries=$((_retries + 1))
    done
    rmdir "$mnt" 2>/dev/null || log_warn update rmdir_mount_point_failed "Could not remove mount point" mnt "$mnt"
    return 1
  }
  rmdir "$mnt" 2>/dev/null || true

  log_info update wrapper_propagated "Propagated atomupd self-heal wrapper into slot" slot "$slot"
}

[[ -x "$REAL" ]] || {
  log_error update valve_client_missing_or_not_executable "Valve atomupd client is missing or not executable" path "$REAL"
  exit 127
}

this_before="$(steamos-bootconf this-image 2>/dev/null || true)"
other_before="$(_slot_other "$this_before" 2>/dev/null || true)"

build_before=""
build_before_ok=0
request_before=""
request_before_ok=0

if [[ -n "$other_before" ]]; then
  if build_before="$(_read_slot_build_id "$other_before" 2>/dev/null)"; then
    build_before_ok=1
  fi
  if request_before="$(_boot_value "$other_before" boot-requested-at 2>/dev/null)"; then
    request_before_ok=1
  fi
fi

log_info update starting_valve_client "Starting Valve atomupd client" client "$REAL" args "$*"
log_info update pre_state "Pre-state" self "${this_before:-unknown}" other "${other_before:-unknown}" build "${build_before:-unknown}" boot_requested_at "${request_before:-unknown}"
_dump_boot_state

"$REAL" "$@"
rc=$?

log_info update valve_client_returned "Valve atomupd client returned" rc "$rc"
_dump_boot_state

# A failed/check/query operation must retain Valve's exact result and must not
# attempt any self-heal work.
if [[ $rc -ne 0 ]]; then
  exit "$rc"
fi

this_after="$(steamos-bootconf this-image 2>/dev/null || true)"
other_after="$(_slot_other "$this_after" 2>/dev/null || true)"

# If we cannot prove which inactive slot belongs to the booted image, do not
# guess. The Valve operation succeeded, so preserve its return code.
if [[ -z "$other_before" || -z "$other_after" || "$this_after" != "$this_before" || "$other_after" != "$other_before" ]]; then
  log_info update no_safe_ab_transition "No safe A/B target transition could be established; no rebuild triggered"
  exit "$rc"
fi

build_after=""
build_after_ok=0
request_after=""
request_after_ok=0

if build_after="$(_read_slot_build_id "$other_after" 2>/dev/null)"; then
  build_after_ok=1
fi
if request_after="$(_boot_value "$other_after" boot-requested-at 2>/dev/null)"; then
  request_after_ok=1
fi

log_info update post_state "Post-state" self "$this_after" other "$other_after" build "${build_after:-unknown}" boot_requested_at "${request_after:-unknown}"

stage_reason=""
if ((build_before_ok && build_after_ok)) && [[ "$build_after" != "$build_before" ]]; then
  stage_reason="other-slot BUILD_ID changed: $build_before -> $build_after"
elif ((request_before_ok && request_after_ok)) \
  && [[ "$request_after" != "0" && "$request_after" != "$request_before" ]]; then
  # Fallback for a same-BUILD_ID reinstall: a newly requested boot of OTHER is
  # still a real staged-image transition and must be reconciled.
  stage_reason="other-slot boot-requested-at changed: $request_before -> $request_after"
fi

if [[ -z "$stage_reason" ]]; then
  log_info update no_staged_image "No newly staged OTHER-slot OS image detected; no rebuild needed."
  exit "$rc"
fi

log_info update staged_update_detected "Detected staged OS update: $stage_reason"

if [[ $EUID -ne 0 ]]; then
  log_error update not_root "Staged OS update detected but atomupd wrapper is not running as root"
  exit 1
fi
[[ -x "$BACKEND" ]] || {
  log_error update backend_missing "Rebuild backend is missing or not executable: $BACKEND"
  _rollback_target "$other_after" || true
  exit 1
}

# atomupd normally serializes updates, but guard against a concurrent helper
# invocation observing the same just-staged slot.
mkdir -p /run/steamos-build
exec 9>/run/steamos-build/rebuild.lock
if command -v flock >/dev/null 2>&1; then
  flock -x 9
fi

# Re-check the target after acquiring the lock. If another invocation already
# rolled the stage back, do not start a second rebuild.
request_locked="$(_boot_value "$other_after" boot-requested-at 2>/dev/null || true)"
invalid_locked="$(_boot_value "$other_after" image-invalid 2>/dev/null || true)"
if [[ "$request_locked" == "0" && "$invalid_locked" == "1" ]]; then
  log_info update already_rolled_back "Target slot was already rolled back by another updater invocation."
  exit 1
fi

log_info update rebuild_start "Update staged. Starting NVIDIA rebuild of partset 'other'."
"$BACKEND" --action rebuild --partset other >>"$LOG" 2>&1 # lint-ignore: merged-streams — intentional diagnostic capture; backend has its own structured JSONL log
rebuild_rc=$?

log_info update rebuild_returned "Rebuild returned rc=$rebuild_rc"
_dump_boot_state

if [[ $rebuild_rc -eq 10 ]]; then
  # rebuild completed but one or more optional patches failed.
  # The OS update itself is fine — do NOT roll back the staged slot.
  log_warn update optional_patches_failed "SteamOS update installed, but some optional patches failed."
  log_warn update slot_left_bootable "The updated OS slot has been left bootable."
  log_warn update review_rebuild_log "Review the rebuild log: $LOG"
elif [[ $rebuild_rc -ne 0 ]]; then
  log_error update rebuild_failed "Rebuild failed critically (rc=$rebuild_rc)."
  log_error update cancelling_update "The staged SteamOS update will be cancelled."
  log_error update review_rebuild_log "Review the rebuild log: $LOG"
  _rollback_target "$other_after" || log_error update rollback_verification_failed "Rollback verification failed"
  exit 1
fi

# Propagate the atomupd wrapper into the new slot, so the next OS update
# is intercepted even after reboot.
if ! _install_self_into_target "$other_after"; then
  log_error update propagation_failed "Rebuild succeeded but atomupd wrapper could not be propagated."
  _rollback_target "$other_after" || log_error update rollback_verification_failed "Rollback verification failed"
  log_error update details "Details: $LOG"
  exit 1
fi

log_info update rebuild_succeeded "NVIDIA rebuild succeeded; marking updated slot bootable."
if ! _edit_slot_conf "$other_after" \
  -e 's/^image-invalid:.*/image-invalid: 0/'; then
  log_error update mark_valid_failed "Updated boot config could not be marked valid"
  _rollback_target "$other_after" || log_error update rollback_verification_failed "Rollback verification failed"
  exit 1
fi

if ! _verify_slot_boot_value "$other_after" image-invalid 0; then
  log_error update verify_image_invalid_failed "Target slot did not verify as image-invalid=0"
  _rollback_target "$other_after" || log_error update rollback_verification_failed "Rollback verification failed"
  exit 1
fi

log_info update post_activation_state "Updated slot boot state after activation:"
_dump_boot_state
log_info update safe_to_reboot "NVIDIA driver installed into updated OS. Safe to reboot."
exit "$rc"
