#!/bin/bash
# steamos-update compatibility wrapper (steamos-build self-healing updates).
#
# The authoritative repatch hook now lives at steamos-atomupd-client, which is
# shared by Steam/Game Mode and KDE Discover. This wrapper only preserves the
# existing steamos-update interception/logging surface and forwards Valve's
# return code; it must NOT trigger a second repatch.
# lint-ignore: strict-mode  # captures child exit codes; logging failures must not block updates
# Resolve script directory
: "${_NVIDIA_DIR:=}"
if [[ -d "/home/.steamos-build/build_cache/lib" ]]; then
  _NVIDIA_DIR="/home/.steamos-build/build_cache"
fi

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

# Source structured logging library.
# _NVIDIA_DIR is resolved above; logging.sh lives alongside this script.
# shellcheck source=lib/logging.sh
source "${_NVIDIA_DIR:+$_NVIDIA_DIR/}lib/logging.sh" 2>/dev/null || {
  # Fallback shim if logging.sh is unavailable (e.g. minimal chroot).
  log_info() {                                                    # lint-ignore: no-shadow
    printf '[steamos-build-update] %s\n' "$3" | tee -a "$LOG" >&2 # lint-ignore: tee-redirect
    logger -t steamos-build-update -- "$3" 2>/dev/null || true
  }
  # shellcheck disable=SC2317  # function definitions inside || block are not unreachable
  log_warn() {                                                          # lint-ignore: no-shadow
    printf '[steamos-build-update] WARN: %s\n' "$3" | tee -a "$LOG" >&2 # lint-ignore: tee-redirect
    logger -t steamos-build-update -- "$3" 2>/dev/null || true
  }
  log_error() {                                                          # lint-ignore: no-shadow
    printf '[steamos-build-update] ERROR: %s\n' "$3" | tee -a "$LOG" >&2 # lint-ignore: tee-redirect
    logger -t steamos-build-update -- "$3" 2>/dev/null || true
  }
}

log_init --log-file "$LOG" --console-level info --no-color 2>/dev/null || true

[[ -f "$REAL" && -x "$REAL" ]] || {
  log_error update valve_updater_missing "Valve updater is missing or not executable: $REAL"
  exit 127
}

log_info update starting "Starting Valve updater" client "$REAL" args "$*"
"$REAL" "$@"
rc=$?
log_info update returned "Valve updater returned (atomupd layer owns staged-slot repatch)" rc "$rc"
exit "$rc"
