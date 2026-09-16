#!/bin/bash
#
# Lint: no-shadow
#
# Detects function names defined in more than one .sh file.
# Cross-file function redefinition causes silent overrides — the last
# sourced file wins, which is almost never intentional.
#
# Inline suppression:  # lint-ignore: no-shadow
#
# Usage:
#   tools/lint/no-shadow.sh [--repo-root DIR]
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
# Collect function definitions
# ---------------------------------------------------------------------------

# Associative array: func_name -> newline-separated list of "file:line"
declare -A func_locations

while IFS= read -r -d '' file; do
  rel="${file#"$REPO_ROOT"/}"
  lineno=0

  while IFS= read -r line; do
    lineno=$((lineno + 1))

    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    # Skip inline ignore
    [[ "$line" =~ lint-ignore:[[:space:]]*no-shadow ]] && continue

    # Match:  funcname() {
    if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z_0-9]*)\(\)[[:space:]]*\{ ]]; then
      func_name="${BASH_REMATCH[1]}"

      if [[ -n "${func_locations[$func_name]+_}" ]]; then
        func_locations[$func_name]+=$'\n'"$rel:$lineno"
      else
        func_locations[$func_name]="$rel:$lineno"
      fi
    fi
  done <"$file"
done < <(find "$REPO_ROOT" -name '*.sh' -print0)

# ---------------------------------------------------------------------------
# Report duplicates
# ---------------------------------------------------------------------------

violations=0

for func_name in "${!func_locations[@]}"; do
  locations="${func_locations[$func_name]}"
  count="$(echo "$locations" | wc -l)"

  if [[ "$count" -gt 1 ]]; then
    echo "shadow: function '$func_name' defined in $count files:"
    echo "$locations" | while IFS= read -r loc; do
      echo "  $loc"
    done
    violations=$((violations + 1))
  fi
done

# ---------------------------------------------------------------------------
# Exit
# ---------------------------------------------------------------------------

if [[ $violations -gt 0 ]]; then
  echo ""
  echo "FAIL: $violations function(s) defined in more than one file"
  echo "Cross-file redefinition causes silent overrides (last source wins)."
  echo "Rename one, or consolidate into a single definition."
  echo "To suppress a false positive, add:  # lint-ignore: no-shadow"
  exit 1
fi

echo "PASS: no-shadow lint clean"
exit 0
