#!/bin/bash
#
# Lint: no-post-incr
#
# Detects ((VAR++)) in arithmetic contexts, which returns exit code 1 when
# the variable is 0 (the old value is falsy).  Under `set -e` this kills
# the script silently.
#
# Bad:   ((x++))   — evaluates to old value; 0 is falsy → exit 1
# Good:  ((++x))   — evaluates to new value; 1 is truthy → exit 0
# Good:  x=$((x + 1)) — assignment, always succeeds
#
# Inline suppression:  # lint-ignore: no-post-incr
#
# Usage:
#   tools/lint/no-post-incr.sh [--repo-root DIR]
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
# Scan for ((VAR++)) patterns
# ---------------------------------------------------------------------------

violations=0

while IFS= read -r -d '' file; do
  rel="${file#"$REPO_ROOT"/}"
  lineno=0

  while IFS= read -r line; do
    lineno=$((lineno + 1))

    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    # Skip inline ignore
    [[ "$line" =~ lint-ignore:[[:space:]]*no-post-incr ]] && continue

    # Match:  ((VAR++))  or  (( VAR++ ))
    # Only match when (( appears as a statement (start of line or after ; & |),
    # not inside strings.  Exclude for-loop headers:  for ((i = 0; ...; i++))
    if [[ "$line" =~ ^[[:space:]]*for[[:space:]] ]]; then
      continue
    fi

    # Skip lines where (( is inside a string (echo, printf, etc.)
    # Heuristic: if the line starts with echo/printf/log/warn and contains
    # quoted text with ((, skip it.
    if [[ "$line" =~ ^[[:space:]]*(echo|printf|log|warn|debug)[[:space:]] ]] && [[ "$line" =~ \".*\(\(.*\+\+.*\) ]]; then
      continue
    fi

    if [[ "$line" =~ \(\([[:space:]]*[a-zA-Z_][a-zA-Z_0-9]*\+\+[[:space:]]*\)\) ]]; then
      # Extract the variable name for the message
      var_match="${BASH_REMATCH[0]}"
      var_name="$(echo "$var_match" | grep -oE '[a-zA-Z_][a-zA-Z_0-9]*\+\+' | head -1 | sed 's/++//')"
      echo "no-post-incr: $rel:$lineno: (( ${var_name}++ )) — use (( ++${var_name} )) or ${var_name}=\$(( ${var_name} + 1 ))"
      violations=$((violations + 1))
    fi
  done <"$file"
done < <(find "$REPO_ROOT" -name '*.sh' -print0)

# ---------------------------------------------------------------------------
# Exit
# ---------------------------------------------------------------------------

if [[ $violations -gt 0 ]]; then
  echo ""
  echo "FAIL: $violations post-increment(s) in arithmetic context"
  echo "((x++)) returns exit code 1 when x=0 (old value is falsy)."
  echo "Under set -e this kills the script silently."
  echo "Use ((++x)) (pre-increment) or x=\$((x + 1)) instead."
  echo "To suppress a false positive, add:  # lint-ignore: no-post-incr"
  exit 1
fi

echo "PASS: no-post-incr lint clean"
exit 0
