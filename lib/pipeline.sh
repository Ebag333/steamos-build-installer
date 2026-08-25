#!/bin/bash
#
# steamos-nvidia-installer — lib/pipeline.sh
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
declare _PIPELINE_CURRENT_PHASE=""
declare _PIPELINE_START_TIME=0

# ---------------------------------------------------------------------------
# Pipeline Definition
# ---------------------------------------------------------------------------

# Define a pipeline with ordered phases.
# Args: $@ = phase names (in order)
define_pipeline() {
  _PIPELINE_ORDER=("$@")
  # Clear the associative arrays properly
  unset _PIPELINE_PHASES
  unset _PIPELINE_PHASE_DESC
  declare -gA _PIPELINE_PHASES=()
  declare -gA _PIPELINE_PHASE_DESC=()
}

# Register a phase implementation.
# Args: $1 = phase name, $2 = function name, $3 = description (optional)
register_phase() {
  local phase="${1:?register_phase: missing phase name}"
  local func="${2:?register_phase: missing function name}"
  local desc="${3:-}"

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

  _PIPELINE_START_TIME=$(date +%s)

  log "Starting pipeline ($total_phases phases)"

  local phase_num=0
  local phase
  for phase in "${phases_to_run[@]}"; do
    ((phase_num++))
    _PIPELINE_CURRENT_PHASE="$phase"

    # Check if phase is registered
    if [[ -z "${_PIPELINE_PHASES[$phase]:-}" ]]; then
      warn "Unknown phase: $phase"
      return 1
    fi

    local func="${_PIPELINE_PHASES[$phase]}"
    local desc="${_PIPELINE_PHASE_DESC[$phase]:-$phase}"

    log "Phase $phase_num/$total_phases: $desc"
    step "$desc"

    # Execute phase
    local phase_start
    phase_start=$(date +%s)

    if ! "$func"; then
      local phase_end
      phase_end=$(date +%s)
      local phase_duration=$((phase_end - phase_start))

      warn "Phase '$phase' failed after ${phase_duration}s"
      _pipeline_report_failure "$phase" "$phase_num" "$total_phases"
      return 1
    fi

    local phase_end
    phase_end=$(date +%s)
    local phase_duration=$((phase_end - phase_start))

    log "Phase '$phase' completed in ${phase_duration}s"
  done

  local pipeline_end
  pipeline_end=$(date +%s)
  local total_duration=$((pipeline_end - _PIPELINE_START_TIME))

  log "Pipeline completed in ${total_duration}s"
  return 0
}

# Report pipeline failure with context.
# Args: $1 = failed phase, $2 = phase number, $3 = total phases
_pipeline_report_failure() {
  local failed_phase="$1"
  local phase_num="$2"
  local total_phases="$3"

  local pipeline_end
  pipeline_end=$(date +%s)
  local total_duration=$((pipeline_end - _PIPELINE_START_TIME))

  warn "Pipeline failed at phase $phase_num/$total_phases: $failed_phase"
  warn "Total duration before failure: ${total_duration}s"

  # Report remaining phases
  local remaining=()
  local found=0
  local phase
  for phase in "${_PIPELINE_ORDER[@]}"; do
    if [[ "$phase" == "$failed_phase" ]]; then
      found=1
      continue
    fi
    if ((found)); then
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

# Get the current phase name.
get_current_phase() {
  echo "$_PIPELINE_CURRENT_PHASE"
}

# Check if a phase exists in the pipeline.
# Args: $1 = phase name
# Returns 0 if exists, 1 if not
phase_exists() {
  local phase="$1"
  [[ -n "${_PIPELINE_PHASES[$phase]:-}" ]]
}

# Get the list of defined phases.
# Output: one phase per line
list_phases() {
  local phase
  for phase in "${_PIPELINE_ORDER[@]}"; do
    echo "$phase: ${_PIPELINE_PHASE_DESC[$phase]:-}"
  done
}

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

# ---------------------------------------------------------------------------
# Workflow Registration Helpers
# ---------------------------------------------------------------------------

# Register a build workflow pipeline.
register_build_pipeline() {
  define_pipeline \
    "validate" \
    "setup" \
    "prepare" \
    "install" \
    "configure" \
    "finalize"

  register_phase "validate" "phase_build_validate" "Validate build inputs"
  register_phase "setup" "phase_build_setup" "Set up build environment"
  register_phase "prepare" "phase_build_prepare" "Prepare rootfs and overlay"
  register_phase "install" "phase_build_install" "Install drivers and packages"
  register_phase "configure" "phase_build_configure" "Configure system and GRUB"
  register_phase "finalize" "phase_build_finalize" "Finalize and publish image"
}

# Register a repatch workflow pipeline.
register_repatch_pipeline() {
  define_pipeline \
    "mount" \
    "discover" \
    "install" \
    "configure" \
    "reconcile"

  register_phase "mount" "phase_repatch_mount" "Mount target rootfs"
  register_phase "discover" "phase_repatch_discover" "Discover kernel and packages"
  register_phase "install" "phase_repatch_install" "Install drivers and packages"
  register_phase "configure" "phase_repatch_configure" "Configure system and GRUB"
  register_phase "reconcile" "phase_repatch_reconcile" "Reconcile and verify"
}

# Register a live workflow pipeline.
register_live_pipeline() {
  define_pipeline \
    "validate" \
    "configure" \
    "verify"

  register_phase "validate" "phase_live_validate" "Validate target"
  register_phase "configure" "phase_live_configure" "Apply configuration"
  register_phase "verify" "phase_live_verify" "Verify changes"
}
