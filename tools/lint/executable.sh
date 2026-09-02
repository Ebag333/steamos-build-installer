#!/bin/bash
#
# Lint: executable
#
# Checks that all .sh files have the executable bit set.
# Non-executable shell scripts are a common packaging bug.
#
# Inline suppression:  # lint-ignore: executable
#
# Usage:
#   tools/lint/executable.sh [--repo-root DIR] [--fix]
#
# Options:
#   --fix    Auto-fix by running chmod +x on non-executable files
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
    --repo-root)
      REPO_ROOT="${2:?--repo-root requires a path}"
      shift 2
      ;;
    --fix)
      FIX_MODE=true
      shift
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
# Scan
# ---------------------------------------------------------------------------

violations=0
fixed=0

while IFS= read -r -d '' file; do
  rel="${file#"$REPO_ROOT"/}"

  # Check if the file has the executable bit
  if [[ ! -x "$file" ]]; then
    # Check for inline suppression
    has_suppress=false
    while IFS= read -r line; do
      if [[ "$line" =~ lint-ignore:[[:space:]]*executable ]]; then
        has_suppress=true
        break
      fi
    done <"$file"

    if [[ "$has_suppress" == true ]]; then
      continue
    fi

    if [[ "$FIX_MODE" == true ]]; then
      if chmod +x "$file" 2>/dev/null; then
        echo "executable: $rel: fixed (chmod +x)"
        fixed=$((fixed + 1))
      else
        echo "executable: $rel: cannot fix (permission denied)"
        violations=$((violations + 1))
      fi
    else
      echo "executable: $rel: not executable"
      violations=$((violations + 1))
    fi
  fi
done < <(find "$REPO_ROOT" -name '*.sh' -print0)

# ---------------------------------------------------------------------------
# Exit
# ---------------------------------------------------------------------------

if [[ "$FIX_MODE" == true ]]; then
  if [[ $fixed -gt 0 ]]; then
    echo ""
    echo "FIXED: $fixed file(s) made executable"
  fi
  if [[ $violations -gt 0 ]]; then
    echo ""
    echo "FAIL: $violations file(s) could not be fixed"
    exit 1
  fi
  echo "PASS: executable lint clean (after fixes)"
  exit 0
fi

if [[ $violations -gt 0 ]]; then
  echo ""
  echo "FAIL: $violations file(s) not executable"
  echo "Shell scripts should have the executable bit set."
  echo "To suppress a false positive, add:  # lint-ignore: executable"
  exit 1
fi

echo "PASS: executable lint clean"
exit 0
