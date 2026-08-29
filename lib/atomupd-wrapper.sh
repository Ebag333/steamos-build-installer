#!/bin/bash
# steamos-atomupd-client wrapper (steamos-build self-healing updates).
#
# This is the authoritative OS-update interception point. Both Steam/Game Mode
# and KDE Discover ultimately reach steamos-atomupd-client through atomupd.
# Run Valve's real client first; if it actually stages a new OTHER-slot image,
# rebuild the NVIDIA/hardware payload there before reporting success.
#
# If repatch fails, invalidate the staged slot and keep booting the current
# known-good image.

REAL=/usr/bin/steamos-atomupd-client.orig

# Resolve script directory
_NVIDIA_DIR=""
if [[ -d "/home/.steamos-build/build_cache/lib" ]]; then
  _NVIDIA_DIR="/home/.steamos-build/build_cache"
fi

REPATCH="$_NVIDIA_DIR/lib/repatch.sh"
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

alog() {
  echo "[steamos-build-atomupd] $*" | tee -a "$LOG" >&2
  logger -t steamos-build-atomupd -- "$*" 2>/dev/null || true
}

slot_other() {
  case "$1" in
    A) printf 'B\n' ;;
    B) printf 'A\n' ;;
    *) return 1 ;;
  esac
}

boot_value() {
  local slot="${1:?boot_value: missing slot}"
  local key="${2:?boot_value: missing key}"
  local conf="/esp/SteamOS/conf/$slot.conf"

  [[ -f "$conf" ]] || return 1
  sed -n "s/^${key}:[[:space:]]*//p" "$conf" | tail -n1
}

read_build_id_from_root() {
  local root="${1:?read_build_id_from_root: missing root}"
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

read_slot_build_id() {
  local slot="${1:?read_slot_build_id: missing slot}"
  local dev="/dev/disk/by-partsets/$slot/rootfs"
  local realdev existing mnt value rc=1

  [[ -e "$dev" ]] || return 1
  realdev="$(readlink -f "$dev" 2>/dev/null || printf '%s' "$dev")"

  # Reuse an existing mount if the inactive rootfs is already mounted.
  existing="$(findmnt -rn -S "$realdev" -o TARGET 2>/dev/null | head -n1)"
  if [[ -n "$existing" ]]; then
    read_build_id_from_root "$existing"
    return $?
  fi

  # Reading the raw staged rootfs requires root. Non-root callers still get
  # normal Valve-client behaviour; they simply cannot trigger self-heal.
  ((EUID == 0)) || return 1

  mnt="$(mktemp -d /tmp/steamos-build-slot.XXXXXX)" || return 1
  if mount -o ro "$dev" "$mnt" 2>/dev/null; then
    if value="$(read_build_id_from_root "$mnt")"; then
      printf '%s\n' "$value"
      rc=0
    fi
    umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
  fi
  rmdir "$mnt" 2>/dev/null || true
  return "$rc"
}

dump_boot_state() {
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

edit_slot_conf() {
  local slot="${1:?edit_slot_conf: missing slot}"
  shift
  local conf="/esp/SteamOS/conf/$slot.conf"

  [[ -f "$conf" ]] || {
    alog "ERROR: boot config missing for target slot $slot: $conf"
    return 1
  }

  alog "Editing boot config for target slot $slot: $conf"
  sed -i "$@" "$conf" || {
    alog "ERROR: failed editing $conf"
    return 1
  }

  sync -f "$conf" 2>/dev/null || sync
}

verify_slot_boot_value() {
  local slot="${1:?verify_slot_boot_value: missing slot}"
  local key="${2:?verify_slot_boot_value: missing key}"
  local expected="${3-}"
  local actual

  actual="$(boot_value "$slot" "$key" 2>/dev/null)" || return 1
  [[ "$actual" == "$expected" ]]
}

rollback_target() {
  local slot="${1:?rollback_target: missing slot}"
  local ok=1

  alog "Cancelling staged update in slot $slot."

  if ! edit_slot_conf "$slot" \
    -e 's/^boot-requested-at:.*/boot-requested-at: 0/' \
    -e 's/^boot-attempts:.*/boot-attempts: 0/' \
    -e 's/^image-invalid:.*/image-invalid: 1/'; then
    alog "ERROR: failed to invalidate updated slot $slot"
    ok=0
  fi

  if ! verify_slot_boot_value "$slot" image-invalid 1 \
    || ! verify_slot_boot_value "$slot" boot-attempts 0 \
    || ! verify_slot_boot_value "$slot" boot-requested-at 0; then
    alog "ERROR: target slot $slot did not reach rollback state"
    ok=0
  fi

  if steamos-bootconf set-mode booted 2>/dev/null; then
    alog "Restored currently booted slot as boot-ok"
  else
    alog "WARNING: steamos-bootconf set-mode booted failed"
  fi

  dump_boot_state
  ((ok == 1))
}

install_self_into_target() {
  local slot="${1:?install_self_into_target: missing slot}"
  local dev="/dev/disk/by-partsets/$slot/rootfs"
  local mnt btrfs_ro

  [[ -x "$SELF_BUNDLE" ]] || {
    alog "ERROR: self-heal atomupd wrapper bundle is missing: $SELF_BUNDLE"
    return 1
  }
  [[ -e "$dev" ]] || {
    alog "ERROR: target rootfs device is missing: $dev"
    return 1
  }

  mnt="$(mktemp -d /tmp/steamos-build-propagate.XXXXXX)" || return 1
  if ! mount "$dev" "$mnt" 2>/dev/null; then
    alog "ERROR: could not mount $slot rootfs to propagate atomupd wrapper"
    rmdir "$mnt" 2>/dev/null || true
    return 1
  fi

  # repatch normally clears this already, but keep propagation independently
  # safe if Valve stages the root tree with the Btrfs ro property set.
  btrfs_ro="$(btrfs property get -ts "$mnt" ro 2>/dev/null | awk -F= '/^ro=/{print $2}' || true)"
  if [[ "$btrfs_ro" == "true" ]]; then
    btrfs property set -ts "$mnt" ro false || {
      alog "ERROR: could not clear Btrfs ro property on $slot during wrapper propagation"
      umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
      rmdir "$mnt" 2>/dev/null || true
      return 1
    }
  fi

  if [[ ! -e "$mnt/usr/bin/steamos-atomupd-client.orig" ]]; then
    [[ -e "$mnt/usr/bin/steamos-atomupd-client" || -L "$mnt/usr/bin/steamos-atomupd-client" ]] || {
      alog "ERROR: Valve steamos-atomupd-client is missing from staged slot $slot"
      umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
      rmdir "$mnt" 2>/dev/null || true
      return 1
    }
    mv "$mnt/usr/bin/steamos-atomupd-client" \
      "$mnt/usr/bin/steamos-atomupd-client.orig" || {
      alog "ERROR: could not preserve Valve atomupd client in slot $slot"
      umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
      rmdir "$mnt" 2>/dev/null || true
      return 1
    }
  fi

  install -m 755 "$SELF_BUNDLE" "$mnt/usr/bin/steamos-atomupd-client" || {
    alog "ERROR: could not install atomupd self-heal wrapper into slot $slot"
    umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
    rmdir "$mnt" 2>/dev/null || true
    return 1
  }

  sync -f "$mnt/usr/bin/steamos-atomupd-client" 2>/dev/null || sync
  umount "$mnt" 2>/dev/null || {
    alog "ERROR: could not cleanly unmount $slot after wrapper propagation"
    umount -l "$mnt" 2>/dev/null || true
    rmdir "$mnt" 2>/dev/null || true
    return 1
  }
  rmdir "$mnt" 2>/dev/null || true

  alog "Propagated atomupd self-heal wrapper into slot $slot"
}

[[ -x "$REAL" ]] || {
  alog "ERROR: Valve atomupd client is missing or not executable: $REAL"
  exit 127
}

this_before="$(steamos-bootconf this-image 2>/dev/null || true)"
other_before="$(slot_other "$this_before" 2>/dev/null || true)"

build_before=""
build_before_ok=0
request_before=""
request_before_ok=0

if [[ -n "$other_before" ]]; then
  if build_before="$(read_slot_build_id "$other_before" 2>/dev/null)"; then
    build_before_ok=1
  fi
  if request_before="$(boot_value "$other_before" boot-requested-at 2>/dev/null)"; then
    request_before_ok=1
  fi
fi

alog "Starting Valve atomupd client: $REAL $*"
alog "Pre-state: self=${this_before:-unknown} other=${other_before:-unknown} build=${build_before:-unknown} boot-requested-at=${request_before:-unknown}"
dump_boot_state

"$REAL" "$@"
rc=$?

alog "Valve atomupd client returned rc=$rc"
dump_boot_state

# A failed/check/query operation must retain Valve's exact result and must not
# attempt any self-heal work.
if [[ $rc -ne 0 ]]; then
  exit "$rc"
fi

this_after="$(steamos-bootconf this-image 2>/dev/null || true)"
other_after="$(slot_other "$this_after" 2>/dev/null || true)"

# If we cannot prove which inactive slot belongs to the booted image, do not
# guess. The Valve operation succeeded, so preserve its return code.
if [[ -z "$other_before" || -z "$other_after" || "$this_after" != "$this_before" || "$other_after" != "$other_before" ]]; then
  alog "No safe A/B target transition could be established; no repatch triggered."
  exit "$rc"
fi

build_after=""
build_after_ok=0
request_after=""
request_after_ok=0

if build_after="$(read_slot_build_id "$other_after" 2>/dev/null)"; then
  build_after_ok=1
fi
if request_after="$(boot_value "$other_after" boot-requested-at 2>/dev/null)"; then
  request_after_ok=1
fi

alog "Post-state: self=$this_after other=$other_after build=${build_after:-unknown} boot-requested-at=${request_after:-unknown}"

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
  alog "No newly staged OTHER-slot OS image detected; no repatch needed."
  exit "$rc"
fi

alog "Detected staged OS update: $stage_reason"

if [[ $EUID -ne 0 ]]; then
  alog "ERROR: staged OS update detected but atomupd wrapper is not running as root"
  exit 1
fi
[[ -x "$REPATCH" ]] || {
  alog "ERROR: repatch tool is missing or not executable: $REPATCH"
  rollback_target "$other_after" || true
  exit 1
}

# atomupd normally serializes updates, but guard against a concurrent helper
# invocation observing the same just-staged slot.
mkdir -p /run/steamos-build
exec 9>/run/steamos-build/repatch.lock
if command -v flock >/dev/null 2>&1; then
  flock -x 9
fi

# Re-check the target after acquiring the lock. If another invocation already
# rolled the stage back, do not start a second repatch.
request_locked="$(boot_value "$other_after" boot-requested-at 2>/dev/null || true)"
invalid_locked="$(boot_value "$other_after" image-invalid 2>/dev/null || true)"
if [[ "$request_locked" == "0" && "$invalid_locked" == "1" ]]; then
  alog "Target slot was already rolled back by another updater invocation."
  exit 1
fi

alog "Update staged. Starting NVIDIA repatch of partset 'other'."
"$REPATCH" other >>"$LOG" 2>&1
repatch_rc=$?

alog "Repatch returned rc=$repatch_rc"
dump_boot_state

if [[ $repatch_rc -eq 10 ]]; then
  # repatch completed but one or more optional patches failed.
  # The OS update itself is fine — do NOT roll back the staged slot.
  alog "WARNING: SteamOS update installed, but some optional patches failed."
  alog "WARNING: The updated OS slot has been left bootable."
  alog "WARNING: Review the repatch log: $LOG"
elif [[ $repatch_rc -ne 0 ]]; then
  alog "ERROR: Repatch failed critically (rc=$repatch_rc)."
  alog "ERROR: The staged SteamOS update will be cancelled."
  alog "ERROR: Review the repatch log: $LOG"
  rollback_target "$other_after" || alog "ERROR: rollback verification failed"
  exit 1
fi

# Propagate the atomupd wrapper into the new slot, so the next OS update
# is intercepted even after reboot.
if ! install_self_into_target "$other_after"; then
  alog "ERROR: repatch succeeded but atomupd wrapper could not be propagated."
  rollback_target "$other_after" || alog "ERROR: rollback verification failed"
  alog "Details: $LOG"
  exit 1
fi

alog "NVIDIA repatch succeeded; marking updated slot bootable."
if ! edit_slot_conf "$other_after" \
  -e 's/^image-invalid:.*/image-invalid: 0/'; then
  alog "ERROR: updated boot config could not be marked valid"
  rollback_target "$other_after" || alog "ERROR: rollback verification failed"
  exit 1
fi

if ! verify_slot_boot_value "$other_after" image-invalid 0; then
  alog "ERROR: target slot did not verify as image-invalid=0"
  rollback_target "$other_after" || alog "ERROR: rollback verification failed"
  exit 1
fi

alog "Updated slot boot state after activation:"
dump_boot_state
alog "NVIDIA driver installed into updated OS. Safe to reboot."
exit "$rc"
