#!/bin/bash
#
# Lint: strict-mode
#
# Checks that entry-point scripts (not sourced libraries) contain
# `set -euo pipefail` for proper error handling.
#
# Files with BASH_SOURCE guards are skipped (they are sourced libraries).
# Files missing strict mode are reported as violations.
#
# Inline suppression:  # lint-ignore: strict-mode
#
# Usage:
#   tools/lint/strict-mode.sh [--repo-root DIR]
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
# Skip list: files that intentionally lack strict mode
# ---------------------------------------------------------------------------

SKIP_FILES=(
  "lib/library-loader.sh"
  "steamos-recovery-update-diagnostics.sh"
)

# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------

violations=0

while IFS= read -r -d '' file; do
  rel="${file#"$REPO_ROOT"/}"

  # Skip files that intentionally lack strict mode
  skip=false
  for skip_file in "${SKIP_FILES[@]}"; do
    if [[ "$rel" == "$skip_file" ]]; then
      skip=true
      break
    fi
  done
  [[ "$skip" == true ]] && continue

  # Check for inline suppression
  has_suppress=false
  has_bash_source_guard=false
  has_strict_mode=false
  partial_variant=""

  while IFS= read -r line; do
    # Check for BASH_SOURCE guard (indicates sourced library)
    if [[ "$line" =~ \[\[[[:space:]]*\"\$\{BASH_SOURCE\[0\]\}\"[[:space:]]*==[[:space:]]*\"\$\{0\}\"[[:space:]]*\]\] ]] || \
       [[ "$line" =~ \[\[[[:space:]]*\"\$\{BASH_SOURCE\[0\]\}\"[[:space:]]*!=[[:space:]]*\"\$\{0\}\"[[:space:]]*\]\] ]]; then
      has_bash_source_guard=true
    fi

    # Check for strict mode
    if [[ "$line" =~ ^[[:space:]]*set[[:space:]]+-Eeuo[[:space:]]+pipefail ]] || \
       [[ "$line" =~ ^[[:space:]]*set[[:space:]]+-euo[[:space:]]+pipefail ]]; then
      has_strict_mode=true
    fi

    # Detect partial variants for better error messages
    if [[ "$line" =~ ^[[:space:]]*set[[:space:]]+-.*u.*pipefail ]] && \
       ! [[ "$line" =~ ^[[:space:]]*set[[:space:]]+-Eeuo[[:space:]]+pipefail ]] && \
       ! [[ "$line" =~ ^[[:space:]]*set[[:space:]]+-euo[[:space:]]+pipefail ]]; then
      # Extract the set command for the detail message
      partial_variant="$(echo "$line" | sed 's/^[[:space:]]*//')"
    fi

    # Check for inline suppression
    if [[ "$line" =~ lint-ignore:[[:space:]]*strict-mode ]]; then
      has_suppress=true
    fi
  done <"$file"

  # Skip inline suppression
  [[ "$has_suppress" == true ]] && continue

  # Skip sourced libraries (files with BASH_SOURCE guard)
  [[ "$has_bash_source_guard" == true ]] && continue

  # Files without a BASH_SOURCE guard are assumed to be entry points.
  # Report violation if they lack strict mode.
  if [[ "$has_strict_mode" == false ]]; then
    if [[ -n "$partial_variant" ]]; then
      echo "strict-mode: $rel: missing 'set -euo pipefail' (has '$partial_variant' — missing -e)"
    else
      echo "strict-mode: $rel: missing 'set -euo pipefail'"
    fi
    violations=$((violations + 1))
  fi
done < <(find "$REPO_ROOT" -name '*.sh' -print0)

# ---------------------------------------------------------------------------
# Exit
# ---------------------------------------------------------------------------

if [[ $violations -gt 0 ]]; then
  echo ""
  echo "FAIL: $violations entry-point(s) missing 'set -euo pipefail'"
  echo "Entry-point scripts should use strict mode for proper error handling."
  echo "Add 'set -euo pipefail' near the top of the script."
  echo "To suppress a false positive, add:  # lint-ignore: strict-mode"
  exit 1
fi

echo "PASS: strict-mode lint clean"
exit 0
