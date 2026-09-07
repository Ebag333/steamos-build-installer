#!/bin/bash
#
# Lint: private-funcs
#
# Detects functions that are only called within their defining file but are
# not prefixed with an underscore.  Functions with zero references outside
# their definition file are considered private and should be prefixed with
# `_` to signal their intended scope.
#
# Inline suppression:  # lint-ignore: private-funcs
#
# Usage:
#   tools/lint/private-funcs.sh [--fix] [--repo-root DIR]
#
# Options:
#   --fix         Automatically rename functions to add '_' prefix
#   --repo-root DIR  Set the repository root directory
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
FIX_MODE=false

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix)
      FIX_MODE=true
      shift
      ;;
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
# Fix function: rename functions to add '_' prefix
# ---------------------------------------------------------------------------

_fix_private_funcs() {
  local fixed=0

  for report in "${reports[@]}"; do
    IFS=: read -r file line func_name <<<"$report"

    # Get the full path
    local file_path="$REPO_ROOT/$file"

    # Rename function definition and all call sites within the file
    sed -i -E "s/\b${func_name}\b/_${func_name}/g" "$file_path"

    echo "private-funcs: $file: fixed (renamed $func_name → _${func_name})"
    fixed=$((fixed + 1))
  done

  if [[ $fixed -gt 0 ]]; then
    echo ""
    echo "PRIVATE-FUNCS FIXED: $fixed function(s) renamed"
  fi
}

# ---------------------------------------------------------------------------
# Main scan function
# ---------------------------------------------------------------------------

# Global arrays for scan results
declare -a reports=()
declare -a external_call_reports=()
declare -a func_defs=()
declare -a private_func_defs=()

_run_scan() {
  # ---------------------------------------------------------------------------
  # Collect function definitions
  # ---------------------------------------------------------------------------

  # Reset arrays
  func_defs=()
  private_func_defs=()
  reports=()
  external_call_reports=()

  while IFS= read -r -d '' file; do
    rel="${file#"$REPO_ROOT"/}"
    lineno=0
    prev_line=""

    while IFS= read -r line; do
      lineno=$((lineno + 1))

      # Match function definitions:
      #   name() {
      #   function name {
      #   function name() {
      # Only top-level (non-indented) definitions
      if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)\(\)[[:space:]]*\{ ]] \
        || [[ "$line" =~ ^function[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\{ ]] \
        || [[ "$line" =~ ^function[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)\(\)[[:space:]]*\{ ]]; then
        func_name="${BASH_REMATCH[1]}"

        # Check for lint-ignore on same line or previous line
        if [[ "$line" =~ lint-ignore:[[:space:]]*private-funcs ]] \
          || [[ "$prev_line" =~ lint-ignore:[[:space:]]*private-funcs ]]; then
          prev_line="$line"
          continue
        fi

        # Separate private functions from non-private ones
        if [[ "$func_name" == _* ]]; then
          private_func_defs+=("$rel:$lineno:$func_name")
        else
          func_defs+=("$rel:$lineno:$func_name")
        fi
      fi

      prev_line="$line"
    done <"$file"
  done < <(find "$REPO_ROOT" -name '*.sh' -not -path '*/.git/*' -print0)

  # ---------------------------------------------------------------------------
  # Check function references
  # ---------------------------------------------------------------------------

  violations=0
  missing_prefix_count=0
  external_call_count=0

  for def in "${func_defs[@]}"; do
    IFS=: read -r file line func_name <<<"$def"

    # Count references across all .sh files (word-boundary match)
    # Exclude: the definition line itself, comment lines, function definitions
    ref_count=$(
      cd "$REPO_ROOT" \
        && { grep -rw -rn --include='*.sh' -- "$func_name" . 2>/dev/null || true; } \
        | sed 's|^\./||' \
          | grep -v "^${file}:" \
          | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' \
          | grep -v "^[^:]*:[0-9]*:${func_name}()" \
          | grep -c -v "^[^:]*:[0-9]*:function ${func_name}"
    ) || ref_count=0

    if [[ $ref_count -eq 0 ]]; then
      reports+=("$file:$line:$func_name")
      violations=$((violations + 1))
      missing_prefix_count=$((missing_prefix_count + 1))
    fi
  done

  # --- Check for private functions called from outside their file ---
  if [[ "$FIX_MODE" != "true" ]]; then
    for def in "${private_func_defs[@]}"; do
      IFS=: read -r file line func_name <<<"$def"

      # Count references in OTHER files
      ref_count=$(
        cd "$REPO_ROOT" \
          && { grep -rw -rn --include='*.sh' -- "$func_name" . 2>/dev/null || true; } \
          | sed 's|^\./||' \
            | grep -v "^${file}:" \
            | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' \
            | grep -v "^[^:]*:[0-9]*:${func_name}()" \
            | grep -c -v "^[^:]*:[0-9]*:function ${func_name}"
      ) || ref_count=0

      if [[ "$ref_count" -gt 0 ]]; then
        # Get caller locations
        callers=$(
          cd "$REPO_ROOT" \
            && { grep -rw -rn --include='*.sh' -- "$func_name" . 2>/dev/null || true; } \
            | sed 's|^\./||' \
              | grep -v "^${file}:" \
              | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' \
              | grep -v "^[^:]*:[0-9]*:${func_name}()" \
              | grep -v "^[^:]*:[0-9]*:function ${func_name}" \
              | head -5
        ) || callers=""

        external_call_reports+=("${file}:${line}:${func_name}:${callers}")
        violations=$((violations + 1))
        external_call_count=$((external_call_count + 1))
      fi
    done
  fi

  # ---------------------------------------------------------------------------
  # Report
  # ---------------------------------------------------------------------------

  # Check 1: Functions missing '_' prefix
  for report in "${reports[@]}"; do
    IFS=: read -r file line func_name <<<"$report"
    echo "private-funcs: $file:$line: function '${func_name}()' is only used in this file — prefix with '_' to mark private"
  done

  # Check 2: Private functions called from outside their file
  if [[ "$FIX_MODE" != "true" ]]; then
    for report in "${external_call_reports[@]}"; do
      # Split on first three colons to get file:line:func_name, rest is callers
      IFS=: read -r file line func_name callers <<<"$report"
      echo "private-funcs: ${file}:${line}: private function '${func_name}' is called from outside its defining file"
      if [[ -n "$callers" ]]; then
        while IFS= read -r caller; do
          echo "  $caller"
        done <<<"$callers"
      fi
    done
  fi

  if [[ $violations -gt 0 ]]; then
    echo ""
    echo "FAIL: $violations function(s) should be marked private"
    if [[ $missing_prefix_count -gt 0 ]]; then
      echo "  - $missing_prefix_count function(s) should be prefixed with '_'"
    fi
    if [[ "$FIX_MODE" != "true" && $external_call_count -gt 0 ]]; then
      echo "  - $external_call_count private function(s) are called from outside their file"
    fi
    echo "To suppress a false positive, add:  # lint-ignore: private-funcs"
    return 1
  fi

  echo "PASS: private-funcs lint clean"
  return 0
}

# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------

if [[ "$FIX_MODE" == "true" ]]; then
  # Scan to populate reports[], then fix (no-op if nothing to fix)
  _run_scan || true
  _fix_private_funcs
  exit 0
else
  # Just scan and report
  _run_scan
  exit $?
fi
