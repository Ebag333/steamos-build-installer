#!/bin/bash
#
# steamos-build-installer — lib/pipeline_init.sh
# Pipeline initialization: ledger setup and crash recovery.
# Sourced by backend entry points before pipeline dispatch.
#
# Requires: common.sh (log, warn, die, debug), mounts.sh (cleanup_ledger_begin, cleanup_recover)
#
# Provides:
#   pipeline_init STATE_ROOT WORKSPACE — initialize ledger for current run
#   pipeline_recover STATE_ROOT — recover incomplete run if exists
#   pipeline_init_check_lock STATE_ROOT — check if workspace is locked (preflight)
#

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/pipeline_init.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_PIPELINE_LEDGER_BASE="${HOME}/.steamos-build/ledger"

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# pipeline_init_check_lock STATE_ROOT
#   Check if the workspace lock is held by another process.
#   Returns 0 if lock is free, 1 if locked (another build running).
#   Used as a preflight check before starting a new build.
pipeline_init_check_lock() {
  local state_root="${1:-$_PIPELINE_LEDGER_BASE}"

  # Ensure state root exists
  if [[ ! -d "$state_root/runs" ]]; then
    return 0 # No runs directory = no locks
  fi

  # Check for any active (non-CLEAN) run directories
  local run_dir
  for run_dir in "$state_root/runs"/*/; do
    [[ -d "$run_dir" ]] || continue

    local manifest="$run_dir/manifest"
    [[ -f "$manifest" ]] || continue

    local run_state
    run_state="$(grep -m1 '^run_state' "$manifest" 2>/dev/null | cut -f2)" || run_state=""

    case "$run_state" in
      ACTIVE | RECOVERING | BLOCKED)
        # Check if lock is held
        local lock_file="$run_dir/.lock"
        if [[ -f "$lock_file" ]]; then
          # Try to acquire lock non-blocking
          local lock_fd=9
          eval "exec ${lock_fd}>\"$lock_file\""
          if ! flock -n "${lock_fd}"; then
            exec {lock_fd}>&- 2>/dev/null || true
            warn "pipeline_init_check_lock: workspace locked by run $(basename "$run_dir") (state=$run_state)"
            return 1
          fi
          # Lock acquired — release it (we just wanted to check)
          exec {lock_fd}>&- 2>/dev/null || true
        fi
        ;;
    esac
  done

  return 0
}

# pipeline_recover STATE_ROOT
#   Check for and recover any incomplete runs.
#   Returns 0 if clean (no recovery needed or recovery succeeded),
#   Returns 1 if recovery failed or workspace is locked.
pipeline_recover() {
  local state_root="${1:-$_PIPELINE_LEDGER_BASE}"

  [[ -d "$state_root/runs" ]] || return 0

  local recovered=0
  local failed=0

  local run_dir
  for run_dir in "$state_root/runs"/*/; do
    [[ -d "$run_dir" ]] || continue

    local manifest="$run_dir/manifest"
    [[ -f "$manifest" ]] || continue

    local run_state
    run_state="$(grep -m1 '^run_state' "$manifest" 2>/dev/null | cut -f2)" || run_state=""

    case "$run_state" in
      ACTIVE | RECOVERING | BLOCKED)
        log "pipeline_recover: recovering incomplete run $(basename "$run_dir") (state=$run_state)"
        if cleanup_recover "$run_dir"; then
          recovered=$((recovered + 1))
        else
          failed=$((failed + 1))
          warn "pipeline_recover: recovery failed for $(basename "$run_dir")"
        fi
        ;;
      CLEAN)
        # Already clean — optionally remove old run dirs
        debug "pipeline_recover: run $(basename "$run_dir") is CLEAN"
        ;;
    esac
  done

  if ((recovered > 0)); then
    log "pipeline_recover: recovered $recovered run(s)"
  fi
  if ((failed > 0)); then
    warn "pipeline_recover: $failed run(s) could not be recovered"
    return 1
  fi

  return 0
}

# pipeline_init STATE_ROOT WORKSPACE
#   Initialize the ledger for the current run.
#   Must be called AFTER pipeline_recover.
#   Sets: _PIPELINE_LEDGER_STATE_ROOT, _PIPELINE_LEDGER_RUN_ID
pipeline_init() {
  local state_root="${1:-$_PIPELINE_LEDGER_BASE}"
  local workspace="${2:?pipeline_init: missing workspace}"

  # Ensure state root exists
  mkdir -p "$state_root/runs" 2>/dev/null || {
    warn "pipeline_init: could not create $state_root/runs"
    return 1
  }

  # Initialize ledger
  if ! cleanup_ledger_begin "$state_root" "$workspace"; then
    warn "pipeline_init: failed to initialize ledger"
    return 1
  fi

  _PIPELINE_LEDGER_STATE_ROOT="$_LEDGER_STATE_ROOT"
  _PIPELINE_LEDGER_RUN_ID="$_LEDGER_RUN_ID"

  log "pipeline_init: ledger initialized (state=$state_root, run=$_PIPELINE_LEDGER_RUN_ID)"
  return 0
}
