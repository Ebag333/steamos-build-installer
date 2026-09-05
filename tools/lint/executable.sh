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
#   tools/lint/executable.sh [--repo-root DIR] [--fix] [--owner USER:GROUP]
#
# Options:
#   --fix    Auto-fix by running chmod +x on non-executable files
#   --owner  Target owner for root-owned files (default: deck:deck)
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
DEFAULT_OWNER="deck:deck"

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
    --owner)
      DEFAULT_OWNER="${2:?--owner requires a value}"
      shift 2
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
# Check if a file has lint-ignore suppression
# ---------------------------------------------------------------------------

has_suppress() {
  local file="$1"
  while IFS= read -r line; do
    if [[ "$line" =~ lint-ignore:[[:space:]]*executable ]]; then
      return 0
    fi
  done <"$file"
  return 1
}

# ---------------------------------------------------------------------------
# Fix ownership: chown root-owned .sh files to DEFAULT_OWNER
# ---------------------------------------------------------------------------

fix_ownership() {
  local root_owned=()
  while IFS= read -r -d '' file; do
    local uid
    uid=$(stat -c '%u' "$file" 2>/dev/null || true)
    if [[ "$uid" == "0" ]]; then
      root_owned+=("$file")
    fi
  done < <(find "$REPO_ROOT" -name '*.sh' -print0)

  if [[ ${#root_owned[@]} -eq 0 ]]; then
    return 0
  fi

  echo ""
  echo "Fixing ownership: ${#root_owned[@]} file(s) owned by root"
  echo ""

  local fixed=0
  local failed=0
  for file in "${root_owned[@]}"; do
    local rel="${file#"$REPO_ROOT"/}"
    if chown -h "$DEFAULT_OWNER" "$file" 2>/dev/null; then
      echo "ownership: $rel: fixed (chown $DEFAULT_OWNER)"
      fixed=$((fixed + 1))
    else
      echo "ownership: $rel: cannot fix (permission denied - try with sudo)"
      failed=$((failed + 1))
    fi
  done

  echo ""
  if [[ $fixed -gt 0 ]]; then
    echo "OWNERSHIP FIXED: $fixed file(s) chowned to $DEFAULT_OWNER"
  fi
  if [[ $failed -gt 0 ]]; then
    echo "OWNERSHIP FAILED: $failed file(s) could not be fixed (need sudo)"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Fix executable: chmod +x on non-executable .sh files
# ---------------------------------------------------------------------------

fix_executable() {
  local fixed=0
  local failed=0

  while IFS= read -r -d '' file; do
    local rel="${file#"$REPO_ROOT"/}"

    # Check if the file has the executable bit
    if [[ ! -x "$file" ]]; then
      # Check for inline suppression
      if has_suppress "$file"; then
        continue
      fi

      if chmod +x "$file" 2>/dev/null; then
        echo "executable: $rel: fixed (chmod +x)"
        fixed=$((fixed + 1))
      else
        echo "executable: $rel: cannot fix (permission denied)"
        failed=$((failed + 1))
      fi
    fi
  done < <(find "$REPO_ROOT" -name '*.sh' -print0)

  echo ""
  if [[ $fixed -gt 0 ]]; then
    echo "EXECUTABLE FIXED: $fixed file(s) made executable"
  fi
  if [[ $failed -gt 0 ]]; then
    echo "EXECUTABLE FAILED: $failed file(s) could not be fixed"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Scan: check for violations without fixing
# ---------------------------------------------------------------------------

scan() {
  local violations=0

  # Check ownership (non-fix mode: exit 1 if root-owned)
  if [[ "$FIX_MODE" != true ]]; then
    local root_owned
    root_owned=$(find "$REPO_ROOT" -name '*.sh' -print0 | xargs -0 stat -c '%u %n' 2>/dev/null | awk '$1 == 0 { $1=""; print }' || true)

    if [[ -n "$root_owned" ]]; then
      echo ""
      echo "WARNING: .sh file(s) owned by root (uid 0):"
      echo "$root_owned"
      echo ""
      echo "To fix, run:"
      echo "  sudo find $REPO_ROOT -xdev -uid 0 -exec chown -h $DEFAULT_OWNER -- {} +"
      return 1
    fi
  fi

  # Check executable bit on all .sh files
  while IFS= read -r -d '' file; do
    local rel="${file#"$REPO_ROOT"/}"

    # Check if the file has the executable bit
    if [[ ! -x "$file" ]]; then
      # Check for inline suppression
      if has_suppress "$file"; then
        continue
      fi

      echo "executable: $rel: not executable"
      violations=$((violations + 1))
    fi
  done < <(find "$REPO_ROOT" -name '*.sh' -print0)

  if [[ $violations -gt 0 ]]; then
    echo ""
    echo "FAIL: $violations file(s) not executable"
    echo "Shell scripts should have the executable bit set."
    echo "To suppress a false positive, add:  # lint-ignore: executable"
    return 1
  fi

  echo "PASS: executable lint clean"
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [[ "$FIX_MODE" == true ]]; then
  fix_ownership || true
  fix_executable || true
  scan
else
  scan
fi
