#!/bin/bash
# steamos-update compatibility wrapper (steamos-nvidia self-healing updates).
#
# The authoritative repatch hook now lives at steamos-atomupd-client, which is
# shared by Steam/Game Mode and KDE Discover. This wrapper only preserves the
# existing steamos-update interception/logging surface and forwards Valve's
# return code; it must NOT trigger a second repatch.
REAL=/usr/bin/steamos-update.orig

if [[ $EUID -eq 0 ]]; then
  LOGDIR=/home/.steamos-nvidia/logs
else
  LOGDIR="${XDG_STATE_HOME:-$HOME/.local/state}/steamos-nvidia/logs"
fi
mkdir -p "$LOGDIR" /home/.steamos-nvidia/recovery
chmod 777 /home/.steamos-nvidia/recovery 2>/dev/null || true

LOG="$LOGDIR/update-$(date +%Y%m%d-%H%M%S)-$$.log"
ln -sfn "$(basename "$LOG")" "$LOGDIR/update-latest.log"

ulog() {
  echo "[steamos-nvidia-update] $*" | tee -a "$LOG" >&2
  logger -t steamos-nvidia-update -- "$*" 2>/dev/null || true
}

[[ -x "$REAL" ]] || {
  ulog "ERROR: Valve updater is missing or not executable: $REAL"
  exit 127
}

ulog "Starting Valve updater: $REAL $*"
"$REAL" "$@"
rc=$?
ulog "Valve updater returned rc=$rc (atomupd layer owns staged-slot repatch)"
exit "$rc"
