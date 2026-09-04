#!/bin/bash
# steamos-update compatibility wrapper (steamos-build self-healing updates).
#
# The authoritative repatch hook now lives at steamos-atomupd-client, which is
# shared by Steam/Game Mode and KDE Discover. This wrapper only preserves the
# existing steamos-update interception/logging surface and forwards Valve's
# return code; it must NOT trigger a second repatch.
REAL=/usr/bin/steamos-update.orig

if [[ $EUID -eq 0 ]]; then
  LOGDIR=/home/.steamos-build/logs
else
  LOGDIR="${XDG_STATE_HOME:-$HOME/.local/state}/steamos-build/logs"
fi
mkdir -p "$LOGDIR"
if [[ $EUID -eq 0 ]]; then
  mkdir -p /home/.steamos-build/recovery
  chmod 755 /home/.steamos-build/recovery 2>/dev/null || true
fi

LOG="$LOGDIR/update-$(date +%Y%m%d-%H%M%S)-$$.log"
ln -sfn "$LOG" "$LOGDIR/update-latest.log"

ulog() {
  printf '[steamos-build-update] %s\n' "$*" | tee -a "$LOG" >&2
  logger -t steamos-build-update -- "$*" 2>/dev/null || true
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
