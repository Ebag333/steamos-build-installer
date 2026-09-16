#!/bin/bash
#
# steamos-build-installer — lib/pipeline.sh
# Workflow pipeline execution engine.
# Provides a framework for defining and executing workflows as a series of phases.
#
# Sourced by workflow entry points — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/pipeline.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Pipeline State
# ---------------------------------------------------------------------------

# Use -gA (global associative) to ensure arrays persist when sourced from functions
declare -gA _PIPELINE_PHASES=()
declare -gA _PIPELINE_PHASE_DESC=()
declare -gA _PIPELINE_PHASE_STAGE=()
declare -ga _PIPELINE_ORDER=()
declare -g _PIPELINE_START_TIME=0
declare -ga _PIPELINE_RESULTS=()
declare -g _PIPELINE_PASSED=0
declare -g _PIPELINE_FAILED=0
declare -g _PIPELINE_NAME=""

# ---------------------------------------------------------------------------
# Pipeline Definition
# ---------------------------------------------------------------------------

# Define a pipeline with ordered phases.
# Args: $@ = phase names (in order)
define_pipeline() {
  if [[ $# -eq 0 ]]; then
    warn "define_pipeline: at least one phase name is required"
    return 1
  fi

  # Validate phase names
  local -A _seen_phases=()
  local _phase
  for _phase in "$@"; do
    if [[ -z "$_phase" ]]; then
      warn "define_pipeline: empty phase name is not allowed"
      return 1
    fi
    if [[ -n "${_seen_phases[$_phase]:-}" ]]; then
      warn "define_pipeline: duplicate phase name '$_phase'"
      return 1
    fi
    _seen_phases["$_phase"]=1
  done

  unset _PIPELINE_ORDER
  declare -ga _PIPELINE_ORDER=("$@")

  # Clear the associative arrays
  unset _PIPELINE_PHASES
  unset _PIPELINE_PHASE_DESC
  unset _PIPELINE_PHASE_STAGE
  declare -gA _PIPELINE_PHASES=()
  declare -gA _PIPELINE_PHASE_DESC=()
  declare -gA _PIPELINE_PHASE_STAGE=()

  # Reset results tracking
  unset _PIPELINE_RESULTS
  declare -ga _PIPELINE_RESULTS=()
  _PIPELINE_PASSED=0
  _PIPELINE_FAILED=0
}

# Register a phase implementation.
# Args: $1 = phase name, $2 = function name, $3 = description (optional), $4 = stage label (optional)
register_phase() {
  if [[ -z "${1:-}" ]]; then
    warn "register_phase: missing phase name"
    return 1
  fi
  if [[ -z "${2:-}" ]]; then
    warn "register_phase: missing function name"
    return 1
  fi
  local phase="$1"
  local func="$2"
  local desc="${3:-}"
  local stage="${4:-}"

  if ! declare -F "$func" >/dev/null 2>&1; then
    warn "register_phase: '$func' is not a declared function"
    return 1
  fi

  if [[ -n "${_PIPELINE_PHASES[$phase]:-}" ]]; then
    warn "register_phase: phase '$phase' is already registered (overwriting)"
  fi

  _PIPELINE_PHASES["$phase"]="$func"
  _PIPELINE_PHASE_DESC["$phase"]="$desc"
  _PIPELINE_PHASE_STAGE["$phase"]="$stage"
}

# ---------------------------------------------------------------------------
# Pipeline Execution
# ---------------------------------------------------------------------------

# Execute the defined pipeline.
# Args: $@ = (optional) phases to run (empty = run all)
# Returns 0 on success, 1 on failure
# shellcheck disable=SC2120  # callers intentionally pass no args to run all phases
run_pipeline() {
  local -a phases_to_run=("$@")
  local total_phases=${#phases_to_run[@]}

  # If no phases specified, run all
  if [[ $total_phases -eq 0 ]]; then
    phases_to_run=("${_PIPELINE_ORDER[@]}")
    total_phases=${#phases_to_run[@]}
  fi

  if [[ $total_phases -eq 0 ]]; then
    warn "run_pipeline: no phases to execute (was define_pipeline called?)"
    return 1
  fi

  # Pre-validate all requested phases before executing any
  local phase
  for phase in "${phases_to_run[@]}"; do
    if [[ -z "${_PIPELINE_PHASES[$phase]:-}" ]]; then
      warn "Unknown phase: $phase"
      return 1
    fi
    local _f="${_PIPELINE_PHASES[$phase]}"
    if [[ -z "$_f" ]] || ! declare -F "$_f" >/dev/null 2>&1; then
      warn "Phase '$phase' has invalid function: '$_f'"
      return 1
    fi
  done

  _PIPELINE_START_TIME=$(date +%s) || _PIPELINE_START_TIME=0

  # Print pipeline header
  local _pipe_name="${_PIPELINE_NAME:-unknown}"
  local _config_name
  if [[ -n "${CONFIG_FILE:-}" ]]; then
    _config_name="$(basename "$CONFIG_FILE" .conf)"
  else
    _config_name="(none)"
  fi
  local _log_path="${_LOG_FILE_PATH:-/dev/stderr}"

  log_notice pipeline separator ""
  log_notice pipeline header "pipeline: $_pipe_name"
  log_notice pipeline header "config: $_config_name"
  log_notice pipeline header "log: $_log_path"
  log_notice pipeline separator ""

  log_notice pipeline header "Starting pipeline ($total_phases phases)"

  # Print phase list header
  local _phase_list=""
  for _p in "${phases_to_run[@]}"; do
    [[ -n "$_phase_list" ]] && _phase_list+="  "
    _phase_list+="· ${_PIPELINE_PHASE_DESC[$_p]:-$_p}"
  done
  log_notice pipeline header "$_phase_list"

  # Track results for summary (global so ERR trap can access them)
  _PIPELINE_RESULTS=()
  _PIPELINE_PASSED=0
  _PIPELINE_FAILED=0

  local phase_num=0
  local func desc phase_start phase_end phase_duration
  local _prev_stage=""
  for phase in "${phases_to_run[@]}"; do
    phase_num=$((phase_num + 1))

    func="${_PIPELINE_PHASES[$phase]}"
    desc="${_PIPELINE_PHASE_DESC[$phase]:-$phase}"

    log "[$phase_num/$total_phases] $desc"

    # Update CURRENT_STEP so the ERR trap failure snapshot shows the correct phase
    # shellcheck disable=SC2034  # cross-file: read by _failure_snapshot() in common.sh
    CURRENT_STEP="${_PIPELINE_PHASE_DESC[$phase]:-$phase}"

    # Execute phase
    phase_start=$(date +%s)

    # Print stage header if stage changed (before capturing phase output)
    local _stage="${_PIPELINE_PHASE_STAGE[$phase]:-}"
    if [[ -n "$_stage" && "$_stage" != "$_prev_stage" ]]; then
      stage_header "$_stage"
    fi
    _prev_stage="$_stage"

    local phase_rc=0
    if [[ "${VERBOSE:-0}" -ne 1 && -t 1 ]]; then
      # Non-verbose CLI mode: capture phase output, show only markers
      local _phase_log
      # Use persistent log dir if BUILD_ID is available, else /tmp
      local _phase_tmp_dir="/tmp"
      if [[ -n "${BUILD_ID:-}" ]]; then
        _phase_tmp_dir="/home/.steamos-build/logs/${BUILD_ID}"
        mkdir -p "$_phase_tmp_dir" 2>/dev/null || _phase_tmp_dir="/tmp"
      fi
      _phase_log="$(mktemp "${_phase_tmp_dir}/steamos-build-phase.XXXXXX")"

      # Install a temporary EXIT trap so die()-induced exits still dump phase output.
      local _saved_phase_exit_trap
      _saved_phase_exit_trap="$(trap -p EXIT)"
      # Extract the command portion for direct execution inside the trap.
      # (Cannot use ' inside the single-quoted trap body, so extract here.)
      local _saved_phase_exit_cmd=""
      if [[ -n "${_saved_phase_exit_trap:-}" ]]; then
        _saved_phase_exit_cmd="${_saved_phase_exit_trap#trap -- \'}"
        _saved_phase_exit_cmd="${_saved_phase_exit_cmd#trap \'}"
        _saved_phase_exit_cmd="${_saved_phase_exit_cmd%\' EXIT}"
      fi
      trap '
        if [[ -n "${_phase_log:-}" && -s "${_phase_log:-}" ]]; then
          warn "Phase output (interrupted by exit):"
          cat "$_phase_log"
          rm -f "$_phase_log"
        fi
        # Execute the saved trap command directly (not just re-register it)
        if [[ -n "${_saved_phase_exit_cmd:-}" ]]; then
          eval "${_saved_phase_exit_cmd}"
        fi
      ' EXIT

      # lint-ignore: merged-streams
      "$func" >"$_phase_log" 2>&1 || phase_rc=$?

      # Phase completed normally — restore EXIT trap and handle output as before.
      trap - EXIT
      eval "${_saved_phase_exit_trap:-trap - EXIT}"

      if [[ $phase_rc -ne 0 && -s "$_phase_log" ]]; then
        warn "Phase output:"
        cat "$_phase_log"
      fi
      rm -f "$_phase_log"
    else
      # Verbose mode or GUI mode: show everything
      "$func" || phase_rc=$?
    fi

    # Detect set +e leaks from phase functions
    if ! [[ -o errexit ]]; then
      warn "Pipeline: errexit was disabled after phase '$phase' — possible set +e leak"
      set -e # Restore it for subsequent phases
    fi

    phase_end=$(date +%s) || phase_end=$phase_start
    phase_duration=$((phase_end - phase_start))

    if [[ $phase_rc -ne 0 ]]; then
      warn "[$phase_num/$total_phases] $desc failed after ${phase_duration}s (rc=$phase_rc)"
      warn "✗ $desc"
      _PIPELINE_RESULTS+=("fail:$desc")
      _PIPELINE_FAILED=$((_PIPELINE_FAILED + 1))

      # Print summary before returning
      pipeline_print_summary "${phases_to_run[@]}"

      _pipeline_report_failure "$phase" "$phase_num" "$total_phases" "${phases_to_run[@]}"
      return 1
    fi

    log "[$phase_num/$total_phases] $desc completed in ${phase_duration}s (rc=$phase_rc)"
    log "✓ $desc"
    _PIPELINE_RESULTS+=("pass:$desc")
    _PIPELINE_PASSED=$((_PIPELINE_PASSED + 1))
  done

  local pipeline_end
  pipeline_end=$(date +%s)
  local total_duration=$((pipeline_end - _PIPELINE_START_TIME))

  # Print final summary
  pipeline_print_summary "${phases_to_run[@]}"

  log "Pipeline completed in ${total_duration}s"
  return 0
}

# Print the final summary line with all phases, results, and counts.
# Args: $@ = phases that were part of this pipeline run
pipeline_print_summary() {
  local _summary=""
  local _skipped=0
  local _p _result _desc _found

  for _p in "${_PIPELINE_ORDER[@]}"; do
    _found=0
    for _result in "${_PIPELINE_RESULTS[@]}"; do
      _desc="${_result#*:}"
      if [[ "$_desc" == "${_PIPELINE_PHASE_DESC[$_p]:-$_p}" ]]; then
        _found=1
        [[ -n "$_summary" ]] && _summary+="  "
        if [[ "$_result" == pass:* ]]; then
          _summary+="✓ $_desc"
        else
          _summary+="✗ $_desc"
        fi
        break
      fi
    done
    if [[ $_found -eq 0 ]]; then
      [[ -n "$_summary" ]] && _summary+="  "
      _summary+="· ${_PIPELINE_PHASE_DESC[$_p]:-$_p} (not reached)"
      _skipped=$((_skipped + 1))
    fi
  done

  log "$_summary"
  log "Results: ${_PIPELINE_PASSED} passed, ${_PIPELINE_FAILED} failed, ${_skipped} skipped"
}

# Report pipeline failure with context.
# Args: $1 = failed phase, $2 = phase number, $3 = total phases, $4... = active phases
_pipeline_report_failure() {
  local failed_phase="${1:?_pipeline_report_failure: missing failed_phase}"
  local phase_num="${2:?_pipeline_report_failure: missing phase_num}"
  local total_phases="${3:?_pipeline_report_failure: missing total_phases}"
  shift 3
  local -a active_phases=("$@")

  local pipeline_end
  pipeline_end=$(date +%s) || pipeline_end=0
  if [[ $_PIPELINE_START_TIME -eq 0 ]]; then
    warn "_pipeline_report_failure called but pipeline start time is not set"
    return 1
  fi
  local total_duration=$((pipeline_end - _PIPELINE_START_TIME))

  local failed_desc="${_PIPELINE_PHASE_DESC[$failed_phase]:-$failed_phase}"
  warn "Pipeline failed at [$phase_num/$total_phases] $failed_desc"
  warn "Total duration before failure: ${total_duration}s"

  # Report remaining phases from the active set, not the full pipeline order
  local remaining=()
  local found=0
  local phase
  for phase in "${active_phases[@]}"; do
    if [[ "$phase" == "$failed_phase" ]]; then
      found=1
      continue
    fi
    if [[ $found -ne 0 ]]; then
      remaining+=("$phase")
    fi
  done

  if [[ ${#remaining[@]} -gt 0 ]]; then
    warn "Remaining phases: ${remaining[*]}"
  fi
}

# ---------------------------------------------------------------------------
# Phase Helpers
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Common Phase Implementations
# ---------------------------------------------------------------------------

# These are placeholder implementations that can be overridden by workflows.
# Workflows should define their own functions and register them.

# Example phase function signature:
# phase_setup() {
#   # Setup logic here
#   return 0
# }
