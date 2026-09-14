#!/bin/bash
#
# steamos-build-installer — lib/common.sh
# Shared helpers: logging/failure reporting, loop/mount primitives, and
# builder cleanup/payload helpers. Sourced by the build backend and repatch.
# Do not run it directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/common.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Resolve the path to the heredocs directory relative to this file
heredoc_dir() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  echo "${dir}/heredocs"
}

# Shared logging/failure framework.  Callers may set these before sourcing:
#   LOG_TAG      short human-readable prefix (default: nvidia-usb)
#   LOGGER_TAG   systemd-journal tag (default: steamos-build)
#   LOG_COLOR    1 for colored terminal prefixes, 0 for plain text
#   RUN_LOG      optional persistent log path included in failure headlines
#
# Callers may also define these optional hooks before or after sourcing:
#   failure_journal_context  -> prints compact caller-specific journal context
#   failure_snapshot_extra   -> emits caller-specific diagnostic sections
# Debug log line — only prints when DEBUG=1.  Goes to stderr to avoid
# polluting pipelines.
debug() { log_debug pipeline debug "$@"; }

: "${LOG_TAG:=nvidia-usb}"
: "${LOGGER_TAG:=steamos-build}"
: "${LOG_COLOR:=1}"
: "${CURRENT_STEP:=startup}"
: "${FAILURE_REPORTED:=0}"
: "${PACMAN_RAW_LOG:=/tmp/steamos-pacman-raw.log}"
: "${PARTITION_DEBUG_LOG:=/tmp/steamos-partition.log}"
: "${DEBUG:=0}"
: "${VERBOSE:=0}"

# When set to 1, cleanup_check_host_namespace() allows cleanup to proceed
# in the init namespace. Use only when entering a specific build's namespace
# via nsenter or when the build's namespace is confirmed dead.
: "${CLEANUP_NAMESPACE_OVERRIDE:=0}"

log() { log_info pipeline log "$@"; }

warn() { log_warn pipeline warn "$@"; }

emit_prefixed_lines() {
  local emitter="${1:?emit_prefixed_lines: missing emitter}"
  local prefix="${2:?emit_prefixed_lines: missing prefix}"
  local text="${3:-}"
  local skip_empty="${4:-0}"
  local line

  [[ -n "$text" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$skip_empty" == 1 && -z "$line" ]] && continue
    "$emitter" "${prefix}${line}"
  done <<<"$text"
}

step() {
  CURRENT_STEP="$*"
  logging_set_step "$*"
  log_info pipeline step "$*"
}

# stage_header LABEL
#   Print a prominent visual separator for a major build stage.
#   LABEL is uppercased automatically.  Uses raw output (no [nvidia-usb]
#   prefix) so headers stand out clearly in log streams.
stage_header() { log_stage pipeline "${1:?stage_header: missing label}"; }

_failure_snapshot() {
  local rc="${1:?_failure_snapshot: missing rc}"
  local line="${2:?_failure_snapshot: missing line}"
  local cmd="${3:-}"
  local reason="${4:-}"
  local source="${5:-}"
  local func="${6:-}"
  local journal_cmd journal_reason journal_context=""

  warn "FAILURE"
  warn "  rc:      $rc"
  warn "  step:    ${CURRENT_STEP:-unknown}"
  warn "  line:    $line"
  warn "  command: $cmd"
  [[ -n "$source" ]] && warn "  file:    $source"
  [[ -n "$func" ]] && warn "  func:    $func"
  [[ -n "$reason" ]] && warn "  reason:  $reason"
  warn "  cwd:     ${PWD:-<unknown>}"
  warn "  env:     WORKDIR=${WORKDIR:-unset} NEWROOT=${NEWROOT:-unset} DEBUG=${DEBUG:-0} VERBOSE=${VERBOSE:-0}"
  if [[ -n "${_LOG_FILE_PATH:-}" ]]; then
    warn "  log:     $_LOG_FILE_PATH"
  fi

  # Full call stack
  local _depth=${#FUNCNAME[@]}
  if ((_depth > 2)); then
    warn "  stack:"
    local _i
    for ((_i = 1; _i <= 10 && _i < _depth; _i++)); do
      local _sf="${BASH_SOURCE[$_i]:-<unknown>}"
      local _ff="${FUNCNAME[$((_i + 1))]:-<toplevel>}"
      local _sl="${BASH_LINENO[$_i]:-?}"
      warn "    $_i: ${_sf}:${_sl} in ${_ff}"
    done
  fi

  # Active shell options (relevant to debugging)
  local _active_opts
  _active_opts="$(set -o 2>/dev/null | grep -E '(errexit|pipefail|nounset|errtrace|tracevars) +on$' | awk '{print $1}' | tr '\n' ' ')" || true
  if [[ -n "$_active_opts" ]]; then
    warn "  shell-options: $_active_opts"
  fi

  if [[ -n "${_PIPESTATUS_STR:-}" && "$_PIPESTATUS_STR" != "0" ]]; then
    warn "  pipestatus: $_PIPESTATUS_STR"
  fi

  journal_cmd="${cmd//$'\n'/ }"
  journal_reason="${reason//$'\n'/ }"
  journal_cmd="${journal_cmd:0:300}"
  journal_reason="${journal_reason:0:300}"

  if declare -F failure_journal_context >/dev/null 2>&1; then
    journal_context="$(failure_journal_context 2>/dev/null || true)"
    journal_context="${journal_context//$'\n'/ }"
    journal_context="${journal_context:0:300}"
  fi

  # Let the caller add domain-specific state (RAUC/slot state for repatch,
  # image/build state for the builder, etc.) without coupling common.sh to it.
  if declare -F failure_snapshot_extra >/dev/null 2>&1; then
    failure_snapshot_extra "$rc" "$line" "$cmd" "$reason" || true
  fi

  log_error pipeline failure-diagnostics "MOUNTS"
  findmnt 2>&1 | log_capture_stream pipeline error mount-info || true

  log_error pipeline failure-diagnostics "LOOP DEVICES"
  losetup -a 2>&1 | log_capture_stream pipeline error loop-info || true

  log_error pipeline failure-diagnostics "SPACE"
  df -h /home 2>&1 | log_capture_stream pipeline error space-info || true

  # Dump raw Pacman log tail on failure
  if [[ -s "${PACMAN_RAW_LOG:-}" ]]; then
    warn "Pacman raw output (last 100 lines):"
    tail -100 "$PACMAN_RAW_LOG" | log_capture_stream pipeline error pacman-output || true
  fi

  # Dump partition debug log tail on failure
  if [[ -s "${PARTITION_DEBUG_LOG:-}" ]]; then
    warn "Partition operations raw output (last 50 lines):"
    tail -50 "$PARTITION_DEBUG_LOG" | log_capture_stream pipeline error partition-output || true
  fi
}

report_failure() {
  local rc="${1:?report_failure: missing rc}"
  local line="${2:?report_failure: missing line}"
  local cmd="${3:-}"
  local reason="${4:-}"
  local source="${5:-}"
  local func="${6:-}"

  # A manually invoked die() might follow a command that returned 0.
  ((rc != 0)) || rc=1

  # Prevent ERR + die, or failures inside diagnostics, from producing
  # multiple snapshots.
  if ((FAILURE_REPORTED)); then
    exit "$rc"
  fi
  FAILURE_REPORTED=1

  trap - ERR
  set +e

  _failure_snapshot "$rc" "$line" "$cmd" "$reason" "$source" "$func"
  exit "$rc"
}

_on_err() {
  local rc=$?
  local line="${1:-${LINENO}}"
  local cmd="${2:-$BASH_COMMAND}"
  local source="${3:-${BASH_SOURCE[1]:-}}"
  local func="${4:-${FUNCNAME[1]:-}}"

  warn "ERR trap fired: line=$line command=$cmd source=$source func=$func"

  # Emit pipeline summary before reporting failure (if a pipeline is active)
  if [[ ${_PIPELINE_ORDER+x} && ${#_PIPELINE_ORDER[@]} -gt 0 ]]; then
    pipeline_print_summary
  fi

  report_failure \
    "$rc" \
    "$line" \
    "$cmd" \
    "unhandled command failure" \
    "$source" \
    "$func"
}

die() {
  # Capture $? immediately so `cmd || die "..."` retains cmd's exit code.
  local rc=$?
  local reason="$*"
  local line="${BASH_LINENO[0]:-${LINENO}}"
  local source="${BASH_SOURCE[1]:-}"
  local func="${FUNCNAME[1]:-}"

  ((rc != 0)) || rc=1

  # Emit pipeline summary before reporting failure (if a pipeline is active)
  if [[ ${_PIPELINE_ORDER+x} && ${#_PIPELINE_ORDER[@]} -gt 0 ]]; then
    pipeline_print_summary
  fi

  report_failure \
    "$rc" \
    "$line" \
    "die: $reason" \
    "$reason" \
    "$source" \
    "$func"
}

# ERR inheritance is required for failures originating inside functions,
# command substitutions, and subshells.  This is already enabled by repatch;
# enabling it here gives the builder the same enriched failure handling.
set -E
trap '_PIPESTATUS_STR="${PIPESTATUS[*]}"; _on_err "$LINENO" "$BASH_COMMAND" "${BASH_SOURCE[1]:-}" "${FUNCNAME[1]:-}"' ERR

# ensure_steamos_build_dirs [BASE_PATH]
#   Create the persistent /home/.steamos-build tree (logs + recovery).
#   Idempotent — safe to call repeatedly; never stomps existing dirs.
#   BASE_PATH defaults to /home; pass $HOMEMNT during image construction.
ensure_steamos_build_dirs() {
  local base="${1:-/home}"
  local root="$base/.steamos-build"

  mkdir -p "$root/logs" "$root/recovery"
  chmod 1777 "$root/recovery"
}

# ---------------------------------------------------------------------------
# Project Persistence (Self-Heal)
# ---------------------------------------------------------------------------
# Persist a copy of the project into /home/.steamos-build/ so users can
# re-run from the device without caching the original scripts.
#
# Self-heal semantics:
#   - Same version → no-op (skip copy)
#   - Newer version → overwrite changed files
#   - Partially deleted/damaged → restore missing files
#   - Never deletes user files (logs/, recovery/)

# Compute a version identifier for the current project tree.
# Uses git describe if available, otherwise hashes key files.
_get_project_version() {
  local src="${1:?_get_project_version: missing source dir}"

  # Prefer git describe (includes tag + commit hash)
  if command -v git &>/dev/null && [[ -d "$src/.git" ]]; then
    git -C "$src" describe --always --dirty 2>/dev/null && return 0
  fi

  # Fallback: hash of key files that change with releases
  local hash_input=""
  for f in "$src/steamos-build.sh" "$src/lib/common.sh" "$src/lib/backend.sh" \
    "$src/lib/library-loader.sh" "$src/lib/configs/customizations.conf"; do
    [[ -f "$f" ]] && hash_input+="$(cat "$f")"
  done

  if [[ -n "$hash_input" ]]; then
    echo "$hash_input" | md5sum | cut -d' ' -f1
  else
    date +%s
  fi
}

# Persist project files into /home/.steamos-build/ with self-heal.
# Args: $1 = source dir (project root), $2 = (optional) target base (default /home)
#
# Copies: steamos-build.sh, lib/, tools/, configs/, build.conf, LICENSE
# Skips: .git/, .idea/, test-*.sh, docs/, __pycache__/
# Preserves: logs/, recovery/, .version
_persist_project_files() {
  local src="${1:?_persist_project_files: missing source dir}"
  local base="${2:-/home}"
  local dest="$base/.steamos-build"
  local version_file="$dest/.version"

  # Compute current version
  local current_version
  current_version="$(_get_project_version "$src")"

  # Check if persisted version matches
  if [[ -f "$version_file" ]]; then
    local persisted_version
    persisted_version="$(cat "$version_file")"
    if [[ "$persisted_version" == "$current_version" ]]; then
      log "Project already persisted at $dest (version $current_version)"
      return 0
    fi
    log "Project version changed ($persisted_version → $current_version) — updating"
  else
    log "Persisting project to $dest"
  fi

  # Ensure target directory exists
  mkdir -p "$dest"

  # Sync project files using rsync if available, otherwise cp
  local copy_rc=0
  if command -v rsync &>/dev/null; then
    if ! rsync -a --delete \
      --exclude='.git/' \
      --exclude='.idea/' \
      --exclude='test-*.sh' \
      --exclude='docs/' \
      --exclude='__pycache__/' \
      --exclude='logs/' \
      --exclude='recovery/' \
      --exclude='.version' \
      "$src/" "$dest/"; then
      warn "rsync failed — falling back to cp"
      _persist_project_files_cp "$src" "$dest" || copy_rc=$?
    fi
  else
    _persist_project_files_cp "$src" "$dest" || copy_rc=$?
  fi

  if ((copy_rc != 0)); then
    warn "Failed to persist project files to $dest (rc=$copy_rc)"
    return 1
  fi

  # Write version stamp
  echo "$current_version" >"$version_file"
  log "Project persisted (version $current_version)"
}

# Fallback copy when rsync is not available.
# Copies specific files/dirs, skips known exclusions.
_persist_project_files_cp() {
  local src="${1:?_persist_project_files_cp: missing source}"
  local dest="${2:?_persist_project_files_cp: missing dest}"

  # Copy top-level files
  local f
  for f in steamos-build.sh steamos-recovery-update-diagnostics.sh build.conf LICENSE README.md; do
    [[ -f "$src/$f" ]] && cp -fp "$src/$f" "$dest/$f"
  done

  # Copy directories
  local d
  for d in lib tools configs; do
    [[ -d "$src/$d" ]] && mkdir -p "$dest/$d" && cp -a "$src/$d/." "$dest/$d/"
  done

  # Ensure all persisted scripts are executable — cp -a preserves source perms,
  # but some tools (atomupd wrapper, repatch) check -x before invoking.
  find "$dest" -name '*.sh' -type f -exec chmod +x {} +
}

# Ensure the project is persisted to /home/.steamos-build/.
# Entry point for all pipelines — handles source detection and calls persist.
# Args: $1 = (optional) source dir (default: $SCRIPT_DIR)
#        $2 = (optional) target base (default: /home)
ensure_project_persisted() {
  local src="${1:-${SCRIPT_DIR:-}}"
  local base="${2:-/home}"

  if [[ -z "$src" || ! -d "$src/lib" ]]; then
    warn "Cannot determine project source directory — skipping persistence"
    return 0
  fi

  ensure_steamos_build_dirs "$base"
  _persist_project_files "$src" "$base"
}

# curl_retry ATTEMPTS [CURL_ARGS...]
#   Run curl with retry on transient failures (network errors, HTTP 5xx).
curl_retry() {
  local attempts="${1:?curl_retry: missing attempt count}"
  if ! [[ "$attempts" =~ ^[0-9]+$ ]] || ((attempts < 1)); then
    warn "curl_retry: attempts must be a positive integer (got: $attempts)"
    return 1
  fi
  shift
  local i
  for ((i = 1; i <= attempts; i++)); do
    if curl "$@"; then
      return 0
    fi
    ((i < attempts)) && {
      warn "curl attempt $i failed, retrying..."
      sleep $((2 ** (i - 1)))
    }
  done
  warn "curl failed after $attempts attempts"
  return 1
}

# Weighted progress tracking.
# Weights are proportional to expected wall-clock time (not step count).
# progress_emit "step_name" at each major milestone; the frontend parses
# @@PROGRESS:XX@@ markers from the log stream to drive a yad progress bar.
_PROGRESS_TOTAL=98
_PROGRESS_SO_FAR=0

progress_emit() { log_progress pipeline progress "$1"; }

persist_debug_logs() {
  debug "persist_debug_logs: WORKDIR=${WORKDIR:-unset} BUILD_ID=${BUILD_ID:-unset}"
  debug "persist_debug_logs: looking for *.log and *.txt files in ${WORKDIR:-unset}"
  [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] || return 0

  # Reuse the BUILD_ID directory created by the frontend when available.
  # Fall back to generating a standalone name only when BUILD_ID is not set
  # (e.g. a bare --action cleanup invocation without a frontend).
  local persist_dir
  if [[ -n "${BUILD_ID:-}" ]]; then
    persist_dir="/home/.steamos-build/logs/${BUILD_ID}"
  else
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    persist_dir="/home/.steamos-build/logs/build-${ts}-$$"
  fi
  mkdir -p "$persist_dir" 2>/dev/null || return 0

  local count=0
  local log_file
  while IFS= read -r -d '' log_file; do
    local rel="${log_file#"$WORKDIR"/}"
    local sub_dir
    sub_dir="$(dirname "$rel")"
    [[ "$sub_dir" != "." ]] && mkdir -p "$persist_dir/$sub_dir"
    cp -- "$log_file" "$persist_dir/$rel" 2>/dev/null && ((++count))
  done < <(find "$WORKDIR" -maxdepth 3 \( -name '*.log' -o -name '*.txt' \) -type f -print0 2>/dev/null)

  if ((count > 0)); then
    log "cleanup: persisted $count diagnostic file(s) to $persist_dir"
    # The build-latest symlink is also created by pipeline_build.sh (which
    # correctly uses BUILD_ID).  Only update it here for the fallback case
    # where BUILD_ID is not set (standalone cleanup).
    if [[ -z "${BUILD_ID:-}" ]]; then
      ln -sfn "$(basename "$persist_dir")" \
        "/home/.steamos-build/logs/build-latest" 2>/dev/null || true
    fi
  fi
}

# cleanup_check_host_namespace
#   Returns 0 if safe to clean up (not in init namespace),
#   Returns 1 if in init namespace (PID 1 mount namespace).
#   Set CLEANUP_NAMESPACE_OVERRIDE=1 to allow cleanup in init namespace
#   when entering a build's namespace via nsenter.
cleanup_check_host_namespace() {
  if [[ -e /proc/self/ns/mnt && -e /proc/1/ns/mnt ]]; then
    if [[ "$(readlink /proc/self/ns/mnt)" == "$(readlink /proc/1/ns/mnt)" ]]; then
      if ((CLEANUP_NAMESPACE_OVERRIDE)); then
        debug "cleanup_check_host_namespace: override active — proceeding in init namespace"
        return 0
      fi
      warn "cleanup_check_host_namespace: running in init namespace — refusing to proceed"
      warn "  Set CLEANUP_NAMESPACE_OVERRIDE=1 only when entering a build namespace via nsenter"
      return 1
    fi
  fi
  return 0
}

# cleanup_stop_background_jobs
#   Stop all background jobs launched by the current shell.
cleanup_stop_background_jobs() {
  local kid
  for kid in $(jobs -p 2>/dev/null); do
    kill "$kid" 2>/dev/null || true
  done
}

# cleanup_remove_udev_rules
#   Remove udev rules created during build.
cleanup_remove_udev_rules() {
  log_debug pipeline cleanup "cleanup_remove_udev_rules: start"
  if [[ -z "${UDEV_RULE:-}" ]]; then
    warn "cleanup_remove_udev_rules: UDEV_RULE is unset; nothing to remove"
    log_debug pipeline cleanup "cleanup_remove_udev_rules: done"
    return 0
  fi
  if [[ ! -f "$UDEV_RULE" ]]; then
    log_debug pipeline cleanup "cleanup_remove_udev_rules: $UDEV_RULE does not exist; skipping"
    log_debug pipeline cleanup "cleanup_remove_udev_rules: done"
    return 0
  fi
  log "cleanup_remove_udev_rules: removing udev rule $UDEV_RULE"
  rm -f "$UDEV_RULE"
  log "cleanup_remove_udev_rules: reloading host udev rules (udevadm control --reload)"
  if ! run_dangerous_cmd udevadm control --reload 2>/dev/null; then
    warn "cleanup_remove_udev_rules: udevadm control --reload failed"
  fi
  log_debug pipeline cleanup "cleanup_remove_udev_rules: done"
}

run_dangerous_cmd() {
  local cmd="${1:?run_dangerous_cmd: missing command}"
  shift

  local _rdc_start_ms _rdc_end_ms _rdc_duration_ms=0
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    local _s _ms
    _s="${EPOCHREALTIME%%.*}"
    _ms="${EPOCHREALTIME#*.}"
    _ms="${_ms:0:3}"
    _rdc_start_ms=$((10#${_s} * 1000 + 10#${_ms}))
  fi

  local _rc=0
  "$cmd" "$@" || _rc=$?

  if [[ -n "${_rdc_start_ms:-}" ]]; then
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
      local _s _ms
      _s="${EPOCHREALTIME%%.*}"
      _ms="${EPOCHREALTIME#*.}"
      _ms="${_ms:0:3}"
      _rdc_end_ms=$((10#${_s} * 1000 + 10#${_ms}))
      _rdc_duration_ms=$((_rdc_end_ms - _rdc_start_ms))
      ((_rdc_duration_ms < 0)) && _rdc_duration_ms=0
    fi
  fi

  local _rdc_in_cleanup="${CLEANUP_RUNNING:-0}"

  local _rdc_args_str="$*"
  ((${#_rdc_args_str} > 200)) && _rdc_args_str="${_rdc_args_str:0:200}…"

  # Sanitize for flat log (remove control chars)
  local _rdc_args_safe="${_rdc_args_str//[[:cntrl:]]/?}"

  if declare -F cleanup_log >/dev/null 2>&1; then
    local _rdc_status="OK"
    ((_rc != 0)) && _rdc_status="FAIL(rc=$_rc)"
    cleanup_log "CMD $_rdc_status ${cmd} ${_rdc_args_safe} (${_rdc_duration_ms}ms cleanup=${_rdc_in_cleanup})"
  fi

  if ((_rc != 0)); then
    log_warn pipeline dangerous-cmd "command failed" \
      cmd "$cmd" args "$_rdc_args_str" rc "$_rc" \
      duration_ms "$_rdc_duration_ms" cleanup "$_rdc_in_cleanup"
  else
    log_debug pipeline dangerous-cmd "command succeeded" \
      cmd "$cmd" args "$_rdc_args_str" rc "$_rc" \
      duration_ms "$_rdc_duration_ms" cleanup "$_rdc_in_cleanup"
  fi

  return "$_rc"
}

# Diff the chroot's new packages against the pristine image db to get the list
# of files that actually ship, then size-check it against available rootfs space.
_compute_payload() {
  # --- input validation (match copy_driver_payload style) ---
  [[ -n "${MNT:-}" ]] || die "_compute_payload: MNT is not set"
  [[ -d "${MNT:-}" ]] || die "_compute_payload: MNT directory not found: $MNT"
  [[ -n "${MERGED:-}" ]] || die "_compute_payload: MERGED is not set"
  [[ -d "${MERGED:-}" ]] || die "_compute_payload: MERGED directory not found: $MERGED"
  [[ -n "${UPPER:-}" ]] || die "_compute_payload: UPPER is not set"
  [[ -d "${UPPER:-}" ]] || die "_compute_payload: UPPER directory not found: $UPPER"
  [[ -n "${KVER:-}" ]] || die "_compute_payload: KVER is not set"
  [[ -n "${WORKDIR:-}" ]] || die "_compute_payload: WORKDIR is not set"

  # "Before" = the pristine image's own pacman db (read directly, host-side) —
  # NOT the chroot's, whose db carries installs cached in the overlay upper
  # layer from previous runs and would make the diff come out empty.
  #
  # Use pacman -Q (name + version) instead of -Qq (name only) so that
  # version upgrades are detected — e.g. nvidia-utils 580→590 would otherwise
  # be invisible to comm since both lines contain the same package name.
  pacman -Q --dbpath "$(resolve_pacman_dbpath "$MNT")" | env LC_ALL=C sort >"$WORKDIR/pkgs-before.txt"
  in_chroot "pacman -Q" | env LC_ALL=C sort >"$WORKDIR/pkgs-after.txt"

  # New or upgraded packages minus build-only toolchain = what ships in the image.
  # The optional extra-exclude file is populated by build modules (e.g. AoTofu)
  # that record their own transitive build-only dependencies.
  compute_new_pkgs "$WORKDIR/pkgs-before.txt" "$WORKDIR/pkgs-after.txt" "$WORKDIR/build-only-exclusions.txt"
  if [[ ${#NEW_PKGS[@]} -eq 0 ]]; then
    log "No runtime package changes — module-only payload"
  else
    log "Payload packages: ${NEW_PKGS[*]}"
  fi

  FILELIST="$WORKDIR/payload-files.txt"
  generate_payload_filelist "$FILELIST" "${NEW_PKGS[@]}"

  if [[ "${TRIM_CUDA:-0}" -eq 1 ]]; then
    log "Trimming CUDA/OpenCL/NVVM/OptiX libraries"
    grep -Ev 'libcuda|libcudadebugger|libnvidia-nvvm|libnvidia-opencl|libnvoptix|nvidia-cuda-mps|OpenCL' \
      "$FILELIST" >"$FILELIST.trim" || true
    mv "$FILELIST.trim" "$FILELIST"
  fi
  sed 's|^/||' "$FILELIST" >"$FILELIST.rel"

  # Space check: pacman -Qlq lists directories too — size only files/symlinks.
  # If no runtime packages changed, PAYLOAD_MB is 0 (module-only update).
  if [[ -s "$FILELIST" ]]; then
    # Guard: run sizing in a function to avoid shell-fragment expansion issues
    # in the command substitution.  The function body is parsed once at define
    # time, not re-parsed from a string.
    _compute_payload_mb() {
      set +o pipefail
      cd "$MERGED" || return 1
      while IFS="" read -r p; do
        if [[ -f "$p" || -L "$p" ]]; then printf '%s\0' "$p"; fi
      done <"$FILELIST.rel" \
        | { du -scm --no-dereference --files0-from=- 2>/dev/null || true; } \
        | tail -1 | cut -f1
    }
    PAYLOAD_MB="$(_compute_payload_mb)" || PAYLOAD_MB=""
    unset -f _compute_payload_mb
    [[ "$PAYLOAD_MB" =~ ^[0-9]+$ ]] || die "Could not size the payload"
  else
    PAYLOAD_MB=0
  fi
  MODULES_MB="$(du -sm "$UPPER/usr/lib/modules/$KVER/updates" | cut -f1)"
  AVAIL_MB="$(df -m --output=avail "$MNT" | tail -1 | tr -d ' ')"
  log "Payload ≈ ${PAYLOAD_MB} MB files + ${MODULES_MB} MB modules (before btrfs zstd); rootfs has ${AVAIL_MB} MB free"
  if ((PAYLOAD_MB + MODULES_MB > AVAIL_MB * 2)); then # zstd roughly halves it
    die "Not enough space in rootfs. Rerun with --trim-cuda."
  fi
}

# ---------------------------------------------------------------------------
# Pacman config helpers
# ---------------------------------------------------------------------------

# Append the standard Arch Linux official repository sections to a pacman
# config file.  Uses the geo-redundant mirror and pacman $repo/$arch
# variables so the resulting config is portable across architectures.
#
# Args: $1 = path to the pacman.conf-style file to append to
append_arch_repos() {
  local conf="${1:?append_arch_repos: missing config path}"

  # Idempotency: only append sections that don't already exist
  if ! grep -q '^\[core\]' "$conf" 2>/dev/null; then
    cat "$(heredoc_dir)/static/pacman-core.conf" >>"$conf"
  fi

  if ! grep -q '^\[extra\]' "$conf" 2>/dev/null; then
    cat "$(heredoc_dir)/static/pacman-extra.conf" >>"$conf"
  fi

  if ! grep -q '^\[multilib\]' "$conf" 2>/dev/null; then
    cat "$(heredoc_dir)/static/pacman-multilib.conf" >>"$conf"
  fi
}
