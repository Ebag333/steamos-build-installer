#!/bin/bash
# steamos-update wrapper (steamos-nvidia self-healing updates).
# Runs Valve's real updater, then rebuilds the NVIDIA driver inside the
# freshly staged OS slot. If that fails, the update is cancelled: the
# bootloader keeps booting the current (working) image.
REAL=/usr/bin/steamos-update.orig
REPATCH=/usr/lib/steamos-nvidia/repatch.sh
LOGDIR=/home/.steamos-nvidia/logs
mkdir -p "$LOGDIR"

LOG="$LOGDIR/update-$(date +%Y%m%d-%H%M%S)-$$.log"
ln -sfn "$(basename "$LOG")" "$LOGDIR/update-latest.log"

ulog() {
  echo "[steamos-nvidia-update] $*" | tee -a "$LOG" >&2
  logger -t steamos-nvidia-update -- "$*" 2>/dev/null || true
}

is_apply=1
for a in "$@"; do
  case "$a" in check|--supports-duplicate-detection) is_apply=0 ;; esac
done

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
  } >> "$LOG"
}

verify_other_boot_value() {
  local key="$1"
  local expected="$2"
  local this other conf actual

  this="$(steamos-bootconf this-image 2>/dev/null)" || return 1

  case "$this" in
    A) other=B ;;
    B) other=A ;;
    *) return 1 ;;
  esac

  conf="/esp/SteamOS/conf/$other.conf"
  [[ -f "$conf" ]] || return 1

  actual="$(sed -n "s/^${key}:[[:space:]]*//p" "$conf" | tail -n1)"
  [[ "$actual" == "$expected" ]]
}

ulog "Starting Valve updater: $REAL $*"
dump_boot_state

"$REAL" "$@"
rc=$?

ulog "Valve updater returned rc=$rc"
dump_boot_state


# Edit only the opposite A/B slot from the currently booted image.
# The conf files on the ESP are plain text; editing them directly is the
# only revert that reliably steers steamcl (set-mode booted does NOT undo a
# staged switch, and a zeroed boot-requested-at still gets retried while
# boot-attempts is nonzero — both verified the hard way).

edit_other_conf() {
  local this other conf

  this="$(steamos-bootconf this-image 2>/dev/null)" || return 1

  case "$this" in
    A) other=B ;;
    B) other=A ;;
    *)
      ulog "ERROR: cannot determine opposite slot from current image '$this'"
      return 1
      ;;
  esac

  conf="/esp/SteamOS/conf/$other.conf"
  [[ -f "$conf" ]] || {
    ulog "ERROR: boot config missing for target slot $other: $conf"
    return 1
  }

  ulog "Editing boot config for target slot $other: $conf"

  sed -i "$@" "$conf" || {
    ulog "ERROR: failed editing $conf"
    return 1
  }

  sync -f "$conf" 2>/dev/null || sync
}

if [[ $rc -eq 0 && $is_apply -eq 1 ]]; then
  ulog "Update staged. Starting NVIDIA repatch of partset 'other'."
  dump_boot_state

  "$REPATCH" other >> "$LOG" 2>&1
  repatch_rc=$?

  ulog "Repatch returned rc=$repatch_rc"
  dump_boot_state

  if [[ $repatch_rc -eq 0 ]]; then
    ulog "NVIDIA repatch succeeded; marking updated slot bootable."

    if ! edit_other_conf \
        -e 's/^image-invalid:.*/image-invalid: 0/'; then
      ulog "ERROR: repatch succeeded but updated boot config could not be marked valid"
      dump_boot_state
      exit 1
    fi

    if ! verify_other_boot_value image-invalid 0; then
        ulog "WARNING: target slot did not verify as image-invalid=0"
    fi

    ulog "Updated slot boot state after activation:"
    dump_boot_state
    ulog "NVIDIA driver installed into updated OS. Safe to reboot."

  else
    ulog "ERROR: NVIDIA repatch failed; cancelling staged update."

    dump_boot_state

    if ! edit_other_conf \
        -e 's/^boot-requested-at:.*/boot-requested-at: 0/' \
        -e 's/^boot-attempts:.*/boot-attempts: 0/' \
        -e 's/^image-invalid:.*/image-invalid: 1/'; then
      ulog "ERROR: failed to invalidate updated slot"
    fi

    if ! verify_other_boot_value image-invalid 1 \
        || ! verify_other_boot_value boot-attempts 0 \
        || ! verify_other_boot_value boot-requested-at 0; then
        ulog "ERROR: target slot did not reach rollback state (image-invalid=1, boot-attempts=0, boot-requested-at=0)"
        dump_boot_state
        exit 1
    fi

    if steamos-bootconf set-mode booted 2>/dev/null; then
      ulog "Restored currently booted slot as boot-ok"
    else
      ulog "WARNING: steamos-bootconf set-mode booted failed"
    fi

    ulog "Final boot state after rollback:"
    dump_boot_state

    ulog "Details: $LOG"
    exit 1
  fi
fi

exit $rc
