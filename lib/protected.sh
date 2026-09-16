#!/usr/bin/env bash
# ── Protected host resources ────────────────────────────────────────────────
# Paths that cleanup must NEVER unmount, delete, or rsync-over.
# These are fundamental host resources — they don't change between builds.
#
# Defense layers:
#   1. Lexical match: protected_path() rejects paths at or below these
#   2. Mount-source validation: protected_mount_sources() rejects recursive
#      operations when descendant mounts source from protected host trees
#
# Sourced by library-loader.sh BEFORE mounts.sh.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/protected.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ── Protected path list ─────────────────────────────────────────────────────
# Ancestor-aware: protecting /dev also protects /dev/zero, /dev/pts, etc.
# Do NOT include / — it would protect every absolute path.
PROTECTED_PATHS=(
  /dev
  /proc
  /sys
  /run
)

# ── Lexical path protection ─────────────────────────────────────────────────
# Check if a path is at or below any protected path.
# Uses realpath -m for normalization (handles nonexistent paths).
# Returns 0 if protected (or normalization fails — fail-closed), 1 if safe.
protected_path() {
  local input="${1:?protected_path: missing path}"
  local path protected

  path="$(realpath -m -- "$input" 2>/dev/null)" || {
    warn "protected_path: cannot normalize path — treating as protected: $input"
    return 0
  }
  # Strip trailing slash for consistent matching
  path="${path%/}"

  for protected in "${PROTECTED_PATHS[@]}"; do
    case "$path" in
      "$protected" | "$protected"/*)
        return 0
        ;;
    esac
  done

  return 1
}

# ── Mount-source validation ─────────────────────────────────────────────────
# Check if any mount at or below a target has a source that resolves to
# a protected host resource. This catches the bind-mount-through-workspace
# pattern: /workspace/merged/dev -> /dev (target is safe, source is not).
#
# Arguments:
#   $1 — target directory to inspect
# Returns:
#   0 if a protected mount source is found, or if mount table cannot be read (fail-closed)
#   1 if all mount sources are safe
protected_mount_sources() {
  local target="${1:?protected_mount_sources: missing target}"
  local normalized="${target%/}"

  # Get all mounts at or below target with their sources
  local mount_info
  if ! mount_info="$(findmnt -rno TARGET,SOURCE --kernel 2>/dev/null)"; then
    warn "protected_mount_sources: unable to read kernel mount table — treating as protected"
    return 0 # fail-closed
  fi

  local mount_target mount_source resolved_source
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # findmnt -r output: TARGET SOURCE
    mount_target="${line%% *}"
    mount_source="${line#* }"

    # Check if this mount is at or below our target
    if [[ "$mount_target" == "$normalized" || "$mount_target" == "$normalized"/* ]]; then
      # Workspace exclusion: if the mount target is inside the workspace,
      # skip the source protection check — workspace mounts may legitimately
      # use devices from protected host trees (e.g. /dev/loop0p3).
      local _target_in_workspace=0
      local _target_resolved
      _target_resolved="$(realpath -m -- "$mount_target" 2>/dev/null)" || _target_resolved="$mount_target"
      if [[ -n "${CLEANUP_WORKSPACE_ROOT:-}" ]]; then
        if [[ "$_target_resolved" == "${CLEANUP_WORKSPACE_ROOT}" || "$_target_resolved" == "${CLEANUP_WORKSPACE_ROOT%/}"/* ]]; then
          _target_in_workspace=1
        fi
      fi
      # Also check /dev/shm/steamos-build as a fallback workspace path
      if [[ "$_target_resolved" == /dev/shm/steamos-build || "$_target_resolved" == /dev/shm/steamos-build/* ]]; then
        _target_in_workspace=1
      fi

      # If target is in workspace, skip source protection check
      if [[ $_target_in_workspace -eq 1 ]]; then
        continue
      fi

      # Resolve the source to its canonical path
      resolved_source="$(realpath -m -- "$mount_source" 2>/dev/null)" || continue
      resolved_source="${resolved_source%/}"

      # Check if the resolved source is at or below a protected path
      local protected
      for protected in "${PROTECTED_PATHS[@]}"; do
        case "$resolved_source" in
          "$protected" | "$protected"/*)
            warn "protected_mount_sources: mount $mount_target has protected source $resolved_source (via $mount_source)"
            return 0
            ;;
        esac
      done
    fi
  done <<<"$mount_info"

  return 1
}
