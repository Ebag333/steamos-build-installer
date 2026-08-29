#!/bin/bash
#
# Lint: shellcheck
#
# Runs ShellCheck on all .sh files in the repository.
#
# Usage:
#   tools/lint/shellcheck.sh [--repo-root DIR]
#
# Requirements:
#   shellcheck must be installed (apt install shellcheck, pacman -S shellcheck, etc.)
#
# Exit codes:
#   0 — no violations
#   1 — violations found
#   2 — usage error / shellcheck not found

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

if ! command -v shellcheck &>/dev/null; then
  echo "ERROR: shellcheck not found. Install it:" >&2
  echo "  apt install shellcheck    # Debian/Ubuntu" >&2
  echo "  pacman -S shellcheck      # Arch" >&2
  echo "  brew install shellcheck   # macOS" >&2
  exit 2
fi

echo "Running shellcheck..."
find "$REPO_ROOT" -name '*.sh' -print0 | xargs -0 shellcheck
echo "PASS: shellcheck clean"
