#!/bin/bash
# steamos-update compatibility wrapper (steamos-build self-healing updates).
#
# The authoritative repatch hook now lives at steamos-atomupd-client, which is
# shared by Steam/Game Mode and KDE Discover. This wrapper only preserves the
# existing steamos-update interception/logging surface and forwards Valve's
# return code; it must NOT trigger a second repatch.
# lint-ignore: strict-mode  # captures child exit codes; logging failures must not block updates
REAL=/usr/bin/steamos-update.orig

if [[ $EUID -eq 0 ]]; then
  LOGDIR=/home/.steamos-build/logs
else
  LOGDIR="${XDG_STATE_HOME:-$HOME/.local/state}/steamos-build/logs"
fi
if ! mkdir -p "$LOGDIR" 2>/dev/null; then
  LOG=/dev/null
else
  LOG="$LOGDIR/update-$(date +%Y%m%d-%H%M%S)-$$.log"
  : >"$LOG"
  ln -sfn "$LOG" "$LOGDIR/update-latest.log"
fi
if [[ $EUID -eq 0 ]]; then
  if mkdir -p /home/.steamos-build/recovery 2>/dev/null; then
    chmod 755 /home/.steamos-build/recovery 2>/dev/null || true
  fi
fi

ulog() {
  printf '[steamos-build-update] %s\n' "$*" | tee -a "$LOG" >&2
  logger -t steamos-build-update -- "$*" 2>/dev/null || true
}

[[ -f "$REAL" && -x "$REAL" ]] || {
  ulog "ERROR: Valve updater is missing or not executable: $REAL"
  exit 127
}

ulog "Starting Valve updater: $REAL $*"
"$REAL" "$@"
rc=$?
ulog "Valve updater returned rc=$rc (atomupd layer owns staged-slot repatch)"
exit "$rc"
