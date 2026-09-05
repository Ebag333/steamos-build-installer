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
declare -ga _PIPELINE_ORDER=()
declare -g _PIPELINE_START_TIME=0

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

  unset _PIPELINE_ORDER
  declare -ga _PIPELINE_ORDER=("$@")

  # Clear the associative arrays
  unset _PIPELINE_PHASES
  unset _PIPELINE_PHASE_DESC
  declare -gA _PIPELINE_PHASES=()
  declare -gA _PIPELINE_PHASE_DESC=()
}

# Register a phase implementation.
# Args: $1 = phase name, $2 = function name, $3 = description (optional)
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

  if ! declare -F "$func" >/dev/null 2>&1; then
    warn "register_phase: '$func' is not a declared function"
    return 1
  fi

  if [[ -n "${_PIPELINE_PHASES[$phase]:-}" ]]; then
    warn "register_phase: phase '$phase' is already registered (overwriting)"
  fi

  _PIPELINE_PHASES["$phase"]="$func"
  _PIPELINE_PHASE_DESC["$phase"]="$desc"
}

# ---------------------------------------------------------------------------
# Pipeline Execution
# ---------------------------------------------------------------------------

# Execute the defined pipeline.
# Args: $@ = (optional) phases to run (empty = run all)
# Returns 0 on success, 1 on failure
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
  log "Starting pipeline ($total_phases phases)"

  local phase_num=0
  local func desc phase_start phase_end phase_duration
  for phase in "${phases_to_run[@]}"; do
    phase_num=$((phase_num + 1))

    func="${_PIPELINE_PHASES[$phase]}"
    desc="${_PIPELINE_PHASE_DESC[$phase]:-$phase}"

    log "[$phase_num/$total_phases] $desc"

    # Execute phase
    phase_start=$(date +%s)

    local phase_rc=0
    "$func" || phase_rc=$?

    phase_end=$(date +%s) || phase_end=$phase_start
    phase_duration=$((phase_end - phase_start))

    if [[ $phase_rc -ne 0 ]]; then
      warn "[$phase_num/$total_phases] $desc failed after ${phase_duration}s"
      _pipeline_report_failure "$phase" "$phase_num" "$total_phases" "${phases_to_run[@]}"
      return 1
    fi

    log "[$phase_num/$total_phases] $desc completed in ${phase_duration}s"
  done

  local pipeline_end
  pipeline_end=$(date +%s)
  local total_duration=$((pipeline_end - _PIPELINE_START_TIME))

  log "Pipeline completed in ${total_duration}s"
  return 0
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
