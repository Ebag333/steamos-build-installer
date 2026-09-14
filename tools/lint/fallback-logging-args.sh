#!/bin/bash
#
# Lint: fallback-logging-args
#
# Detects fallback logging functions that use the wrong positional argument
# for the message.  The canonical log_* API is:
#
#   log_<LEVEL>  CATEGORY  EVENT  MESSAGE  [KEY VALUE]…
#
# so the message is always $3.  Fallback shims must also extract $3.
#
# Inline suppression:  # lint-ignore: fallback-logging-args
#
# Usage:
#   tools/lint/fallback-logging-args.sh [--repo-root DIR]
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
# Scan for fallback log_* functions with wrong message argument
# ---------------------------------------------------------------------------

violations=0

while IFS= read -r -d '' file; do
  rel="${file#"$REPO_ROOT"/}"

  # Skip lib/logging.sh — canonical definitions use _log_emit, not printf
  [[ "$rel" == "lib/logging.sh" ]] && continue

  lineno=0
  func_depth=0
  in_log_func=false

  while IFS= read -r line; do
    lineno=$((lineno + 1))

    # Skip inline ignore on the current line
    [[ "$line" =~ lint-ignore:[[:space:]]*fallback-logging-args ]] && continue

    # Detect log_* function definition (one-liner or multi-line opener)
    #   log_info() { ... }
    #   log_info() {
    if [[ "$line" =~ ^[[:space:]]*(log_(info|warn|error|notice|die|debug))\(\) ]]; then
      func_name="${BASH_REMATCH[1]}"

      # Check if this is a one-liner (both { and } on the same line)
      # Count braces on this line
      open_count=0
      close_count=0
      for ((i = 0; i < ${#line}; i++)); do
        char="${line:$i:1}"
        [[ "$char" == "{" ]] && open_count=$((open_count + 1))
        [[ "$char" == "}" ]] && close_count=$((close_count + 1))
      done

      if [[ $open_count -eq 0 ]]; then
        # No brace found — skip (malformed, but don't crash)
        continue
      fi

      if [[ $close_count -gt 0 ]] && [[ $open_count -eq $close_count ]]; then
        # One-liner: { and } on same line — process body inline
        in_log_func=true
        # Check the one-liner's body for printf with wrong argument
        if [[ "$line" =~ printf ]] && [[ "$line" =~ %s ]]; then
          if ! [[ "$line" =~ \$3[^0-9] ]] && ! [[ "$line" =~ \$\{3(\}|-|:) ]]; then
            # Also check for suppression on the function line itself
            if ! [[ "$line" =~ lint-ignore:[[:space:]]*fallback-logging-args ]]; then
              echo "fallback-logging-args: $rel:$lineno: ${func_name}() fallback must use \$3 for message argument"
              violations=$((violations + 1))
            fi
          fi
        fi
        in_log_func=false
        func_depth=0
        continue
      fi

      # Multi-line function: start tracking depth
      func_depth=$open_count
      in_log_func=true
      continue
    fi

    # If we're inside a multi-line log_* function, track brace depth
    if [[ "$in_log_func" == true ]]; then
      for ((i = 0; i < ${#line}; i++)); do
        char="${line:$i:1}"
        [[ "$char" == "{" ]] && func_depth=$((func_depth + 1))
        [[ "$char" == "}" ]] && func_depth=$((func_depth - 1))
      done

      # Skip comments and blank lines
      if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line// /}" ]]; then
        # Check if function ends on this line
        [[ "$func_depth" -le 0 ]] && {
          in_log_func=false
          func_depth=0
        }
        continue
      fi

      # Skip inline ignore
      if [[ "$line" =~ lint-ignore:[[:space:]]*fallback-logging-args ]]; then
        [[ "$func_depth" -le 0 ]] && {
          in_log_func=false
          func_depth=0
        }
        continue
      fi

      # Check for printf with %s — must use $3 or ${3...}
      if [[ "$line" =~ printf ]] && [[ "$line" =~ %s ]]; then
        if ! [[ "$line" =~ \$3[^0-9] ]] && ! [[ "$line" =~ \$\{3(\}|-|:) ]]; then
          echo "fallback-logging-args: $rel:$lineno: ${func_name}() fallback must use \$3 for message argument"
          violations=$((violations + 1))
        fi
      fi

      # Function body ended
      if [[ "$func_depth" -le 0 ]]; then
        in_log_func=false
        func_depth=0
      fi
    fi
  done <"$file"
done < <(find "$REPO_ROOT" -name '*.sh' -print0)

# ---------------------------------------------------------------------------
# Exit
# ---------------------------------------------------------------------------

if [[ $violations -gt 0 ]]; then
  echo ""
  echo "FAIL: $violations fallback logging function(s) use wrong message argument"
  echo "The canonical log_* API puts the message at \$3 (CATEGORY EVENT MESSAGE)."
  echo "Fallback shims must also extract \$3, e.g.:  printf '... %s' \"\${3:-}\""
  echo "To suppress a false positive, add:  # lint-ignore: fallback-logging-args"
  exit 1
fi

echo "PASS: fallback-logging-args lint clean"
exit 0
