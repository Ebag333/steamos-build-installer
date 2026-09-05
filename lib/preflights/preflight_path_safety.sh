#!/bin/bash
#
# steamos-build-installer — lib/preflight_path_safety.sh
# Path safety validation: ensures destination paths are not symlinks that
# escape their expected mount boundaries, and detects stale transaction
# state (interrupted writes leaving .new/.bak/.tmp/.transaction-* files).
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
    || die "_pf_path_resolve_canonical: failed to resolve '$target'"

  [[ -n "$resolved" ]] \
    || die "_pf_path_resolve_canonical: resolved path is empty for '$target'"

  echo "$resolved"
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
#     3. Get the device backing the mountpoint via findmnt.
#     4. Compare major:minor device IDs.
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
  resolved_target="$(_pf_path_resolve_canonical "$target")"
  resolved_mount="$(_pf_path_resolve_canonical "$mountpoint")"

  # Strip trailing slashes for consistent comparison.
  resolved_target="${resolved_target%/}"
  resolved_mount="${resolved_mount%/}"

  # --- Device ID comparison ---
  # Get the device backing the resolved target path.
  local target_dev
  target_dev="$(stat -c '%d' "$resolved_target" 2>/dev/null)" || target_dev=""

  # Get the device backing the mountpoint.
  local mount_dev
  mount_dev="$(findmnt -rn -o MAJ:MIN "$resolved_mount" 2>/dev/null | head -1)" || mount_dev=""

  # If findmnt returned major:minor, extract just the device number for
  # comparison with stat's %d (which returns the decimal device number).
  # stat %d returns st_dev, which for filesystem root is the device.
  # We compare both the mountpoint's device and the target's device.
  local mount_stat_dev
  mount_stat_dev="$(stat -c '%d' "$resolved_mount" 2>/dev/null)" || mount_stat_dev=""

  if [[ -n "$target_dev" && -n "$mount_stat_dev" ]]; then
    if [[ "$target_dev" != "$mount_stat_dev" ]]; then
      debug "_pf_path_within_mount: device mismatch ($target_dev != $mount_stat_dev) — target escapes mount"
      return 1
    fi
  fi

  # --- Path prefix check ---
  # The resolved target must be equal to or under the mountpoint.
  # Equivalently: $resolved_target must start with "$resolved_mount/" or
  # equal $resolved_mount exactly.
  if [[ "$resolved_target" != "$resolved_mount" && "$resolved_target" != "$resolved_mount"/* ]]; then
    debug "_pf_path_within_mount: path '$resolved_target' is not under mount '$resolved_mount'"
    return 1
  fi

  return 0
}

# _pf_path_scan_transaction_artifacts DIRECTORY [MAXDEPTH]
#   Search DIRECTORY recursively for stale transaction files.
#   Matches: *.new, *.bak, *.tmp, *.transaction-*
#   Excludes: .building, .build-complete marker files.
#
#   Uses find with -maxdepth to limit traversal (default: 5 levels).
#   Prints matching paths to stdout, one per line.
#   Returns 0 if artifacts are found (non-empty output), 1 if clean.
_pf_path_scan_transaction_artifacts() {
  local directory="${1:?_pf_path_scan_transaction_artifacts: missing directory}"
  local maxdepth="${2:-5}"

  if [[ ! -d "$directory" ]]; then
    debug "_pf_path_scan_transaction_artifacts: directory does not exist: $directory"
    return 1
  fi

  local matches
  matches="$(find "$directory" \
    -maxdepth "$maxdepth" \
    \( \
      -name '*.new' \
      -o -name '*.bak' \
      -o -name '*.tmp' \
      -o -name '*.transaction-*' \
    \) \
    -not -name '.building' \
    -not -name '.build-complete' \
    -type f \
    2>/dev/null)" || matches=""

  if [[ -n "$matches" ]]; then
    echo "$matches"
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# Individual checks — independently callable
# ---------------------------------------------------------------------------

# preflight_path_safety_not_symlink PATH LABEL
#   PF-55a: Verify the destination PATH is not a symlink.
#   Symlinks are checked BEFORE realpath resolution to detect escapes.
#   LABEL is used in diagnostic messages (e.g. "EFI", "ESP").
#   Dies if the path is a symlink.
preflight_path_safety_not_symlink() {
  local target="${1:?preflight_path_safety_not_symlink: missing path}"
  local label="${2:-destination}"

  if [[ -L "$target" ]]; then
    local link_target
    link_target="$(readlink "$target" 2>/dev/null)" || link_target="<unreadable>"
    die "PF-55a: $label path is a symlink (escape vector): $target -> $link_target"
  fi

  debug "PF-55a: $label path is not a symlink: $target"
}

# preflight_path_safety_within_mount PATH MOUNTPOINT LABEL
#   PF-55b: Verify the destination PATH resolves within the expected mount.
#   Uses device ID comparison to detect cross-filesystem symlink escapes.
#   LABEL is used in diagnostic messages (e.g. "EFI", "ESP").
#   Dies if the path escapes the mount boundary.
preflight_path_safety_within_mount() {
  local target="${1:?preflight_path_safety_within_mount: missing path}"
  local mountpoint="${2:?preflight_path_safety_within_mount: missing mountpoint}"
  local label="${3:-destination}"

  if ! _pf_path_within_mount "$target" "$mountpoint"; then
    local resolved_target resolved_mount
    resolved_target="$(_pf_path_resolve_canonical "$target")" || resolved_target="$target"
    resolved_mount="$(_pf_path_resolve_canonical "$mountpoint")" || resolved_mount="$mountpoint"
    die "PF-55b: $label path escapes its mount boundary ($target resolves to $resolved_target, mount is $resolved_mount)"
  fi

  debug "PF-55b: $label path is within mount: $target -> $mountpoint"
}

# preflight_path_safety_destination_safe PATH MOUNTPOINT LABEL
#   PF-55: Combined destination safety check.
#   Verifies the path is not a symlink (PF-55a) AND resolves within the
#   expected mount (PF-55b).  The symlink check MUST happen before the
#   realpath-based mount check so that symlink escapes are caught first.
preflight_path_safety_destination_safe() {
  local target="${1:?preflight_path_safety_destination_safe: missing path}"
  local mountpoint="${2:?preflight_path_safety_destination_safe: missing mountpoint}"
  local label="${3:-destination}"

  # PF-55a: Symlink check (must precede realpath resolution).
  preflight_path_safety_not_symlink "$target" "$label"

  # PF-55b: Mount boundary check (uses device ID comparison).
  preflight_path_safety_within_mount "$target" "$mountpoint" "$label"

  debug "PF-55: $label destination is safe: $target ($mountpoint)"
}

# preflight_path_safety_no_stale_transactions DIRECTORY [MAXDEPTH]
#   PF-56: Verify no stale transaction files exist in the given directory.
#   Matches: *.new, *.bak, *.tmp, *.transaction-*
#   Excludes: .building, .build-complete marker files.
#   Dies if stale artifacts are found.
preflight_path_safety_no_stale_transactions() {
  local directory="${1:?preflight_path_safety_no_stale_transactions: missing directory}"
  local maxdepth="${2:-5}"

  if [[ ! -d "$directory" ]]; then
    debug "PF-56: directory does not exist — skipping transaction scan: $directory"
    return 0
  fi

  local artifacts
  if artifacts="$(_pf_path_scan_transaction_artifacts "$directory" "$maxdepth")"; then
    # _pf_path_scan_transaction_artifacts returns 0 and prints matches.
    local count
    count="$(echo "$artifacts" | wc -l)"
    die "PF-56: stale transaction artifacts detected ($count file(s)) in $directory:
$artifacts"
  fi

  debug "PF-56: no stale transactions in $directory"
}

# ---------------------------------------------------------------------------
# Orchestrators
# ---------------------------------------------------------------------------

# preflight_path_safety_validate_destinations EFI_MOUNT [ESP_MOUNT]
#   Validate destination path safety for EFI and optional ESP mounts.
#   For each mount, checks that:
#     - The mount path itself is not a symlink (PF-55a)
#     - The mount path resolves within its expected boundary (PF-55b)
#   Dies on the first failure.
preflight_path_safety_validate_destinations() {
  local efi_mount="${1:?preflight_path_safety_validate_destinations: missing EFI mount}"
  local esp_mount="${2:-}"

  debug "preflight_path_safety_validate_destinations: efi=$efi_mount esp=${esp_mount:-<none>}"

  # EFI destination safety (required).
  preflight_path_safety_destination_safe "$efi_mount" "/" "EFI"

  # ESP destination safety (optional — only when provided).
  if [[ -n "$esp_mount" ]]; then
    preflight_path_safety_destination_safe "$esp_mount" "/" "ESP"
  else
    debug "preflight_path_safety_validate_destinations: no ESP mount — skipping"
  fi

  debug "preflight_path_safety_validate_destinations: all destination checks passed"
}

# preflight_path_safety_validate_transactions EFI_MOUNT [ESP_MOUNT]
#   Validate no stale transaction artifacts exist in EFI and optional ESP
#   mount directories.  Uses maxdepth of 5 for recursive scanning.
#   Dies on the first failure.
preflight_path_safety_validate_transactions() {
  local efi_mount="${1:?preflight_path_safety_validate_transactions: missing EFI mount}"
  local esp_mount="${2:-}"

  debug "preflight_path_safety_validate_transactions: efi=$efi_mount esp=${esp_mount:-<none>}"

  # EFI transaction scan (required).
  preflight_path_safety_no_stale_transactions "$efi_mount"

  # ESP transaction scan (optional — only when provided).
  if [[ -n "$esp_mount" ]]; then
    preflight_path_safety_no_stale_transactions "$esp_mount"
  else
    debug "preflight_path_safety_validate_transactions: no ESP mount — skipping"
  fi

  debug "preflight_path_safety_validate_transactions: all transaction checks passed"
}

# preflight_path_safety_validate EFI_MOUNT [ESP_MOUNT]
#   Combined orchestrator: run all path safety validations in sequence.
#   Performs destination safety checks (PF-55) followed by transaction
#   scans (PF-56).  Dies on the first failure.
preflight_path_safety_validate() {
  local efi_mount="${1:?preflight_path_safety_validate: missing EFI mount}"
  local esp_mount="${2:-}"

  debug "preflight_path_safety_validate: efi=$efi_mount esp=${esp_mount:-<none>}"

  # Destination safety (PF-55a + PF-55b).
  preflight_path_safety_validate_destinations "$efi_mount" "$esp_mount"

  # Stale transaction scan (PF-56).
  preflight_path_safety_validate_transactions "$efi_mount" "$esp_mount"

  debug "preflight_path_safety_validate: all path safety checks passed"
}
