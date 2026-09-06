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
debug() {
  [[ "${DEBUG:-0}" == 1 ]] || return 0
  printf 'DEBUG: %s\n' "$*" >&2
}

# Run a command only when DEBUG=1.  Returns 0 immediately otherwise.
# Use for expensive diagnostics that should not slow normal builds.
debug_cmd() {
  [[ "${DEBUG:-0}" == 1 ]] || return 0
  "$@" || true
}

: "${LOG_TAG:=nvidia-usb}"
: "${LOGGER_TAG:=steamos-build}"
: "${LOG_COLOR:=1}"
: "${CURRENT_STEP:=startup}"
: "${FAILURE_REPORTED:=0}"
: "${PACMAN_RAW_LOG:=/tmp/steamos-pacman-raw.log}"
: "${PARTITION_DEBUG_LOG:=/tmp/steamos-partition.log}"
: "${BTRFS_DEBUG_LOG:=/dev/null}"
: "${DEBUG:=0}"
: "${VERBOSE:=0}"

log() {
  if [[ "${LOG_COLOR:-1}" -eq 1 ]]; then
    printf '\e[1;35m[%s]\e[0m %s\n' "$LOG_TAG" "$*" >&2
  else
    printf '[%s] %s\n' "$LOG_TAG" "$*" >&2
  fi
}

warn() {
  if [[ "${LOG_COLOR:-1}" -eq 1 ]]; then
    printf '\e[1;33m[%s] WARNING:\e[0m %s\n' "$LOG_TAG" "$*" >&2
  else
    printf '[%s] WARNING: %s\n' "$LOG_TAG" "$*" >&2
  fi
}

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
  log "STEP: $CURRENT_STEP"
  logger -t "$LOGGER_TAG" -- "STEP: $CURRENT_STEP" 2>/dev/null || true
}

# stage_header LABEL
#   Print a prominent visual separator for a major build stage.
#   LABEL is uppercased automatically.  Uses raw output (no [nvidia-usb]
#   prefix) so headers stand out clearly in log streams.
stage_header() {
  local label="${1:?stage_header: missing label}"
  local width=60
  local sep
  sep="$(printf '%*s' "$width" '' | tr ' ' '=')"
  if [[ "${LOG_COLOR:-1}" -eq 1 ]]; then
    printf '\e[1;36m%s\n%s\n%s\e[0m\n' "$sep" "${label^^}" "$sep"
  else
    printf '%s\n%s\n%s\n' "$sep" "${label^^}" "$sep"
  fi
}

failure_snapshot() {
  local rc="${1:?failure_snapshot: missing rc}"
  local line="${2:?failure_snapshot: missing line}"
  local cmd="${3:-}"
  local reason="${4:-}"
  local journal_cmd journal_reason journal_context=""

  warn "FAILURE"
  warn "  rc:      $rc"
  warn "  step:    ${CURRENT_STEP:-unknown}"
  warn "  line:    $line"
  warn "  command: $cmd"
  [[ -n "$reason" ]] && warn "  reason:  $reason"

  journal_cmd="${cmd//$'\n'/ }"
  journal_reason="${reason//$'\n'/ }"
  journal_cmd="${journal_cmd:0:300}"
  journal_reason="${journal_reason:0:300}"

  if declare -F failure_journal_context >/dev/null 2>&1; then
    journal_context="$(failure_journal_context 2>/dev/null || true)"
    journal_context="${journal_context//$'\n'/ }"
    journal_context="${journal_context:0:300}"
  fi

  logger -t "$LOGGER_TAG" -- \
    "FAIL rc=$rc step='${CURRENT_STEP:-unknown}' line=$line${journal_context:+ $journal_context} command='$journal_cmd' reason='${journal_reason:-unspecified}' log='${RUN_LOG:-<stdout>}'" \
    2>/dev/null || true

  # Let the caller add domain-specific state (RAUC/slot state for repatch,
  # image/build state for the builder, etc.) without coupling common.sh to it.
  if declare -F failure_snapshot_extra >/dev/null 2>&1; then
    failure_snapshot_extra "$rc" "$line" "$cmd" "$reason" || true
  fi

  echo >&2
  echo "=== MOUNTS ===" >&2
  findmnt 2>&1 || true

  echo >&2
  echo "=== LOOP DEVICES ===" >&2
  losetup -a 2>&1 || true

  echo >&2
  echo "=== SPACE ===" >&2
  df -h /home 2>&1 || df -h 2>&1 || true

  # Dump raw Pacman log tail on failure
  if [[ -s "${PACMAN_RAW_LOG:-}" ]]; then
    warn "Pacman raw output (last 100 lines):"
    tail -100 "$PACMAN_RAW_LOG" >&2
  fi

  # Dump partition debug log tail on failure
  if [[ -s "${PARTITION_DEBUG_LOG:-}" ]]; then
    warn "Partition operations raw output (last 50 lines):"
    tail -50 "$PARTITION_DEBUG_LOG" >&2
  fi
}

report_failure() {
  local rc="${1:?report_failure: missing rc}"
  local line="${2:?report_failure: missing line}"
  local cmd="${3:-}"
  local reason="${4:-}"

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

  failure_snapshot "$rc" "$line" "$cmd" "$reason"
  exit "$rc"
}

on_err() {
  local rc=$?
  local line="${BASH_LINENO[0]:-${LINENO}}"
  local cmd="$BASH_COMMAND"

  report_failure \
    "$rc" \
    "$line" \
    "$cmd" \
    "unhandled command failure"
}

die() {
  # Capture $? immediately so `cmd || die "..."` retains cmd's exit code.
  local rc=$?
  local reason="$*"
  local line="${BASH_LINENO[0]:-${LINENO}}"

  ((rc != 0)) || rc=1

  report_failure \
    "$rc" \
    "$line" \
    "die: $reason" \
    "$reason"
}

# ERR inheritance is required for failures originating inside functions,
# command substitutions, and subshells.  This is already enabled by repatch;
# enabling it here gives the builder the same enriched failure handling.
set -E
trap on_err ERR

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
persist_project_files() {
  local src="${1:?persist_project_files: missing source dir}"
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
  persist_project_files "$src" "$base"
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

progress_emit() {
  local step="${1:?progress_emit: missing step name}"
  local weight=0
  case "$step" in
    decompress) weight=20 ;;
    create_fs) weight=5 ;;
    write_fs) weight=2 ;;
    mount) weight=1 ;;
    resolve_driver) weight=8 ;;
    setup_chroot) weight=5 ;;
    install_headers) weight=5 ;;
    install_driver) weight=25 ;;
    build_hid) weight=2 ;;
    install_hw) weight=15 ;;
    copy_payload) weight=3 ;;
    configure_grub) weight=3 ;;
    patch_installer) weight=1 ;;
    finalize) weight=2 ;;
    cleanup) weight=1 ;;
  esac
  if ((weight > 0)); then
    _PROGRESS_SO_FAR=$((_PROGRESS_SO_FAR + weight))
    ((_PROGRESS_SO_FAR > _PROGRESS_TOTAL)) && _PROGRESS_SO_FAR=$_PROGRESS_TOTAL
    local pct=$((_PROGRESS_SO_FAR * 100 / _PROGRESS_TOTAL))
    printf '%s\n' "@@PROGRESS:$pct@@"
  fi
}

# _persist_debug_logs
#   When DEBUG=1, copy all .log and .txt diagnostic files from WORKDIR to
#   /tmp/steamos-build-logs-<timestamp>-<pid>/ before cleanup removes the
#   workspace.  Preserves the directory structure (e.g. packages/build.log
#   → /tmp/steamos-build-logs-.../packages/build.log).
#   No-op when DEBUG!=1 or WORKDIR is unset/missing.
_persist_debug_logs() {
  [[ "${DEBUG:-0}" == 1 ]] || return 0
  [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] || return 0

  local dest
  dest="/tmp/steamos-build-logs-$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$dest" || return 0

  local count=0
  local log_file
  while IFS= read -r -d '' log_file; do
    local rel="${log_file#"$WORKDIR"/}"
    local sub_dir
    sub_dir="$(dirname "$rel")"
    [[ "$sub_dir" != "." ]] && mkdir -p "$dest/$sub_dir"
    cp -- "$log_file" "$dest/$rel" 2>/dev/null && ((++count))
  done < <(find "$WORKDIR" -maxdepth 3 \( -name '*.log' -o -name '*.txt' \) -type f -print0 2>/dev/null)

  if ((count > 0)); then
    log "cleanup: persisted $count diagnostic file(s) to $dest"
  fi
}

# Tear down everything mounted/created on OUR loop device + the overlay, and
# drop the udisks guard rule. Idempotent — safe to run twice (EXIT trap).
cleanup() {
  local _had_e=0
  [[ -o errexit ]] && _had_e=1
  set +e
  trap - ERR

  local rc=0
  local kid m

  log "cleanup: starting (WORKDIR=${WORKDIR:-<unset>} LOOPDEV=${LOOPDEV:-<unset>} MERGED=${MERGED:-<unset>})"

  # ------------------------------------------------------------
  # Namespace verification: refuse aggressive cleanup when we are
  # running in the init (PID 1) mount namespace.  The build runs
  # inside `unshare --mount --propagation private`; if that
  # namespace is lost, unmount/rm operations would affect the host
  # directly.  Safe operations (udev rule removal, log persistence)
  # are still allowed.
  # ------------------------------------------------------------
  local _IN_INIT_NS=0
  if [[ -e /proc/self/ns/mnt && -e /proc/1/ns/mnt ]]; then
    if [[ "$(readlink /proc/self/ns/mnt)" == "$(readlink /proc/1/ns/mnt)" ]]; then
      _IN_INIT_NS=1
      warn "cleanup: detected init (PID 1) mount namespace — refusing aggressive cleanup"
      warn "cleanup: mount namespace: $(readlink /proc/self/ns/mnt)"
      warn "cleanup: safe operations (udev rules, logs) will proceed"
      warn "cleanup: unmount, loop detach, and workspace removal are skipped"
      warn "cleanup: if the build namespace was lost, a reboot may be needed"
    fi
  fi

  # ------------------------------------------------------------
  # Critical-path guard: refuse to clean up if WORKDIR points at
  # (or is a parent of) a well-known system directory.  An unset
  # or empty WORKDIR is also treated as invalid.
  # ------------------------------------------------------------
  local _WORKDIR_INVALID=0
  if [[ -z "${WORKDIR:-}" ]]; then
    warn "cleanup: WORKDIR is unset or empty — refusing workspace removal"
    _WORKDIR_INVALID=1
  else
    # Resolve to absolute path and strip trailing slash for comparison.
    local _wd_real
    _wd_real="$(realpath "$WORKDIR" 2>/dev/null || true)"
    if [[ -z "$_wd_real" ]]; then
      warn "cleanup: WORKDIR ($WORKDIR) does not resolve — refusing workspace removal"
      _WORKDIR_INVALID=1
    else
      case "$_wd_real" in
        / | /bin | /boot | /dev | /etc | /home | /lib* | /media | /mnt | /opt | /proc | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /var)
          warn "cleanup: WORKDIR ($_wd_real) is a critical system path — refusing workspace removal"
          _WORKDIR_INVALID=1
          ;;
      esac
    fi
  fi

  # Stop background children owned by this shell.
  local kid_count=0
  for kid in $(jobs -p 2>/dev/null); do
    kill "$kid" 2>/dev/null || true
    wait "$kid" 2>/dev/null || true
    ((++kid_count))
  done
  ((kid_count > 0)) && log "cleanup: stopped $kid_count background child(ren)"

  # ------------------------------------------------------------
  # Aggressive cleanup: overlay teardown, unmounts, loop detach.
  # Skipped entirely when running in the init namespace.
  # ------------------------------------------------------------
  if ((_IN_INIT_NS)); then
    warn "cleanup: skipping overlay teardown (in init namespace)"
    warn "cleanup: skipping filesystem unmounts (in init namespace)"
    warn "cleanup: skipping loop detach (in init namespace)"
    rc=1
  else
    # Overlay must disappear before its lower filesystem.
    log "cleanup: tearing down overlay"
    if ! overlay_cleanup; then
      warn "cleanup: overlay teardown incomplete"
      warn "cleanup: refusing to unmount main image filesystems underneath it"
      warn "cleanup: this is typically caused by the kernel's jbd2 journal thread"
      warn "cleanup: holding an ext4 superblock after unmount. A reboot will"
      warn "cleanup: release all resources cleanly."
      rc=1
    else
      log "cleanup: overlay teardown complete"

      # ----------------------------------------------------------
      # Main image filesystem mounts.
      # ----------------------------------------------------------
      for m in "${HOMEMNT:-}" "${EFIMNT:-}" "${MNT:-}"; do
        [[ -n "$m" ]] || continue

        if mountpoint -q "$m" 2>/dev/null; then
          log "cleanup: unmounting $m"
          if strict_unmount "$m" "main image filesystem"; then
            untrack_mount "$m" 2>/dev/null || true
          else
            warn "cleanup: failed to unmount $m"
            rc=1
          fi
        fi
      done

      # ----------------------------------------------------------
      # Main image loop.
      # ----------------------------------------------------------
      if [[ -n "${LOOPDEV:-}" ]]; then
        log "cleanup: detaching main loop $LOOPDEV"
        local loop_mounts
        loop_mounts="$(mounts_for_loop "$LOOPDEV")"
        if [[ -n "$loop_mounts" ]]; then
          log "cleanup: $LOOPDEV has remaining mounts:"
          emit_prefixed_lines log "    " "$loop_mounts"
        fi

        if ((rc == 0)); then
          while IFS="" read -r m; do
            [[ -n "$m" ]] || continue
            if ! strict_unmount "$m" "remaining mount from $LOOPDEV"; then
              rc=1
            fi
          done < <(mounts_for_loop "$LOOPDEV")

          if ((rc == 0)); then
            strict_detach_loop "$LOOPDEV" || rc=1
          fi
        else
          warn "cleanup: skipping loop detach (previous errors)"
        fi
      fi
    fi
  fi

  # Udev rule itself is safe to remove regardless of mount cleanup result.
  if [[ -n "${UDEV_RULE:-}" && -f "$UDEV_RULE" ]]; then
    log "cleanup: removing udev rule $UDEV_RULE"
    rm -f "$UDEV_RULE"
    udevadm control --reload 2>/dev/null || true
  fi

  # ------------------------------------------------------------
  # Final diagnostics — skipped in init namespace since we know
  # loops/mounts were not cleaned up by us.
  # ------------------------------------------------------------
  if ((_IN_INIT_NS)); then
    warn "cleanup: skipping final diagnostics (in init namespace)"
  else
    if [[ -n "${OVL_IMG:-}" ]]; then
      local remaining
      remaining="$(loops_for_file "$OVL_IMG")"

      if [[ -n "$remaining" ]]; then
        warn "cleanup: overlay workspace still attached:"
        emit_prefixed_lines warn "  " "$remaining"
        rc=1
      fi
    fi

    if [[ -n "${LOOPDEV:-}" ]] \
      && losetup "$LOOPDEV" >/dev/null 2>&1; then
      warn "cleanup: main image loop still attached: $LOOPDEV"
      losetup "$LOOPDEV" >&2 2>/dev/null || true
      warn "cleanup: a reboot may be required to release this loop device"
      rc=1
    fi
  fi

  # ------------------------------------------------------------
  # Persist debug logs — safe to do in any namespace.
  # ------------------------------------------------------------
  _persist_debug_logs

  # ------------------------------------------------------------
  # Remove build workspace — skipped in init namespace to avoid
  # deleting files that belong to the host, and skipped when
  # WORKDIR is unset, unresolvable, or points at a critical path.
  # ------------------------------------------------------------
  if ((_WORKDIR_INVALID)); then
    warn "cleanup: skipping workspace removal (WORKDIR is invalid or critical)"
  elif ((_IN_INIT_NS)); then
    warn "cleanup: skipping workspace removal (in init namespace)"
  elif ((rc == 0)) && [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then
    log "cleanup: removing build workspace: $WORKDIR"
    rm -rf "$WORKDIR" 2>/dev/null || warn "cleanup: could not remove $WORKDIR"
  elif ((rc != 0)) && [[ -n "${WORKDIR:-}" ]]; then
    warn "cleanup: skipping workspace removal — manually remove ${WORKDIR:-} when loop devices are fully released"
  fi

  log "cleanup: finished (rc=$rc)"
  [[ "$_had_e" -eq 1 ]] && set -e
  return "$rc"
}

# Diff the chroot's new packages against the pristine image db to get the list
# of files that actually ship, then size-check it against available rootfs space.
compute_payload() {
  # --- input validation (match copy_driver_payload style) ---
  [[ -n "${MNT:-}" ]] || die "compute_payload: MNT is not set"
  [[ -d "${MNT:-}" ]] || die "compute_payload: MNT directory not found: $MNT"
  [[ -n "${MERGED:-}" ]] || die "compute_payload: MERGED is not set"
  [[ -d "${MERGED:-}" ]] || die "compute_payload: MERGED directory not found: $MERGED"
  [[ -n "${UPPER:-}" ]] || die "compute_payload: UPPER is not set"
  [[ -d "${UPPER:-}" ]] || die "compute_payload: UPPER directory not found: $UPPER"
  [[ -n "${KVER:-}" ]] || die "compute_payload: KVER is not set"
  [[ -n "${WORKDIR:-}" ]] || die "compute_payload: WORKDIR is not set"

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
    cat >>"$conf" <<'EOF'

[core]
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
EOF
  fi

  if ! grep -q '^\[extra\]' "$conf" 2>/dev/null; then
    cat >>"$conf" <<'EOF'

[extra]
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
EOF
  fi

  if ! grep -q '^\[multilib\]' "$conf" 2>/dev/null; then
    cat >>"$conf" <<'EOF'

[multilib]
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
EOF
  fi
}
