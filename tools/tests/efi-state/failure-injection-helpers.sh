#!/bin/bash
#
# tools/tests/efi-state/failure-injection-helpers.sh
# Scenario-agnostic failure injection infrastructure for EFI state tests.
#
# Provides a toolkit for injecting controlled failures during EFI state
# application tests: I/O failures via permission manipulation, signal
# injection via background subshells, transaction marker injection,
# rollback failure simulation, partial activation scenarios, and
# emergency cleanup verification.
#
# Usage:
#   source tools/tests/efi-state/failure-injection-helpers.sh
#
# Dependencies:
#   - test-harness.sh    (assertion helpers, test lifecycle)
#
# Design constraints:
#   - All I/O failure injection uses permission-based approaches (no LD_PRELOAD)
#   - Transaction markers are JSON-like files for machine-readable state
#   - All cleanup functions are idempotent (safe to call multiple times)
#   - Signal injection uses background subshells + kill
#   - No external tools beyond coreutils, bash, and standard Unix utilities

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "failure-injection-helpers.sh is a library — source it, don't run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Guard: ensure required libraries are loaded
# ---------------------------------------------------------------------------
if ! declare -f test_harness_init >/dev/null 2>&1; then
  echo "ERROR: failure-injection-helpers.sh requires test-harness.sh (source it first)." >&2
  return 1 2>/dev/null || exit 1
fi

# ===========================================================================
# Internal state for cleanup tracking
# ===========================================================================
_FI_CLEANUP_REGISTERED=0
_FI_SNAPSHOT_DIR=""
_FI_EMERGENCY_CLEANUP_HANDLERS=()
_FI_SIGNAL_PID=""
_FI_SIGNAL_PHASE_FILE=""

# ===========================================================================
# fi_send_signal_at_phase SIGNAL PHASE_FILE TIMEOUT_SECS
#
# Wait for a phase marker file to appear, then send a signal to the
# background process that is writing it. This is the core mechanism for
# injecting signals at controlled points during an operation.
#
# Usage:
#   # In the background task:
#   touch "$PHASE_FILE"   # signals "phase started"
#   sleep 999             # simulate work
#
#   # In the caller:
#   fi_send_signal_at_phase SIGTERM "$PHASE_FILE" 5
#
# Arguments:
#   SIGNAL       - Signal to send (e.g. SIGTERM, SIGINT, SIGUSR1)
#   PHASE_FILE   - Path to the phase marker file
#   TIMEOUT_SECS - Maximum seconds to wait for the phase marker (default: 10)
#
# Returns:
#   0 - Signal sent successfully
#   1 - Timeout waiting for phase marker
# ===========================================================================
fi_send_signal_at_phase() {
  local signal="${1:?fi_send_signal_at_phase: missing SIGNAL}"
  local phase_file="${2:?fi_send_signal_at_phase: missing PHASE_FILE}"
  local timeout_secs="${3:-10}"

  local waited=0
  while [[ ! -f "$phase_file" ]] && [[ "$waited" -lt "$timeout_secs" ]]; do
    sleep 0.1
    waited=$((waited + 1))
  done

  if [[ ! -f "$phase_file" ]]; then
    echo "ERROR: fi_send_signal_at_phase: timed out waiting for phase marker: $phase_file" >&2
    return 1
  fi

  # Read PID from the phase marker file
  local target_pid
  target_pid="$(cat "$phase_file" 2>/dev/null)"

  if [[ -z "$target_pid" || ! "$target_pid" =~ ^[0-9]+$ ]]; then
    echo "ERROR: fi_send_signal_at_phase: invalid PID in phase marker: '$target_pid'" >&2
    return 1
  fi

  if ! kill -0 "$target_pid" 2>/dev/null; then
    echo "ERROR: fi_send_signal_at_phase: process $target_pid is not running" >&2
    return 1
  fi

  kill -"$signal" "$target_pid" 2>/dev/null
  if [[ $? -ne 0 ]]; then
    echo "ERROR: fi_send_signal_at_phase: failed to send $signal to PID $target_pid" >&2
    return 1
  fi

  return 0
}

# ===========================================================================
# fi_run_with_signal_at_phase FUNC [ARGS...] SIGNAL PHASE_NAME TIMEOUT_SECS
#
# Run a function in a background subshell, then send a signal after a
# named phase begins. The function receives its arguments normally.
# A phase marker file is created in a temporary location; the function
# should `touch "$FI_PHASE_FILE"` when it reaches the named phase.
#
# Usage:
#   my_func() {
#     echo "phase-1" >&2
#     touch "$FI_PHASE_FILE"    # signal phase started
#     sleep 999                 # work after phase
#   }
#   fi_run_with_signal_at_phase my_func SIGTERM "phase-1" 5
#
# The caller's cleanup will be handled automatically.
#
# Arguments:
#   FUNC         - Function to run in a subshell
#   [ARGS...]    - Arguments to pass to the function
#   SIGNAL       - Signal to send after phase begins (second-to-last arg)
#   PHASE_NAME   - Name of the phase to wait for (third-to-last arg)
#   TIMEOUT_SECS - Max seconds to wait for phase (last arg, default: 10)
#
# Sets:
#   FI_PHASE_FILE - Path the function should touch when phase begins
#
# Returns:
#   0 - Function ran and was signaled successfully
#   1 - Error in setup or signal delivery
# ===========================================================================
fi_run_with_signal_at_phase() {
  local func="${1:?fi_run_with_signal_at_phase: missing FUNC}"
  shift

  # Parse last three args: SIGNAL PHASE_NAME TIMEOUT_SECS
  local timeout_secs="${!#}"
  local phase_name="${(($#-1))}"
  local signal="${(($#-2))}"

  # Remove last three positional args, remaining are FUNC args
  local -a func_args=("${@:1:$(($#-3))}")

  # Create phase marker file
  _FI_SIGNAL_PHASE_FILE="$(mktemp "${TMPDIR:-/tmp}/fi-phase-XXXXXX")"
  export FI_PHASE_FILE="$_FI_SIGNAL_PHASE_FILE"

  # Remove stale marker
  rm -f "$_FI_SIGNAL_PHASE_FILE"

  # Run function in background subshell
  ( "$func" "${func_args[@]}" ) &
  _FI_SIGNAL_PID=$!

  # Wait for phase marker and send signal
  fi_send_signal_at_phase "$signal" "$_FI_SIGNAL_PHASE_FILE" "$timeout_secs"
  local rc=$?

  return $rc
}

# ===========================================================================
# fi_inject_rename_failure TARGET_DIR FILENAME
#
# Simulate a rename() failure by removing write permission on the target
# directory. This causes any rename() into that directory to fail with
# EACCES (permission denied).
#
# The caller should invoke fi_cleanup_rename_failure() to restore
# permissions after the test.
#
# Usage:
#   fi_inject_rename_failure "$esp_dir/SteamOS/partsets"
#   # ... operations that attempt rename into this directory will fail ...
#   fi_cleanup_rename_failure "$esp_dir/SteamOS/partsets"
#
# Arguments:
#   TARGET_DIR - Directory to make non-writable
#
# Sets:
#   _FI_RENAME_FAILURE_DIR - The directory whose permissions were changed
#   _FI_RENAME_FAILURE_PERMS - Original permissions for restoration
#
# Returns:
#   0 - Failure injected successfully
#   1 - Error injecting failure
# ===========================================================================
fi_inject_rename_failure() {
  local target_dir="${1:?fi_inject_rename_failure: missing TARGET_DIR}"

  if [[ ! -d "$target_dir" ]]; then
    echo "ERROR: fi_inject_rename_failure: directory does not exist: $target_dir" >&2
    return 1
  fi

  # Record original permissions for cleanup
  _FI_RENAME_FAILURE_DIR="$target_dir"
  _FI_RENAME_FAILURE_PERMS="$(stat -c '%a' "$target_dir")"

  # Remove write permission
  chmod u-w "$target_dir"
  if [[ $? -ne 0 ]]; then
    echo "ERROR: fi_inject_rename_failure: chmod failed on $target_dir" >&2
    return 1
  fi

  # Register cleanup with test harness if available
  if declare -f test_harness_register_cleanup >/dev/null 2>&1; then
    test_harness_register_cleanup fi_cleanup_rename_failure
  fi

  return 0
}

# ===========================================================================
# fi_cleanup_rename_failure [TARGET_DIR]
#
# Restore permissions after fi_inject_rename_failure(). Idempotent.
#
# Arguments:
#   TARGET_DIR - Directory to restore (default: last injected directory)
# ===========================================================================
fi_cleanup_rename_failure() {
  local target_dir="${1:-${_FI_RENAME_FAILURE_DIR:-}}"

  if [[ -z "$target_dir" || ! -d "$target_dir" ]]; then
    return 0
  fi

  if [[ -n "$_FI_RENAME_FAILURE_PERMS" ]]; then
    chmod u+w "$target_dir" 2>/dev/null || true
    _FI_RENAME_FAILURE_DIR=""
    _FI_RENAME_FAILURE_PERMS=""
  fi
}

# ===========================================================================
# fi_inject_fsync_failure TARGET_FILE
#
# Simulate an fsync() failure by setting the file to immutable
# (if capabilities allow) or by removing write permissions.
# For test environments without CAP_LINUX_IMMUTABLE, we use a
# marker file approach: create a sibling file that signals the
# operation should simulate fsync failure.
#
# Usage:
#   fi_inject_fsync_failure "$esp_dir/SteamOS/conf/B.conf"
#
# Arguments:
#   TARGET_FILE - File to inject fsync failure for
#
# Returns:
#   0 - Failure injected successfully
#   1 - Error injecting failure
# ===========================================================================
fi_inject_fsync_failure() {
  local target_file="${1:?fi_inject_fsync_failure: missing TARGET_FILE}"

  if [[ ! -f "$target_file" ]]; then
    echo "ERROR: fi_inject_fsync_failure: file does not exist: $target_file" >&2
    return 1
  fi

  # Create a marker file that signals fsync failure should be simulated
  local marker="${target_file}.fsync-fail"
  touch "$marker"

  # Remove write permission on the file itself to prevent further writes
  chmod u-w "$target_file" 2>/dev/null || true

  # Register cleanup
  if declare -f test_harness_register_cleanup >/dev/null 2>&1; then
    test_harness_register_cleanup fi_cleanup_fsync_failure
  fi

  return 0
}

# ===========================================================================
# fi_cleanup_fsync_failure [TARGET_FILE]
#
# Remove fsync failure injection artifacts. Idempotent.
#
# Arguments:
#   TARGET_FILE - File to clean up (default: detected from markers)
# ===========================================================================
fi_cleanup_fsync_failure() {
  local target_file="${1:-}"

  # If no specific file given, find and remove all .fsync-fail markers
  if [[ -n "$target_file" ]]; then
    rm -f "${target_file}.fsync-fail" 2>/dev/null || true
    chmod u+w "$target_file" 2>/dev/null || true
  fi
}

# ===========================================================================
# fi_inject_enospc TARGET_DIR
#
# Simulate ENOSPC (no space left on device) by filling the filesystem
# to capacity using a large file. Uses a predictable fill pattern so
# cleanup can reclaim the space.
#
# Usage:
#   fi_inject_enospc "$esp_dir"
#   # ... operations that write will fail with ENOSPC ...
#   fi_cleanup_enospc "$esp_dir"
#
# Arguments:
#   TARGET_DIR - Directory whose filesystem to fill
#
# Sets:
#   _FI_ENOSPC_FILL_FILE - Path to the fill file for cleanup
#
# Returns:
#   0 - ENOSPC injected successfully
#   1 - Error injecting ENOSPC
# ===========================================================================
fi_inject_enospc() {
  local target_dir="${1:?fi_inject_enospc: missing TARGET_DIR}"

  if [[ ! -d "$target_dir" ]]; then
    echo "ERROR: fi_inject_enospc: directory does not exist: $target_dir" >&2
    return 1
  fi

  # Check available space
  local avail_kb
  avail_kb="$(df --output=avail "$target_dir" 2>/dev/null | tail -1 | tr -d ' ')" || avail_kb="0"

  if [[ "$avail_kb" -le 1 ]]; then
    echo "WARNING: fi_inject_enospc: filesystem already full or unavailable" >&2
    return 0
  fi

  # Create a fill file to consume all available space
  _FI_ENOSPC_FILL_FILE="${target_dir}/.fi-enospc-fill-$$"

  # Use dd to fill with a predictable pattern (1K blocks)
  local fill_blocks=$((avail_kb - 1))
  if [[ "$fill_blocks" -gt 0 ]]; then
    dd if=/dev/zero of="$_FI_ENOSPC_FILL_FILE" bs=1024 count="$fill_blocks" 2>/dev/null
    if [[ $? -ne 0 ]]; then
      echo "WARNING: fi_inject_enospc: dd fill may not have completed fully" >&2
    fi
  fi

  # Register cleanup
  if declare -f test_harness_register_cleanup >/dev/null 2>&1; then
    test_harness_register_cleanup fi_cleanup_enospc
  fi

  return 0
}

# ===========================================================================
# fi_cleanup_enospc [TARGET_DIR]
#
# Remove the ENOSPC fill file to reclaim disk space. Idempotent.
#
# Arguments:
#   TARGET_DIR - Directory containing the fill file (optional)
# ===========================================================================
fi_cleanup_enospc() {
  if [[ -n "$_FI_ENOSPC_FILL_FILE" && -f "$_FI_ENOSPC_FILL_FILE" ]]; then
    rm -f "$_FI_ENOSPC_FILL_FILE" 2>/dev/null || true
    _FI_ENOSPC_FILL_FILE=""
  fi
}

# ===========================================================================
# fi_inject_transaction_marker EFI_DIR MARKER_NAME [SLOT]
#
# Inject a stale transaction marker file into the EFI directory tree.
# The marker is a JSON-like file that represents an incomplete operation,
# allowing tests to verify that the system detects and recovers from
# stale transaction state.
#
# Marker format (JSON-like):
#   {
#     "transaction_id": "<uuid>",
#     "operation": "<marker_name>",
#     "slot": "<slot>",
#     "started_at": "<unix_timestamp>",
#     "pid": "<pid>",
#     "status": "in-progress"
#   }
#
# Usage:
#   fi_inject_transaction_marker "$efi_dir" "grub-update" "B"
#
# Arguments:
#   EFI_DIR     - EFI directory to inject marker into
#   MARKER_NAME - Name of the transaction (e.g. "grub-update", "partset-write")
#   SLOT        - Target slot (default: "B")
#
# Returns:
#   0 - Marker injected successfully
#   1 - Error injecting marker
# ===========================================================================
fi_inject_transaction_marker() {
  local efi_dir="${1:?fi_inject_transaction_marker: missing EFI_DIR}"
  local marker_name="${2:?fi_inject_transaction_marker: missing MARKER_NAME}"
  local slot="${3:-B}"

  if [[ ! -d "$efi_dir" ]]; then
    echo "ERROR: fi_inject_transaction_marker: EFI directory does not exist: $efi_dir" >&2
    return 1
  fi

  # Generate deterministic transaction ID from marker name and PID
  local txn_id
  txn_id="$(printf 'txn-%s-%s-%s' "$marker_name" "$slot" "$$" | sha1sum | awk '{print $1}')"
  txn_id="${txn_id:0:8}-${txn_id:8:4}-${txn_id:12:4}-${txn_id:16:4}-${txn_id:20:12}"

  local marker_file="$efi_dir/.transaction-${marker_name}"

  # Write JSON-like transaction marker
  cat > "$marker_file" <<MARKER_EOF
{
  "transaction_id": "${txn_id}",
  "operation": "${marker_name}",
  "slot": "${slot}",
  "started_at": "$(date +%s)",
  "pid": "$$",
  "status": "in-progress"
}
MARKER_EOF

  if [[ ! -f "$marker_file" ]]; then
    echo "ERROR: fi_inject_transaction_marker: failed to create marker file: $marker_file" >&2
    return 1
  fi

  # Register cleanup
  if declare -f test_harness_register_cleanup >/dev/null 2>&1; then
    test_harness_register_cleanup fi_cleanup_transaction_markers
  fi

  echo "$marker_file"
  return 0
}

# ===========================================================================
# fi_cleanup_transaction_markers [EFI_DIR]
#
# Remove all stale transaction markers from the EFI directory. Idempotent.
#
# Arguments:
#   EFI_DIR - EFI directory to clean (default: scan common locations)
# ===========================================================================
fi_cleanup_transaction_markers() {
  local efi_dir="${1:-}"

  if [[ -n "$efi_dir" && -d "$efi_dir" ]]; then
    rm -f "$efi_dir"/.transaction-* 2>/dev/null || true
  fi
}

# ===========================================================================
# fi_verify_transaction_recovery EFI_DIR MARKER_NAME
#
# Verify that a stale transaction marker was detected and the system
# would recover (or has recovered) from the stale state.
#
# Checks:
#   1. Transaction marker exists (it was injected)
#   2. Marker contains valid JSON-like structure
#   3. Marker has "in-progress" status (stale)
#   4. No .new, .bak, or .tmp files remain (clean state expected)
#
# Usage:
#   fi_inject_transaction_marker "$efi_dir" "grub-update" "B"
#   # ... system should detect and clean up ...
#   fi_verify_transaction_recovery "$efi_dir" "grub-update"
#
# Arguments:
#   EFI_DIR     - EFI directory to check
#   MARKER_NAME - Name of the transaction to verify
#
# Returns:
#   0 - Recovery verified (marker detected, stale state identified)
#   1 - Recovery verification failed
# ===========================================================================
fi_verify_transaction_recovery() {
  local efi_dir="${1:?fi_verify_transaction_recovery: missing EFI_DIR}"
  local marker_name="${2:?fi_verify_transaction_recovery: missing MARKER_NAME}"

  local rc=0
  local marker_file="$efi_dir/.transaction-${marker_name}"

  # 1. Check marker exists
  if [[ ! -f "$marker_file" ]]; then
    echo "ERROR: fi_verify_transaction_recovery: marker not found: $marker_file" >&2
    return 1
  fi

  # 2. Validate JSON-like structure
  if ! grep -q '"transaction_id"' "$marker_file" 2>/dev/null; then
    echo "ERROR: fi_verify_transaction_recovery: marker missing transaction_id field" >&2
    rc=1
  fi
  if ! grep -q '"operation"' "$marker_file" 2>/dev/null; then
    echo "ERROR: fi_verify_transaction_recovery: marker missing operation field" >&2
    rc=1
  fi
  if ! grep -q '"status"' "$marker_file" 2>/dev/null; then
    echo "ERROR: fi_verify_transaction_recovery: marker missing status field" >&2
    rc=1
  fi

  # 3. Check status is "in-progress" (stale)
  local status
  status="$(grep '"status"' "$marker_file" 2>/dev/null | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/')"
  if [[ "$status" != "in-progress" ]]; then
    echo "ERROR: fi_verify_transaction_recovery: expected status 'in-progress', got '$status'" >&2
    rc=1
  fi

  # 4. Check no leftover .new/.bak/.tmp files
  local -a stale_found=()
  for pattern in '*.new' '*.bak' '*.tmp'; do
    while IFS= read -r match; do
      [[ -n "$match" ]] && stale_found+=("$match")
    done < <(find "$efi_dir" -maxdepth 3 -name "$pattern" -type f 2>/dev/null)
  done

  if [[ ${#stale_found[@]} -gt 0 ]]; then
    echo "ERROR: fi_verify_transaction_recovery: stale artifacts remain alongside marker:" >&2
    printf '  %s\n' "${stale_found[@]}" >&2
    rc=1
  fi

  return $rc
}

# ===========================================================================
# fi_inject_rollback_failure EFI_DIR SLOT
#
# Simulate a rollback failure by making the backup copies read-only.
# When rollback attempts to restore from backup, it will fail because
# the backup files cannot be overwritten.
#
# Usage:
#   fi_inject_rollback_failure "$efi_dir" "B"
#
# Arguments:
#   EFI_DIR - EFI directory containing backup files
#   SLOT    - Target slot whose backups to protect
#
# Returns:
#   0 - Rollback failure injected successfully
#   1 - Error injecting rollback failure
# ===========================================================================
fi_inject_rollback_failure() {
  local efi_dir="${1:?fi_inject_rollback_failure: missing EFI_DIR}"
  local slot="${2:?fi_inject_rollback_failure: missing SLOT}"

  if [[ ! -d "$efi_dir" ]]; then
    echo "ERROR: fi_inject_rollback_failure: EFI directory does not exist: $efi_dir" >&2
    return 1
  fi

  local rc=0

  # Find and protect backup files (*.bak) for the target slot
  local -a protected_files=()

  while IFS= read -r bak_file; do
    [[ -z "$bak_file" ]] && continue
    chmod u-w "$bak_file" 2>/dev/null && protected_files+=("$bak_file") || true
  done < <(find "$efi_dir" -maxdepth 5 -name "*.bak" -type f 2>/dev/null)

  # Also protect any .rollback-marker files
  while IFS= read -r rollback_file; do
    [[ -z "$rollback_file" ]] && continue
    chmod u-w "$rollback_file" 2>/dev/null && protected_files+=("$rollback_file") || true
  done < <(find "$efi_dir" -maxdepth 5 -name "*rollback*" -type f 2>/dev/null)

  if [[ ${#protected_files[@]} -eq 0 ]]; then
    echo "WARNING: fi_inject_rollback_failure: no backup files found to protect in $efi_dir" >&2
  fi

  # Register cleanup
  if declare -f test_harness_register_cleanup >/dev/null 2>&1; then
    test_harness_register_cleanup fi_cleanup_rollback_failure
  fi

  return 0
}

# ===========================================================================
# fi_cleanup_rollback_failure [EFI_DIR]
#
# Remove rollback failure injection by restoring write permissions. Idempotent.
#
# Arguments:
#   EFI_DIR - EFI directory to clean up (optional)
# ===========================================================================
fi_cleanup_rollback_failure() {
  local efi_dir="${1:-}"

  if [[ -n "$efi_dir" && -d "$efi_dir" ]]; then
    find "$efi_dir" -maxdepth 5 \( -name "*.bak" -o -name "*rollback*" \) -type f \
      -exec chmod u+w {} \; 2>/dev/null || true
  fi
}

# ===========================================================================
# fi_inject_partial_activation EFI_DIR ESP_DIR SLOT PHASE
#
# Simulate a partial activation by applying some but not all EFI state
# changes. The PHASE argument controls which artifacts are updated:
#
#   "grub-only"    - Only grub.cfg is updated
#   "partset-only" - Only partset files are updated
#   "bootconf-only" - Only bootconf is updated
#   "before-efi"   - Everything except grubx64.efi binary is updated
#
# This creates a state where some artifacts reflect the new slot while
# others still reference the old slot, allowing verification of
# recovery logic that must detect and resolve such inconsistency.
#
# Usage:
#   fi_inject_partial_activation "$efi_dir" "$esp_dir" "B" "grub-only"
#
# Arguments:
#   EFI_DIR - EFI directory
#   ESP_DIR - ESP directory (optional, may be empty for some phases)
#   SLOT    - Target slot
#   PHASE   - Phase at which to stop activation
#
# Returns:
#   0 - Partial activation injected successfully
#   1 - Error injecting partial activation
# ===========================================================================
fi_inject_partial_activation() {
  local efi_dir="${1:?fi_inject_partial_activation: missing EFI_DIR}"
  local esp_dir="${2:-}"
  local slot="${3:?fi_inject_partial_activation: missing SLOT}"
  local phase="${4:?fi_inject_partial_activation: missing PHASE}"

  if [[ ! -d "$efi_dir" ]]; then
    echo "ERROR: fi_inject_partial_activation: EFI directory does not exist: $efi_dir" >&2
    return 1
  fi

  local grub_cfg="$efi_dir/EFI/steamos/grub.cfg"
  local partsets_dir="$efi_dir/SteamOS/partsets"
  local grubx64="$efi_dir/EFI/steamos/grubx64.efi"

  case "$phase" in
    grub-only)
      # Only update grub.cfg — mark other artifacts as not yet applied
      if [[ -f "$grub_cfg" ]]; then
        # Append a marker indicating partial activation
        echo "# partial-activation: grub-only phase for slot $slot" >> "$grub_cfg"
      fi
      ;;
    partset-only)
      # Update partset files only
      if [[ -d "$partsets_dir" ]]; then
        for ps_file in "$partsets_dir"/*; do
          [[ -f "$ps_file" ]] || continue
          local ps_basename
          ps_basename="$(basename "$ps_file")"
          # Only update slot-specific partsets, not self/all/shared
          if [[ "$ps_basename" == "$slot" ]]; then
            echo "# partial-activation: partset for slot $slot" >> "$ps_file"
          fi
        done
      fi
      ;;
    bootconf-only)
      # Update bootconf only
      if [[ -n "$esp_dir" && -d "$esp_dir" ]]; then
        local conf_file="$esp_dir/SteamOS/conf/${slot}.conf"
        if [[ -f "$conf_file" ]]; then
          # Mark as activated
          sed -i 's/^image-invalid=1/image-invalid=0/' "$conf_file" 2>/dev/null || true
        fi
      fi
      ;;
    before-efi)
      # Update grub, partsets, and bootconf — but NOT grubx64.efi
      if [[ -f "$grub_cfg" ]]; then
        echo "# partial-activation: before-efi phase for slot $slot" >> "$grub_cfg"
      fi
      if [[ -d "$partsets_dir" ]]; then
        for ps_file in "$partsets_dir"/*; do
          [[ -f "$ps_file" ]] || continue
          echo "# partial-activation: partset update for slot $slot" >> "$ps_file"
        done
      fi
      if [[ -n "$esp_dir" && -d "$esp_dir" ]]; then
        local conf_file="$esp_dir/SteamOS/conf/${slot}.conf"
        if [[ -f "$conf_file" ]]; then
          sed -i 's/^image-invalid=1/image-invalid=0/' "$conf_file" 2>/dev/null || true
        fi
      fi
      ;;
    *)
      echo "ERROR: fi_inject_partial_activation: unknown phase: $phase" >&2
      return 1
      ;;
  esac

  # Register cleanup
  if declare -f test_harness_register_cleanup >/dev/null 2>&1; then
    test_harness_register_cleanup fi_cleanup_partial_activation
  fi

  return 0
}

# ===========================================================================
# fi_cleanup_partial_activation [EFI_DIR] [ESP_DIR]
#
# Remove partial activation markers. Idempotent.
#
# Arguments:
#   EFI_DIR - EFI directory to clean (optional)
#   ESP_DIR - ESP directory to clean (optional)
# ===========================================================================
fi_cleanup_partial_activation() {
  local efi_dir="${1:-}"
  local esp_dir="${2:-}"

  # Remove partial-activation comment lines from grub.cfg
  if [[ -n "$efi_dir" && -d "$efi_dir" ]]; then
    local grub_cfg="$efi_dir/EFI/steamos/grub.cfg"
    if [[ -f "$grub_cfg" ]]; then
      sed -i '/^# partial-activation:/d' "$grub_cfg" 2>/dev/null || true
    fi

    # Remove partial-activation lines from partset files
    local partsets_dir="$efi_dir/SteamOS/partsets"
    if [[ -d "$partsets_dir" ]]; then
      find "$partsets_dir" -maxdepth 1 -type f \
        -exec sed -i '/^# partial-activation:/d' {} \; 2>/dev/null || true
    fi
  fi
}

# ===========================================================================
# fi_verify_partial_activation_recovery EFI_DIR [ESP_DIR]
#
# Verify that after partial activation and recovery, the system is in
# a consistent state. All artifacts should either all reflect the new
# slot or all reflect the old slot — no mixed state.
#
# Checks:
#   1. No partial-activation markers remain
#   2. grub.cfg does not contain slot-specific partial references
#   3. partset files are consistent (no partial writes)
#   4. bootconf and grub.cfg are in agreement about active slot
#
# Arguments:
#   EFI_DIR - EFI directory to verify
#   ESP_DIR - ESP directory to verify (optional)
#
# Returns:
#   0 - Consistent state verified
#   1 - Inconsistent state detected
# ===========================================================================
fi_verify_partial_activation_recovery() {
  local efi_dir="${1:?fi_verify_partial_activation_recovery: missing EFI_DIR}"
  local esp_dir="${2:-}"

  local rc=0

  # 1. Check no partial-activation markers remain
  local grub_cfg="$efi_dir/EFI/steamos/grub.cfg"
  if [[ -f "$grub_cfg" ]]; then
    local partial_markers
    partial_markers="$(grep -c '# partial-activation:' "$grub_cfg" 2>/dev/null)" || partial_markers=0
    if [[ "$partial_markers" -gt 0 ]]; then
      echo "ERROR: fi_verify_partial_activation_recovery: grub.cfg still has partial-activation markers" >&2
      rc=1
    fi
  fi

  # 2. Check partset files for partial markers
  local partsets_dir="$efi_dir/SteamOS/partsets"
  if [[ -d "$partsets_dir" ]]; then
    while IFS= read -r ps_file; do
      [[ -z "$ps_file" ]] && continue
      local partial_count
      partial_count="$(grep -c '# partial-activation:' "$ps_file" 2>/dev/null)" || partial_count=0
      if [[ "$partial_count" -gt 0 ]]; then
        echo "ERROR: fi_verify_partial_activation_recovery: partset $(basename "$ps_file") still has partial markers" >&2
        rc=1
      fi
    done < <(find "$partsets_dir" -maxdepth 1 -type f)
  fi

  # 3. Verify partset files are non-empty and well-formed
  if [[ -d "$partsets_dir" ]]; then
    while IFS= read -r ps_file; do
      [[ -z "$ps_file" ]] && continue
      if [[ ! -s "$ps_file" ]]; then
        echo "ERROR: fi_verify_partial_activation_recovery: partset $(basename "$ps_file") is empty" >&2
        rc=1
      fi
    done < <(find "$partsets_dir" -maxdepth 1 -type f -name "self" -o -name "all" -o -name "shared")
  fi

  # 4. Check bootconf consistency if ESP is provided
  if [[ -n "$esp_dir" && -d "$esp_dir" ]]; then
    local conf_dir="$esp_dir/SteamOS/conf"
    if [[ -d "$conf_dir" ]]; then
      for conf_file in "$conf_dir"/*.conf; do
        [[ -f "$conf_file" ]] || continue
        local invalid_val
        invalid_val="$(grep '^image-invalid=' "$conf_file" 2>/dev/null | head -1 | cut -d= -f2)"
        if [[ -n "$invalid_val" && "$invalid_val" != "0" && "$invalid_val" != "1" ]]; then
          echo "ERROR: fi_verify_partial_activation_recovery: $(basename "$conf_file") has invalid image-invalid value: '$invalid_val'" >&2
          rc=1
        fi
      done
    fi
  fi

  return $rc
}

# ===========================================================================
# fi_snapshot_resources BASE_DIR FILE_PATHS...
#
# Take a snapshot of file ownership and permissions for later verification.
# Creates a snapshot file containing owner, group, permissions, and
# checksum for each specified file.
#
# Usage:
#   fi_snapshot_resources "$efi_dir" \
#     "$efi_dir/EFI/steamos/grub.cfg" \
#     "$efi_dir/SteamOS/partsets/self"
#
# Arguments:
#   BASE_DIR   - Base directory for relative path display
#   FILE_PATHS - One or more file paths to snapshot
#
# Sets:
#   _FI_SNAPSHOT_DIR - Path to the snapshot directory
#
# Returns:
#   0 - Snapshot created successfully
#   1 - Error creating snapshot
# ===========================================================================
fi_snapshot_resources() {
  local base_dir="${1:?fi_snapshot_resources: missing BASE_DIR}"
  shift
  local -a file_paths=("$@")

  if [[ ${#file_paths[@]} -eq 0 ]]; then
    echo "ERROR: fi_snapshot_resources: no file paths provided" >&2
    return 1
  fi

  # Create snapshot directory
  _FI_SNAPSHOT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fi-snapshot-XXXXXX")"
  if [[ ! -d "$_FI_SNAPSHOT_DIR" ]]; then
    echo "ERROR: fi_snapshot_resources: failed to create snapshot directory" >&2
    return 1
  fi

  local snapshot_file="$_FI_SNAPSHOT_DIR/resources.snapshot"
  > "$snapshot_file"

  local file_path
  for file_path in "${file_paths[@]}"; do
    if [[ ! -f "$file_path" ]]; then
      echo "WARNING: fi_snapshot_resources: file does not exist: $file_path" >&2
      continue
    fi

    local rel_path="${file_path#"$base_dir"}"
    local owner group perms checksum

    owner="$(stat -c '%U' "$file_path" 2>/dev/null)" || owner="unknown"
    group="$(stat -c '%G' "$file_path" 2>/dev/null)" || group="unknown"
    perms="$(stat -c '%a' "$file_path" 2>/dev/null)" || perms="000"
    checksum="$(md5sum "$file_path" 2>/dev/null | awk '{print $1}')" || checksum="none"

    printf '%s|%s|%s|%s|%s\n' "$rel_path" "$owner" "$group" "$perms" "$checksum" >> "$snapshot_file"
  done

  # Register cleanup
  if declare -f test_harness_register_cleanup >/dev/null 2>&1; then
    test_harness_register_cleanup fi_cleanup_snapshot
  fi

  echo "$_FI_SNAPSHOT_DIR"
  return 0
}

# ===========================================================================
# fi_cleanup_snapshot
#
# Remove snapshot directory. Idempotent.
# ===========================================================================
fi_cleanup_snapshot() {
  if [[ -n "$_FI_SNAPSHOT_DIR" && -d "$_FI_SNAPSHOT_DIR" ]]; then
    rm -rf "$_FI_SNAPSHOT_DIR" 2>/dev/null || true
    _FI_SNAPSHOT_DIR=""
  fi
}

# ===========================================================================
# fi_verify_cleanup_ownership BASE_DIR SNAPSHOT_DIR FILE_PATHS...
#
# Verify that file ownership and permissions match the snapshot taken
# by fi_snapshot_resources(). This is used to verify that cleanup
# operations restore files to their original ownership state.
#
# Usage:
#   fi_verify_cleanup_ownership "$efi_dir" "$snapshot_dir" \
#     "$efi_dir/EFI/steamos/grub.cfg"
#
# Arguments:
#   BASE_DIR     - Base directory for relative path display
#   SNAPSHOT_DIR - Directory containing the snapshot from fi_snapshot_resources
#   FILE_PATHS   - One or more file paths to verify
#
# Returns:
#   0 - All ownership matches snapshot
#   1 - Ownership mismatch detected
# ===========================================================================
fi_verify_cleanup_ownership() {
  local base_dir="${1:?fi_verify_cleanup_ownership: missing BASE_DIR}"
  local snapshot_dir="${2:?fi_verify_cleanup_ownership: missing SNAPSHOT_DIR}"
  shift 2
  local -a file_paths=("$@")

  local rc=0
  local snapshot_file="$snapshot_dir/resources.snapshot"

  if [[ ! -f "$snapshot_file" ]]; then
    echo "ERROR: fi_verify_cleanup_ownership: snapshot file not found: $snapshot_file" >&2
    return 1
  fi

  local file_path
  for file_path in "${file_paths[@]}"; do
    local rel_path="${file_path#"$base_dir"}"

    # Find snapshot entry for this file
    local snapshot_entry
    snapshot_entry="$(grep "^${rel_path}|" "$snapshot_file" 2>/dev/null | head -1)"

    if [[ -z "$snapshot_entry" ]]; then
      echo "WARNING: fi_verify_cleanup_ownership: no snapshot entry for: $rel_path" >&2
      continue
    fi

    # Parse snapshot: rel_path|owner|group|perms|checksum
    local snap_owner snap_group snap_perms snap_checksum
    IFS='|' read -r _ snap_owner snap_group snap_perms snap_checksum <<< "$snapshot_entry"

    # Current state
    if [[ ! -f "$file_path" ]]; then
      echo "ERROR: fi_verify_cleanup_ownership: file missing after cleanup: $file_path" >&2
      rc=1
      continue
    fi

    local cur_owner cur_group cur_perms cur_checksum
    cur_owner="$(stat -c '%U' "$file_path" 2>/dev/null)" || cur_owner="unknown"
    cur_group="$(stat -c '%G' "$file_path" 2>/dev/null)" || cur_group="unknown"
    cur_perms="$(stat -c '%a' "$file_path" 2>/dev/null)" || cur_perms="000"
    cur_checksum="$(md5sum "$file_path" 2>/dev/null | awk '{print $1}')" || cur_checksum="none"

    if [[ "$cur_owner" != "$snap_owner" ]]; then
      echo "ERROR: fi_verify_cleanup_ownership: owner mismatch for $rel_path (expected=$snap_owner, actual=$cur_owner)" >&2
      rc=1
    fi
    if [[ "$cur_group" != "$snap_group" ]]; then
      echo "ERROR: fi_verify_cleanup_ownership: group mismatch for $rel_path (expected=$snap_group, actual=$cur_group)" >&2
      rc=1
    fi
    if [[ "$cur_perms" != "$snap_perms" ]]; then
      echo "ERROR: fi_verify_cleanup_ownership: permissions mismatch for $rel_path (expected=$snap_perms, actual=$cur_perms)" >&2
      rc=1
    fi
    if [[ "$cur_checksum" != "$snap_checksum" ]]; then
      echo "ERROR: fi_verify_cleanup_ownership: content checksum mismatch for $rel_path" >&2
      rc=1
    fi
  done

  return $rc
}

# ===========================================================================
# fi_register_emergency_cleanup FUNC [ARGS...]
#
# Register a function to be called during emergency cleanup. Emergency
# cleanup handlers are called in reverse registration order and are
# guaranteed to run even if the test harness cleanup fails.
#
# Usage:
#   fi_register_emergency_cleanup my_cleanup_func "arg1" "arg2"
#
# Arguments:
#   FUNC  - Function to register as emergency cleanup handler
#   ARGS  - Arguments to pass to the function during cleanup
#
# Returns:
#   0 - Handler registered successfully
#   1 - Function does not exist
# ===========================================================================
fi_register_emergency_cleanup() {
  local func="${1:?fi_register_emergency_cleanup: missing FUNC}"
  shift
  local -a args=("$@")

  if ! declare -f "$func" >/dev/null 2>&1; then
    echo "ERROR: fi_register_emergency_cleanup: '$func' is not a function" >&2
    return 1
  fi

  # Store function name and args as a delimited string
  local handler_entry="$func"
  if [[ ${#args[@]} -gt 0 ]]; then
    handler_entry="${handler_entry}$(printf '|%s' "${args[@]}")"
  fi

  _FI_EMERGENCY_CLEANUP_HANDLERS+=("$handler_entry")

  # Register with test harness as well
  if declare -f test_harness_register_cleanup >/dev/null 2>&1; then
    test_harness_register_cleanup fi_verify_emergency_cleanup
  fi

  return 0
}

# ===========================================================================
# fi_verify_emergency_cleanup
#
# Execute all registered emergency cleanup handlers in reverse order.
# Each handler is called with the arguments it was registered with.
# Errors in individual handlers are logged but do not prevent other
# handlers from running.
#
# This function is idempotent — safe to call multiple times.
# Designed to be used as a cleanup handler or trap target.
#
# Returns:
#   0 - All handlers executed (even if some failed)
#   1 - One or more handlers failed
# ===========================================================================
fi_verify_emergency_cleanup() {
  local rc=0
  local total=${#_FI_EMERGENCY_CLEANUP_HANDLERS[@]}

  if [[ "$total" -eq 0 ]]; then
    return 0
  fi

  # Execute handlers in reverse order
  local i
  for ((i = total - 1; i >= 0; i--)); do
    local handler_entry="${_FI_EMERGENCY_CLEANUP_HANDLERS[$i]}"

    # Split on first '|' to get function name and args
    local func_name="${handler_entry%%|*}"
    local args_str="${handler_entry#*|}"

    if [[ "$args_str" == "$func_name" ]]; then
      # No args (the whole entry is just the function name)
      if declare -f "$func_name" >/dev/null 2>&1; then
        "$func_name" 2>/dev/null || {
          echo "WARNING: fi_verify_emergency_cleanup: handler '$func_name' failed" >&2
          rc=1
        }
      else
        echo "WARNING: fi_verify_emergency_cleanup: handler function '$func_name' not found" >&2
        rc=1
      fi
    else
      # Has args — split on '|' and call with args
      local -a handler_args
      IFS='|' read -ra handler_args <<< "$args_str"
      if declare -f "$func_name" >/dev/null 2>&1; then
        "$func_name" "${handler_args[@]}" 2>/dev/null || {
          echo "WARNING: fi_verify_emergency_cleanup: handler '$func_name' failed" >&2
          rc=1
        }
      else
        echo "WARNING: fi_verify_emergency_cleanup: handler function '$func_name' not found" >&2
        rc=1
      fi
    fi
  done

  return $rc
}

# ===========================================================================
# fi_cleanup_all
#
# Master cleanup function that invokes all failure injection cleanup
# routines. Idempotent — safe to call multiple times.
#
# Usage:
#   trap fi_cleanup_all EXIT
#
# Returns:
#   0 - All cleanup completed
# ===========================================================================
fi_cleanup_all() {
  fi_cleanup_rename_failure 2>/dev/null || true
  fi_cleanup_fsync_failure 2>/dev/null || true
  fi_cleanup_enospc 2>/dev/null || true
  fi_cleanup_transaction_markers 2>/dev/null || true
  fi_cleanup_rollback_failure 2>/dev/null || true
  fi_cleanup_partial_activation 2>/dev/null || true
  fi_cleanup_snapshot 2>/dev/null || true
  fi_verify_emergency_cleanup 2>/dev/null || true
}
