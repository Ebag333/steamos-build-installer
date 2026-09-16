#!/bin/bash
#
# Lint: bash -n
#
# Runs `bash -n` (syntax check) on all .sh files in the repository.
# Catches syntax errors that other linters may miss.
#
# Usage:
#   tools/lint/bash-n.sh [--repo-root DIR]
#
# Exit codes:
#   0 — no violations
#   1 — violations found
#   2 — usage error

set -euo pipefail

REPO_ROOT=""

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

echo "Running bash -n..."
violations=0

while IFS= read -r -d '' file; do
  if ! bash -n "$file" 2>&1; then
    violations=$((violations + 1))
  fi
done < <(find "$REPO_ROOT" -name '*.sh' -print0)

if [[ $violations -gt 0 ]]; then
  echo ""
  echo "FAIL: $violations file(s) have syntax errors"
  exit 1
fi

echo "PASS: bash -n clean"
