#!/bin/bash
#
# steamos-build-installer — lib/preflight_path_safety.sh
# Path safety validation: ensures destination paths are not symlinks that
# escape their expected mount boundaries, and detects stale transaction
# state (interrupted writes leaving .new/.bak/.tmp/.transaction-* files and
# installer-owned transaction state in .steamos-build-installer/transaction/).
# Called by the build pipeline before any destination writes begin.
#
# Requires: lib/common.sh (die, debug, warn)
# Do not run it directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/preflight_path_safety.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _pf_path_resolve_canonical PATH
#   Resolve PATH through symlinks to its canonical form using `realpath`.
#   Returns the resolved path on stdout.
#   Dies if the input is empty or cannot be resolved.
_pf_path_resolve_canonical() {
  local target="${1:?_pf_path_resolve_canonical: missing path}"

  local resolved
  resolved="$(realpath "$target" 2>/dev/null)" \
    || return 1

  [[ -n "$resolved" ]] \
    || return 1

  echo "$resolved"
}

# _pf_path_intermediate_safe MOUNT_ROOT DESTINATION
#   Verify that every path component between MOUNT_ROOT and DESTINATION
#   (exclusive) is a real directory, not a symlink.
#   This catches symlink injection in intermediate components like
#   /efi/EFI/steamos/grub.cfg where /efi/EFI/steamos could be a symlink.
#   Returns 0 if safe, 1 if any intermediate is a symlink.
#   Does NOT die -- callers decide severity.
_pf_path_intermediate_safe() {
  local mount_root="${1:?_pf_path_intermediate_safe: missing mount root}"
  local destination="${2:?_pf_path_intermediate_safe: missing destination}"

  # Canonicalize the mount root first.
  local canonical_root
  if ! canonical_root="$(_pf_path_resolve_canonical "$mount_root")"; then
    return 1
  fi

  # Walk up from destination to mount root, checking each intermediate.
  local current
  current="$(dirname "$destination")"

  while [[ "$current" != "$canonical_root" && "$current" != "/" ]]; do
    # Check if this intermediate component is a symlink.
    if [[ -L "$current" ]]; then
      local link_target
      link_target="$(readlink "$current" 2>/dev/null)" || link_target="<unreadable>"
      debug "_pf_path_intermediate_safe: intermediate component is a symlink: $current -> $link_target"
      return 1
    fi

    # Check if it's a real directory.
    if [[ ! -d "$current" ]]; then
      # Directory doesn't exist yet -- parent must exist for file creation.
      # Walk up further.
      current="$(dirname "$current")"
      continue
    fi

    current="$(dirname "$current")"
  done

  return 0
}

# _pf_path_within_mount PATH MOUNTPOINT
#   Verify that the resolved PATH is within (or is) the expected MOUNTPOINT.
#   Uses device ID comparison: the resolved path's parent device must match
#   the mount's device.  This detects symlink escapes where the path resolves
#   to a different filesystem entirely.
#
#   Method:
#     1. Resolve both PATH and MOUNTPOINT to canonical forms.
#     2. Get the device (filesystem) backing the resolved path via stat.
#     3. Compare major:minor device IDs (fast first gate).
#     4. Verify resolved path is a prefix of the mount (or vice versa).
#     5. Use findmnt -T to confirm the path is covered by the expected mount
#        (authoritative check that also catches same-filesystem bind mounts).
#
#   Also checks that the resolved path is a prefix of (or equal to) the
#   mountpoint, or vice versa, to catch paths that share a device but
#   sit outside the mount tree (e.g. /tmp symlinked to /home/tmp).
#
#   Returns 0 if within mount, 1 otherwise (caller decides die/warn).
_pf_path_within_mount() {
  local target="${1:?_pf_path_within_mount: missing target path}"
  local mountpoint="${2:?_pf_path_within_mount: missing mountpoint}"

  local resolved_target resolved_mount

  if ! resolved_target="$(_pf_path_resolve_canonical "$target")"; then
    debug "_pf_path_within_mount: cannot resolve target path: $target"
    return 1
  fi

  if ! resolved_mount="$(_pf_path_resolve_canonical "$mountpoint")"; then
    debug "_pf_path_within_mount: cannot resolve mountpoint: $mountpoint"
    return 1
  fi

  # Preserve "/" — only strip trailing slashes from non-root paths.
  if [[ "$resolved_target" != "/" ]]; then
    resolved_target="${resolved_target%/}"
  fi
  if [[ "$resolved_mount" != "/" ]]; then
    resolved_mount="${resolved_mount%/}"
  fi

  # --- Device ID comparison ---
  local target_dev
  target_dev="$(stat -c '%d' "$resolved_target" 2>/dev/null)" || target_dev=""

  local mount_stat_dev
  mount_stat_dev="$(stat -c '%d' "$resolved_mount" 2>/dev/null)" || mount_stat_dev=""

  if [[ -n "$target_dev" && -n "$mount_stat_dev" ]]; then
    if [[ "$target_dev" != "$mount_stat_dev" ]]; then
      debug "_pf_path_within_mount: device mismatch ($target_dev != $mount_stat_dev) — target escapes mount"
      return 1
    fi
  elif [[ -z "$target_dev" ]]; then
    debug "_pf_path_within_mount: cannot determine device for target: $resolved_target"
    return 1
  elif [[ -z "$mount_stat_dev" ]]; then
    debug "_pf_path_within_mount: cannot determine device for mount: $resolved_mount"
    return 1
  fi

  # --- Path prefix check ---
  if [[ "$resolved_target" != "$resolved_mount" && "$resolved_target" != "$resolved_mount"/* ]]; then
    debug "_pf_path_within_mount: path '$resolved_target' is not under mount '$resolved_mount'"
    return 1
  fi

  # --- Mount containment check via findmnt ---
  # findmnt -T returns the most specific mount covering a path.
  # We verify it matches our expected mount.
  local path_mount
  path_mount="$(findmnt -nro TARGET -T "$resolved_target" 2>/dev/null | head -1)" || path_mount=""

  if [[ -n "$path_mount" ]]; then
    # The path is covered by some mount. Verify it's our expected mount.
    local canonical_mount_path
    if canonical_mount_path="$(_pf_path_resolve_canonical "$path_mount")"; then
      if [[ "$canonical_mount_path" != "$resolved_mount" && "$resolved_target" != "$resolved_mount" ]]; then
        debug "_pf_path_within_mount: path is covered by unexpected mount $path_mount (expected $resolved_mount)"
        return 1
      fi
    fi
  fi

  return 0
}

# Transaction namespace directory (installer-owned).
_PREF_PATH_SAFETY_TXN_DIR=".steamos-build-installer/transaction"

# _pf_path_scan_transaction_artifacts DIRECTORY [MAXDEPTH]
#   Check for stale transaction state in the installer-owned namespace.
#   Looks for $DIRECTORY/.steamos-build-installer/transaction/ containing
#   a transaction marker or staged artifacts.
#   Also scans for legacy patterns (*.new, *.bak, *.tmp) as a fallback.
#   Returns:
#     0 — artifacts found (printed to stdout)
#     1 — clean (no artifacts)
#     2 — scan failed (error details on stderr)
_pf_path_scan_transaction_artifacts() {
  local directory="${1:?_pf_path_scan_transaction_artifacts: missing directory}"
  local maxdepth="${2:-5}"

  if [[ ! -d "$directory" ]]; then
    debug "_pf_path_scan_transaction_artifacts: directory does not exist: $directory"
    return 1
  fi

  # Validate MAXDEPTH is a bounded nonnegative integer.
  if ! [[ "$maxdepth" =~ ^[0-9]+$ ]] || [[ "$maxdepth" -gt 20 ]]; then
    die "_pf_path_scan_transaction_artifacts: invalid maxdepth: $maxdepth (must be 0-20)"
  fi

  local -a all_matches=()

  # --- Check installer-owned transaction namespace ---
  local txn_dir="$directory/$_PREF_PATH_SAFETY_TXN_DIR"
  if [[ -d "$txn_dir" ]]; then
    # Transaction directory exists — this is stale state.
    local -a txn_matches=()
    if ! mapfile -d '' txn_matches < <(find "$txn_dir" -maxdepth "$maxdepth" -type f -print0 2>/dev/null); then
      if [[ ${#txn_matches[@]} -gt 0 ]]; then
        all_matches+=("${txn_matches[@]}")
      else
        die "_pf_path_scan_transaction_artifacts: scan failed for $txn_dir (permission or I/O error)"
      fi
    elif [[ ${#txn_matches[@]} -gt 0 ]]; then
      all_matches+=("${txn_matches[@]}")
    fi
  fi

  # --- Legacy pattern scan (backward compatibility) ---
  local -a legacy_matches=()
  if ! mapfile -d '' legacy_matches < <(find "$directory" \
    -maxdepth "$maxdepth" \
    \( \
    -name '*.new' \
    -o -name '*.bak' \
    -o -name '*.tmp' \
    -o -name '*.transaction-*' \
    \) \
    -type f \
    -not -path "$directory/$_PREF_PATH_SAFETY_TXN_DIR/*" \
    -print0 2>/dev/null); then
    if [[ ${#legacy_matches[@]} -gt 0 ]]; then
      all_matches+=("${legacy_matches[@]}")
    else
      die "_pf_path_scan_transaction_artifacts: scan failed for $directory (permission or I/O error)"
    fi
  elif [[ ${#legacy_matches[@]} -gt 0 ]]; then
    all_matches+=("${legacy_matches[@]}")
  fi

  if [[ ${#all_matches[@]} -gt 0 ]]; then
    # Strip trailing NUL and print one path per line.
    printf '%s\n' "${all_matches[@]//$'\0'/}"
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# Individual checks — independently callable
# ---------------------------------------------------------------------------

# _preflight_path_safety_not_symlink PATH LABEL
#   PF-55a: Verify the destination PATH is not a symlink.
#   Symlinks are checked BEFORE realpath resolution to detect escapes.
#   LABEL is used in diagnostic messages (e.g. "EFI", "ESP").
#   Dies if the path is a symlink.
_preflight_path_safety_not_symlink() {
  local target="${1:?_preflight_path_safety_not_symlink: missing path}"
  local label="${2:-destination}"

  if [[ -L "$target" ]]; then
    local link_target
    link_target="$(readlink "$target" 2>/dev/null)" || link_target="<unreadable>"
    die "PF-55a: $label path is a symlink (escape vector): $target -> $link_target"
  fi

  debug "PF-55a: $label path is not a symlink: $target"
}

# _preflight_path_safety_within_mount PATH MOUNTPOINT LABEL
#   PF-55b: Verify the destination PATH resolves within the expected mount.
#   Uses device ID comparison to detect cross-filesystem symlink escapes.
#   LABEL is used in diagnostic messages (e.g. "EFI", "ESP").
#   Dies if the path escapes the mount boundary.
_preflight_path_safety_within_mount() {
  local target="${1:?_preflight_path_safety_within_mount: missing path}"
  local mountpoint="${2:?_preflight_path_safety_within_mount: missing mountpoint}"
  local label="${3:-destination}"

  if ! _pf_path_within_mount "$target" "$mountpoint"; then
    local resolved_target resolved_mount
    resolved_target="$(_pf_path_resolve_canonical "$target" 2>/dev/null)" || resolved_target="$target"
    resolved_mount="$(_pf_path_resolve_canonical "$mountpoint" 2>/dev/null)" || resolved_mount="$mountpoint"
    die "PF-55b: $label path escapes its mount boundary ($target resolves to $resolved_target, mount is $resolved_mount)"
  fi

  debug "PF-55b: $label path is within mount: $target -> $mountpoint"
}

# _preflight_path_safety_destination_safe PATH MOUNTPOINT LABEL
#   PF-55: Combined destination safety check.
#   Verifies the path is not a symlink (PF-55a) AND resolves within the
#   expected mount (PF-55b).  The symlink check MUST happen before the
#   realpath-based mount check so that symlink escapes are caught first.
_preflight_path_safety_destination_safe() {
  local target="${1:?_preflight_path_safety_destination_safe: missing path}"
  local mountpoint="${2:?_preflight_path_safety_destination_safe: missing mountpoint}"
  local label="${3:-destination}"

  # PF-55a: Symlink check (must precede realpath resolution).
  _preflight_path_safety_not_symlink "$target" "$label"

  # PF-55c: Check intermediate path components are not symlinks.
  if ! _pf_path_intermediate_safe "$mountpoint" "$target"; then
    die "PF-55c: $label path has a symlinked intermediate component: $target (mount: $mountpoint)"
  fi

  # PF-55b: Mount boundary check (uses device ID comparison).
  _preflight_path_safety_within_mount "$target" "$mountpoint" "$label"

  debug "PF-55: $label destination is safe: $target ($mountpoint)"
}

# _preflight_path_safety_no_stale_transactions DIRECTORY [MAXDEPTH]
#   PF-56: Verify no stale transaction files exist in the given directory.
#   Checks the installer-owned transaction namespace first, then scans for
#   legacy patterns (*.new, *.bak, *.tmp, *.transaction-*).
#   Provides recovery guidance for installer-owned state and warns about
#   ambiguity for legacy patterns.
#   Dies if stale artifacts are found.
_preflight_path_safety_no_stale_transactions() {
  local directory="${1:?_preflight_path_safety_no_stale_transactions: missing directory}"
  local maxdepth="${2:-5}"

  if [[ ! -d "$directory" ]]; then
    die "PF-56: required transaction scan directory does not exist: $directory"
  fi

  local rc=0
  local artifacts
  artifacts="$(_pf_path_scan_transaction_artifacts "$directory" "$maxdepth")" || rc=$?

  case "$rc" in
    0) # Artifacts found.
      local count
      count="$(echo "$artifacts" | wc -l)"
      warn "PF-56: stale transaction artifacts detected ($count file(s)) in $directory"
      # Check if these are in the installer-owned namespace (recoverable).
      local txn_dir="$directory/$_PREF_PATH_SAFETY_TXN_DIR"
      if [[ -d "$txn_dir" ]]; then
        warn "PF-56: installer-owned transaction state found at $txn_dir — may need manual cleanup"
        warn "PF-56: to recover: remove $txn_dir and retry, or inspect contents for staged artifacts"
      fi
      warn "PF-56: legacy patterns detected — review files before proceeding"
      die "PF-56: stale transactions must be resolved before proceeding"
      ;;
    1) # Clean.
      debug "PF-56: no stale transactions in $directory"
      ;;
    2) # Scan failed — already reported by the helper via die.
      die "PF-56: transaction scan failed for $directory"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Orchestrators
# ---------------------------------------------------------------------------

# _preflight_path_safety_validate_destinations EFI_MOUNT [ESP_MOUNT]
#   Validate destination path safety for EFI and optional ESP mounts.
#   Checks that each managed destination path is not a symlink and resolves
#   within its expected mount boundary.
#
#   Managed destinations under EFI_MOUNT:
#     EFI/steamos/grub.cfg
#     EFI/steamos/grubx64.efi
#   Managed destinations under ESP_MOUNT:
#     SteamOS/partsets/*
#     SteamOS/conf/<slot>.conf
#
#   NOTE: The mount roots themselves are NOT validated against "/" — that
#   would always fail since EFI/ESP are different filesystems from root.
#   Instead, each destination path is validated against its own mount.
#
#   SLOT is required when ESP_MOUNT is provided (for conf path validation).
_preflight_path_safety_validate_destinations() {
  local efi_mount="${1:?_preflight_path_safety_validate_destinations: missing EFI mount}"
  local esp_mount="${2:-}"
  local slot="${3:-}"

  debug "_preflight_path_safety_validate_destinations: efi=$efi_mount esp=${esp_mount:-<none>} slot=${slot:-<none>}"

  # Verify required mount roots exist.
  if [[ ! -d "$efi_mount" ]]; then
    die "PF-55: required EFI mount directory does not exist: $efi_mount"
  fi

  # --- Validate the mount roots themselves are real directories (not symlinks) ---
  _preflight_path_safety_not_symlink "$efi_mount" "EFI mount root"
  if [[ -n "$esp_mount" ]]; then
    _preflight_path_safety_not_symlink "$esp_mount" "ESP mount root"
  fi

  # --- Validate managed destinations under EFI_MOUNT ---
  local efi_dest
  for efi_dest in \
    "$efi_mount/EFI/steamos/grub.cfg" \
    "$efi_mount/EFI/steamos/grubx64.efi"; do
    # For new files, validate the closest existing parent.
    local parent="$efi_dest"
    while [[ ! -e "$parent" && "$parent" != "$efi_mount" ]]; do
      parent="$(dirname "$parent")"
    done
    _preflight_path_safety_destination_safe "$parent" "$efi_mount" "EFI"
  done

  # --- Validate managed destinations under ESP_MOUNT ---
  if [[ -n "$esp_mount" ]]; then
    local esp_dest
    for esp_dest in \
      "$esp_mount/SteamOS/partsets" \
      "$esp_mount/SteamOS/conf"; do
      if [[ -d "$esp_dest" ]]; then
        _preflight_path_safety_destination_safe "$esp_dest" "$esp_mount" "ESP"
      fi
    done
  else
    debug "_preflight_path_safety_validate_destinations: no ESP mount — skipping"
  fi

  debug "_preflight_path_safety_validate_destinations: all destination checks passed"
}

# _preflight_path_safety_validate_transactions EFI_MOUNT [ESP_MOUNT]
#   Validate no stale transaction artifacts exist in EFI and optional ESP
#   mount directories.  Uses maxdepth of 5 for recursive scanning.
#   Dies on the first failure.
_preflight_path_safety_validate_transactions() {
  local efi_mount="${1:?_preflight_path_safety_validate_transactions: missing EFI mount}"
  local esp_mount="${2:-}"

  debug "_preflight_path_safety_validate_transactions: efi=$efi_mount esp=${esp_mount:-<none>}"

  # EFI transaction scan (required).
  _preflight_path_safety_no_stale_transactions "$efi_mount"

  # ESP transaction scan (optional — only when provided).
  if [[ -n "$esp_mount" ]]; then
    _preflight_path_safety_no_stale_transactions "$esp_mount"
  else
    debug "_preflight_path_safety_validate_transactions: no ESP mount — skipping"
  fi

  debug "_preflight_path_safety_validate_transactions: all transaction checks passed"
}

# preflight_path_safety_validate EFI_MOUNT [ESP_MOUNT]
#   Combined orchestrator: run all path safety validations in sequence.
#   Performs destination safety checks (PF-55) followed by transaction
#   scans (PF-56).  Dies on the first failure.
#
#   NOTE: Path safety validation is subject to TOCTOU (time-of-check-to-time-of-use)
#   race conditions. A path validated here could be replaced with a symlink or
#   nested mount before the write occurs. Callers should:
#     1. Acquire the deployment lock before calling this function.
#     2. Retain the lock through commit.
#     3. Revalidate the destination parent immediately before each write.
preflight_path_safety_validate() {
  local efi_mount="${1:?preflight_path_safety_validate: missing EFI mount}"
  local esp_mount="${2:-}"

  debug "preflight_path_safety_validate: efi=$efi_mount esp=${esp_mount:-<none>}"

  # Destination safety (PF-55a + PF-55b).
  _preflight_path_safety_validate_destinations "$efi_mount" "$esp_mount"

  # Stale transaction scan (PF-56).
  _preflight_path_safety_validate_transactions "$efi_mount" "$esp_mount"

  debug "preflight_path_safety_validate: all path safety checks passed"
}
