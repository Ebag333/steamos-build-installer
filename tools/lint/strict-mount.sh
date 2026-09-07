#!/bin/bash
#
# Lint: strict-mount
#
# Detects raw mount, umount, and losetup calls outside of lib/mounts.sh.
# All mount operations should go through the proper API in lib/mounts.sh.
#
# Inline suppression:  # lint-ignore: strict-mount
#
# Usage:
#   tools/lint/strict-mount.sh [--repo-root DIR]
#
# Exit codes:
#   0 — no violations
#   1 — violations found
#   2 — usage error

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

REPO_ROOT=""

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)
      REPO_ROOT="${2:?--repo-root requires a path}"
      shift 2
      ;;
    -h | --help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$REPO_ROOT" ]]; then
  REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fi

# ---------------------------------------------------------------------------
# Files to exclude from scanning
# ---------------------------------------------------------------------------

# These files are allowed to use raw mount/umount/losetup
EXCLUDED_FILES=(
  "lib/mounts.sh"          # Where the primitives live
  "lib/atomupd-wrapper.sh" # Runtime self-heal wrapper
  "lib/installer.sh"       # Deployed runtime code
  "tools/compare-roots.sh" # Standalone tool with own cleanup trap
)

# ---------------------------------------------------------------------------
# Scan for violations
# ---------------------------------------------------------------------------

violations=0
_in_missing_commands=0
_in_heredoc=0

while IFS= read -r -d '' file; do
  # Get relative path for reporting
  rel="${file#"$REPO_ROOT"/}"

  # Skip linter files — linters shouldn't lint each other
  if [[ "$rel" == tools/lint/* ]]; then
    continue
  fi

  # Skip excluded files
  skip=false
  for excluded in "${EXCLUDED_FILES[@]}"; do
    if [[ "$rel" == "$excluded" ]]; then
      skip=true
      break
    fi
  done
  [[ "$skip" == true ]] && continue

  lineno=0
  while IFS= read -r line; do
    lineno=$((lineno + 1))

    # Skip comments
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    # Skip blank lines
    [[ -z "${line// /}" ]] && continue

    # Skip inline ignore
    [[ "$line" =~ lint-ignore:[[:space:]]*strict-mount ]] && continue

    # Skip propagation changes (not mount creation)
    if [[ "$line" =~ --make-rprivate ]] || [[ "$line" =~ --make-rslave ]] || [[ "$line" =~ --make-private ]]; then
      continue
    fi

    # Skip progress_emit calls (UI events, not mount operations)
    if [[ "$line" =~ progress_emit ]]; then
      continue
    fi

    # Track multi-line _missing_commands blocks
    if [[ "$_in_missing_commands" -eq 1 ]]; then
      if [[ "$line" =~ \) ]]; then
        _in_missing_commands=0
      fi
      continue
    fi
    if [[ "$line" =~ _missing_commands ]]; then
      _in_missing_commands=1
      continue
    fi

    # Skip dependency declarations: for loops, _missing_commands args, associative array keys
    if [[ "$line" =~ for[[:space:]]+[a-zA-Z_]+[[:space:]]+in[[:space:]] ]] \
      || [[ "$line" =~ ^[[:space:]]*\[[a-zA-Z_][a-zA-Z_0-9]*\]= ]]; then
      continue
    fi

    # Skip remount lines (mount -o remount,... is not a new mount)
    if [[ "$line" =~ remount ]]; then
      continue
    fi

    # Skip function definitions
    [[ "$line" =~ ^[[:space:]]*function[[:space:]]+ ]] && continue
    [[ "$line" =~ ^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{ ]] && continue

    # Skip variable assignments containing these words
    [[ "$line" =~ ^[[:space:]]*(local|declare|export|readonly)[[:space:]]+ ]] && continue

    # Skip lines that are arguments to findmnt, mountpoint, etc.
    [[ "$line" =~ ^[[:space:]]*(findmnt|mountpoint)[[:space:]] ]] && continue

    # Skip lines where mount/umount/losetup only appear inside string literals
    # passed to logging/error commands.  Strip quoted strings and re-check;
    # if the keyword disappears it was only in a message, not a real call.
    _line_stripped="$line"
    _line_stripped="${_line_stripped//\"[^\"]*\"/}"
    _line_stripped="${_line_stripped//\'[^\']*\'/}"

    # Skip heredoc content (documentation, not shell commands)
    _heredoc_re='^[[:space:]]*<<'
    if [[ "$_line_stripped" =~ $_heredoc_re ]]; then
      _in_heredoc=1
      continue
    fi
    if [[ "$_in_heredoc" -eq 1 ]]; then
      [[ "$_line_stripped" == *"EOF"* ]] && _in_heredoc=0
      continue
    fi

    # Filter out --mount, --umount, --losetup (flags/arguments, not commands)
    _line_stripped="${_line_stripped//--mount/}"
    _line_stripped="${_line_stripped//--umount/}"
    _line_stripped="${_line_stripped//--losetup/}"

    # Filter out case pattern labels (mount), umount), losetup))
    _line_stripped="${_line_stripped//mount)/}"
    _line_stripped="${_line_stripped//umount)/}"
    _line_stripped="${_line_stripped//losetup)/}"

    # Check for raw mount calls
    if [[ "$_line_stripped" =~ (^|[^a-zA-Z0-9_])mount([^a-zA-Z0-9_]|$) ]]; then
      # Exclude known safe function names
      if [[ ! "$line" =~ cleanup_track_mount ]] \
        && [[ ! "$line" =~ cleanup_mount_chroot ]] \
        && [[ ! "$line" =~ _cleanup_mount ]] \
        && [[ ! "$line" =~ cleanup_unmount_registered ]] \
        && [[ ! "$line" =~ strict_unmount ]] \
        && [[ ! "$line" =~ mounts_for_loop ]]; then
        echo "strict-mount: $rel:$lineno: raw 'mount' call — use cleanup_track_mount or strict_unmount"
        violations=$((violations + 1))
      fi
    fi

    # Check for raw umount calls
    if [[ "$_line_stripped" =~ (^|[^a-zA-Z0-9_])umount([^a-zA-Z0-9_]|$) ]]; then
      # Exclude known safe function names
      if [[ ! "$line" =~ cleanup_unmount_registered ]] \
        && [[ ! "$line" =~ strict_unmount ]]; then
        echo "strict-mount: $rel:$lineno: raw 'umount' call — use strict_unmount or cleanup_unmount_registered"
        violations=$((violations + 1))
      fi
    fi

    # Check for raw losetup calls
    if [[ "$_line_stripped" =~ (^|[^a-zA-Z0-9_])losetup([^a-zA-Z0-9_]|$) ]]; then
      # Skip bare losetup existence checks (no flags = query)
      _losetup_bare_re='^[[:space:]]*losetup[[:space:]]+[$"/]'
      if [[ "$_line_stripped" =~ $_losetup_bare_re ]]; then
        continue
      fi
      # Skip read-only query patterns (no loop device modification)
      if [[ "$_line_stripped" =~ losetup[[:space:]]+-.*j ]] \
        || [[ "$_line_stripped" =~ losetup[[:space:]]+-.*a ]] \
        || [[ "$_line_stripped" =~ losetup[[:space:]]+-.*l ]]; then
        continue
      fi
      # Exclude known safe function names
      if [[ ! "$line" =~ cleanup_track_loop ]] \
        && [[ ! "$line" =~ strict_detach_loop ]] \
        && [[ ! "$line" =~ cleanup_attach_loop ]] \
        && [[ ! "$line" =~ loops_for_file ]] \
        && [[ ! "$line" =~ mounts_for_loop ]] \
        && [[ ! "$line" =~ refresh_loop_size ]]; then
        echo "strict-mount: $rel:$lineno: raw 'losetup' call — use cleanup_track_loop or cleanup_attach_loop"
        violations=$((violations + 1))
      fi
    fi
  done <"$file"
done < <(find "$REPO_ROOT" -name '*.sh' -not -path '*/.git/*' -print0)

# ---------------------------------------------------------------------------
# Exit
# ---------------------------------------------------------------------------

if [[ $violations -gt 0 ]]; then
  echo ""
  echo "FAIL: $violations raw mount/umount/losetup call(s) found"
  echo "All mount operations should go through the API in lib/mounts.sh."
  echo "To suppress a false positive, add:  # lint-ignore: strict-mount"
  exit 1
fi

echo "PASS: strict-mount lint clean"
exit 0
