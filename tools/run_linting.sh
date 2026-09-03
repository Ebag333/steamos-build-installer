#!/bin/bash
#
# Run all lint checks in tools/lint/.
# Auto-installs shellcheck and shfmt if missing.
#
# Usage:
#   tools/run_linting.sh [--repo-root DIR] [--fix]
#
# Options:
#   --repo-root DIR  Repository root (auto-detected if omitted)
#   --fix            Auto-fix what can be fixed (shfmt formatting, executable permissions)
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT_DIR="$SCRIPT_DIR/lint"
REPO_ROOT=""
FIX_MODE=false

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

# Auto-install missing dependencies
if ! command -v shellcheck &>/dev/null || ! command -v shfmt &>/dev/null; then
  "$SCRIPT_DIR/install_deps.sh"
fi

root_args=()
[[ -n "$REPO_ROOT" ]] && root_args+=(--repo-root "$REPO_ROOT")

shfmt_args=("${root_args[@]}")
[[ "$FIX_MODE" == true ]] && shfmt_args+=(--fix)

exec_args=("${root_args[@]}")
[[ "$FIX_MODE" == true ]] && exec_args+=(--fix)

failed=0

run_check() {
  local name="$1"
  shift
  echo "=== $name ==="
  if "$@"; then
    echo ""
  else
    echo ""
    failed=$((failed + 1))
  fi
}

run_check "shfmt" "$LINT_DIR/shfmt.sh" "${shfmt_args[@]}"
run_check "executable" "$LINT_DIR/executable.sh" "${exec_args[@]}"

if [[ "$FIX_MODE" != true ]]; then
  run_check "bash -n" "$LINT_DIR/bash-n.sh" "${root_args[@]}"
  run_check "shellcheck" "$LINT_DIR/shellcheck.sh" "${root_args[@]}"
  run_check "single-source" "$LINT_DIR/single-source.sh" "${root_args[@]}"
  run_check "no-shadow" "$LINT_DIR/no-shadow.sh" "${root_args[@]}"
  run_check "no-post-incr" "$LINT_DIR/no-post-incr.sh" "${root_args[@]}"
  run_check "strict-mode" "$LINT_DIR/strict-mode.sh" "${root_args[@]}"
  run_check "dead-code" "$LINT_DIR/dead-code.sh" "${root_args[@]}"
fi

if [[ $failed -gt 0 ]]; then
  echo "FAILED: $failed check(s) failed"
  exit 1
fi

echo "ALL PASSED"
