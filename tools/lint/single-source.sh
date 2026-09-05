#!/bin/bash
#
# Lint: single-source
#
# Enforces that library sourcing is centralized in lib/library-loader.sh.
# Files in lib/ (except library-loader.sh itself) must not use `source`
# to load other .sh libraries — they receive everything via the loader.
#
# Also enforces the BASH_SOURCE guard pattern for library files in lib/.
# Library files must contain a guard that prevents accidental direct execution:
#   if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then ... fi
# This ensures libraries can only be used when sourced, not run as standalone
# scripts.
#
# Exceptions (allowlisted):
#   - lib/library-loader.sh  — the centralized loader itself
#   - Entry points           — steamos-build.sh, lib/backend.sh, lib/repatch.sh, etc.
#   - Build subsystem        — lib/build/** (has its own internal architecture)
#   - Configs                — lib/configs/** (standalone build recipe scripts)
#   - Optimizations          — lib/optimizations/entry.sh (dynamic module loading)
#   - Config sourcing        — sourcing .conf files is always allowed
#   - Inline ignore          — lines with "lint-ignore: single-source" are skipped
#
# Usage:
#   tools/lint/single-source.sh [--repo-root DIR]
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
# Allowlists
# ---------------------------------------------------------------------------

# Files that may source library-loader.sh (entry points / bootstrappers)
ALLOWED_ENTRYPOINTS=(
  "steamos-build.sh"
  "lib/backend.sh"
  "lib/repatch.sh"
  "lib/customization.sh"
  "lib/atomupd-wrapper.sh"
  "lib/update-wrapper.sh"
  "lib/check-deps.sh"
  "lib/scan-hardware.sh"
  "lib/diagnostics/scan-hardware.sh"
  "test-aotofu-e2e.sh"
)

# Directories whose internal sourcing is self-contained
ALLOWED_SUBSYSTEMS=(
  "lib/build"
  "lib/configs"
  "lib/optimizations"
  "lib/pipelines"
)

# The centralized loader itself
LOADER="lib/library-loader.sh"

# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------

violations=0

while IFS= read -r -d '' file; do
  # Path relative to repo root
  rel="${file#"$REPO_ROOT"/}"

  # Skip the loader itself
  [[ "$rel" == "$LOADER" ]] && continue

  # Skip allowlisted entry points
  is_entrypoint=0
  for ep in "${ALLOWED_ENTRYPOINTS[@]}"; do
    [[ "$rel" == "$ep" ]] && is_entrypoint=1 && break
  done
  [[ $is_entrypoint -eq 1 ]] && continue

  # Skip allowlisted subsystems
  is_subsystem=0
  for sub in "${ALLOWED_SUBSYSTEMS[@]}"; do
    [[ "$rel" == "$sub"/* ]] && is_subsystem=1 && break
  done
  [[ $is_subsystem -eq 1 ]] && continue

  # Check each line for source statements
  lineno=0
  while IFS= read -r line; do
    lineno=$((lineno + 1))

    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    # Skip inline ignore
    [[ "$line" =~ lint-ignore:[[:space:]]*single-source ]] && continue

    # Match `source` keyword
    if [[ "$line" =~ ^[[:space:]]*source[[:space:]] ]]; then
      # Allow sourcing .conf files (runtime config, not library loading)
      if [[ "$line" =~ \.conf ]]; then
        continue
      fi
      # Allow sourcing variables that look like config paths (e.g. $VALIDATE_CONFIG)
      if [[ "$line" =~ \$[A-Z_]*CONF[A-Z_]* ]] || [[ "$line" =~ \$[A-Z_]*CONFIG[A-Z_]* ]]; then
        continue
      fi
      echo "$rel:$lineno: $line"
      violations=$((violations + 1))
    fi
  done <"$file"
done < <(find "$REPO_ROOT" -name '*.sh' -print0)

# ---------------------------------------------------------------------------
# BASH_SOURCE Guard Check
# ---------------------------------------------------------------------------

# Check that library files in lib/ have the BASH_SOURCE guard pattern.
# This prevents accidental direct execution of sourced libraries.
guard_pattern='if [[ "${BASH_SOURCE[0]}" == "${0}"'

while IFS= read -r -d '' file; do
  rel="${file#"$REPO_ROOT"/}"

  # Only check lib/ directory
  [[ "$rel" == lib/* ]] || continue

  # Skip the loader itself
  [[ "$rel" == "$LOADER" ]] && continue

  # Skip allowlisted entry points
  is_entrypoint=0
  for ep in "${ALLOWED_ENTRYPOINTS[@]}"; do
    [[ "$rel" == "$ep" ]] && is_entrypoint=1 && break
  done
  [[ $is_entrypoint -eq 1 ]] && continue

  # Skip allowlisted subsystems
  is_subsystem=0
  for sub in "${ALLOWED_SUBSYSTEMS[@]}"; do
    [[ "$rel" == "$sub"/* ]] && is_subsystem=1 && break
  done
  [[ $is_subsystem -eq 1 ]] && continue

  # Skip files with inline ignore
  if head -n 20 "$file" | grep -q 'lint-ignore:[[:space:]]*single-source'; then
    continue
  fi

  # Check for guard pattern
  if ! grep -qF "$guard_pattern" "$file"; then
    echo "$rel:1: missing BASH_SOURCE guard — add 'if [[ \"\${BASH_SOURCE[0]}\" == \"\${0}\" ]]; then ... fi' to prevent direct execution"
    violations=$((violations + 1))
  fi
done < <(find "$REPO_ROOT/lib" -name '*.sh' -print0)

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

if [[ $violations -gt 0 ]]; then
  echo ""
  echo "FAIL: $violations violation(s) found"
  echo "- Source statements must be centralized in lib/library-loader.sh"
  echo "- Library files in lib/ must have the BASH_SOURCE guard pattern"
  echo "To suppress a false positive, add:  # lint-ignore: single-source"
  exit 1
fi

echo "PASS: single-source lint clean"
exit 0
