#!/bin/bash
#
# Lint: clobber-init
#
# Detects unconditional clobber assignments at top-level (outside functions)
# in library files.  When a library is sourced, bare VAR="" at the top level
# clobbers any pre-existing value the caller may have set.
# The safe pattern is:  : "${VAR:=}"
#
# Assignments inside functions are NOT flagged — those are intentional resets
# or cleanup logic, not source-time clobbering.
#
# Bad:   VAR=""          — always overwrites at source time
# Good:  : "${VAR:=}"    — only sets if currently unset
#
# Inline suppression:  # lint-ignore: clobber-init
#
# Usage:
#   tools/lint/clobber-init.sh [--repo-root DIR]
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
# Scan for unconditional VAR="" assignments at top level
# ---------------------------------------------------------------------------

violations=0

while IFS= read -r -d '' file; do
  rel="${file#"$REPO_ROOT"/}"
  lineno=0
  func_depth=0

  while IFS= read -r line; do
    lineno=$((lineno + 1))

    # Track function nesting depth by counting opening braces '{' after
    # function declarations.  We use a simple heuristic: if the line
    # matches a function definition, increment depth.  Count braces on
    # every line to track depth (ignoring braces in strings/comments).
    #
    # Function definition patterns:
    #   funcname() {
    #   function funcname {
    #   function funcname() {
    if [[ "$line" =~ ^[[:space:]]*(function[[:space:]]+)?[a-zA-Z_][a-zA-Z_0-9]*\(\)[[:space:]]*\{ ]]; then
      func_depth=$((func_depth + 1))
    elif [[ "$line" =~ ^[[:space:]]*function[[:space:]]+[a-zA-Z_][a-zA-Z_0-9]*[[:space:]]*\{ ]]; then
      func_depth=$((func_depth + 1))
    fi

    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    # Skip inline ignore
    [[ "$line" =~ lint-ignore:[[:space:]]*clobber-init ]] && continue

    # Skip if we're inside a function — only flag top-level assignments
    [[ "$func_depth" -gt 0 ]] && continue

    # Skip safe pattern:  : "${VAR:=...}"  or  : "${VAR=...}"
    # These use the colon idiom to conditionally set only if unset.
    if [[ "$line" =~ ^[[:space:]]*:[[:space:]] ]] && [[ "$line" =~ \$\{.*= ]]; then
      continue
    fi

    # Match bare unconditional assignment: VAR="" or VAR='' or VAR=
    # Patterns to match at top level:
    #   VAR=""
    #   VAR=''
    #   VAR=
    #   VAR="something"
    #   local VAR=""
    #   export VAR=""
    #
    # Must NOT match:
    #   : "${VAR:=}"  (handled above)
    #   VAR="${something}"  (assignment from another variable)
    #
    # The core issue is unconditionally clobbering at source time with a
    # literal empty string, so we match VAR="" where the value is exactly ""
    # or '' (literal empty).
    if [[ "$line" =~ ^[[:space:]]*(local[[:space:]]+|export[[:space:]]+)?([A-Z_][A-Z_0-9]*)=\"\" ]] \
       || [[ "$line" =~ ^[[:space:]]*(local[[:space:]]+|export[[:space:]]+)?([A-Z_][A-Z_0-9]*)=\'\' ]] \
       || [[ "$line" =~ ^[[:space:]]*(local[[:space:]]+|export[[:space:]]+)?([A-Z_][A-Z_0-9]*)=[[:space:]]*$ ]]; then
      echo "clobber-init: $rel:$lineno: $line"
      echo "  ^-- unconditional assignment clobbers caller's value at source time"
      echo "  fix: use \": \"\${VAR:=}\" to set only when unset"
      violations=$((violations + 1))
    fi
  done <"$file"
done < <(find "$REPO_ROOT/lib" -name '*.sh' -print0)

# ---------------------------------------------------------------------------
# Exit
# ---------------------------------------------------------------------------

if [[ $violations -gt 0 ]]; then
  echo ""
  echo "FAIL: $violations unconditional clobber assignment(s) found in lib/"
  echo "Bare VAR=\"\" always overwrites, even if the caller pre-set the variable."
  echo "Use ': \"\${VAR:=}\"' to set only when unset (safe for sourced libraries)."
  echo "To suppress a false positive, add:  # lint-ignore: clobber-init"
  exit 1
fi

echo "PASS: clobber-init lint clean"
exit 0
