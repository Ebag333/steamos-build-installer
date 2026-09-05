#!/bin/bash
#
# Lint: dead-code
#
# Detects potentially unused functions and variables across all .sh files.
#
# FUNCTIONS
# ---------
# A function is flagged if it has zero references outside its definition.
# The scanner accounts for direct calls, trap handlers, pipeline phases,
# dynamic dispatch (declare -F, "$funcname"), and case routing.
# Nested/inner functions (indented definitions) are skipped — they are
# inherently scoped to their parent function.
#
# VARIABLES
# ---------
# A variable is flagged if assigned via local/declare but never referenced
# ($VAR, ${VAR..., or bare VAR in arithmetic contexts) in the same file — or,
# for variables declared with `declare -g*`, in any .sh file in the repo.
# ShellCheck SC2034 provides more thorough coverage; this check catches
# cases shellcheck may miss (e.g., variables used across sourced files).
#
# Inline suppression:  # lint-ignore: dead-code
#                      # shellcheck disable=SC2034
#
# Usage:
#   tools/lint/dead-code.sh [--repo-root DIR]
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
# Special variables with implicit usage (never flag as dead code)
# ---------------------------------------------------------------------------
IMPLICIT_VARS=(IFS)

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

declare -a func_defs=()

while IFS= read -r -d '' file; do
  rel="${file#"$REPO_ROOT"/}"
  lineno=0
  prev_line=""

  while IFS= read -r line; do
    lineno=$((lineno + 1))

    # Match: name() {
    # Only top-level (non-indented) definitions
    if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)\(\)[[:space:]]*\{ ]]; then
      func_name="${BASH_REMATCH[1]}"

      # Check for lint-ignore on same line or previous line
      if [[ "$line" =~ lint-ignore:[[:space:]]*dead-code ]] \
        || [[ "$prev_line" =~ lint-ignore:[[:space:]]*dead-code ]]; then
        prev_line="$line"
        continue
      fi

      func_defs+=("$rel:$lineno:$func_name")
    fi

    prev_line="$line"
  done <"$file"
done < <(find "$REPO_ROOT" -name '*.sh' -not -path '*/.git/*' -print0)

# ---------------------------------------------------------------------------
# Check function references
# ---------------------------------------------------------------------------

func_violations=0
declare -a func_reports=()

for def in "${func_defs[@]}"; do
  IFS=: read -r file line func_name <<<"$def"

  # Count references across all .sh files (word-boundary match)
  # Exclude the definition line itself
  ref_count=$(
    cd "$REPO_ROOT" \
      && { grep -rw -rn --include='*.sh' "$func_name" . 2>/dev/null || true; } \
      | sed 's|^\./||' \
        | grep -vc "^${file}:${line}:"
  ) || ref_count=0

  if [[ $ref_count -eq 0 ]]; then
    func_reports+=("$file:$line:$func_name")
    func_violations=$((func_violations + 1))
  fi
done

# ---------------------------------------------------------------------------
# Collect variable definitions
# ---------------------------------------------------------------------------

declare -a var_defs=()

while IFS= read -r -d '' file; do
  rel="${file#"$REPO_ROOT"/}"
  lineno=0
  prev_line=""

  while IFS= read -r line; do
    lineno=$((lineno + 1))

    # Skip comments
    [[ "$line" =~ ^[[:space:]]*# ]] && {
      prev_line="$line"
      continue
    }

    # Match: local VAR[=...] or declare [-flags] VAR[=...]
    if [[ "$line" =~ ^[[:space:]]*(local|declare)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)?([a-zA-Z_][a-zA-Z0-9_]*) ]]; then
      var_name="${BASH_REMATCH[3]}"

      # Detect global-scope declaration (declare -g, -gA, -ga, etc.)
      is_global=0
      if [[ "${BASH_REMATCH[1]}" == "declare" ]] && [[ "${BASH_REMATCH[2]:-}" =~ g ]]; then
        is_global=1
      fi

      # Skip discard variable
      [[ "$var_name" == "_" ]] && {
        prev_line="$line"
        continue
      }

      # Skip variables with implicit usage (e.g., IFS used by ${array[*]}, word splitting)
      [[ " ${IMPLICIT_VARS[*]} " =~ [[:space:]]${var_name}[[:space:]] ]] && {
        prev_line="$line"
        continue
      }

      # Check for lint-ignore or shellcheck SC2034 suppression on same line or previous line
      if [[ "$line" =~ lint-ignore:[[:space:]]*dead-code ]] \
        || [[ "$prev_line" =~ lint-ignore:[[:space:]]*dead-code ]] \
        || [[ "$line" =~ shellcheck[[:space:]]+disable=SC2034 ]] \
        || [[ "$prev_line" =~ shellcheck[[:space:]]+disable=SC2034 ]]; then
        prev_line="$line"
        continue
      fi

      var_defs+=("$rel:$lineno:$var_name:$file:$is_global")
    fi

    prev_line="$line"
  done <"$file"
done < <(find "$REPO_ROOT" -name '*.sh' -not -path '*/.git/*' -print0)

# ---------------------------------------------------------------------------
# Check variable references
# ---------------------------------------------------------------------------

var_violations=0
declare -a var_reports=()

for def in "${var_defs[@]}"; do
  IFS=: read -r file line var_name full_path is_global <<<"$def"

  # Shared variable-reference regex
  _var_ref_re='(\$'"$var_name"'([^a-zA-Z0-9_]|$)|\$\{'"$var_name"'[^a-zA-Z0-9_]|\$\{!'"$var_name"'[^a-zA-Z0-9_]|\(\(([^a-zA-Z0-9_]*|[^)]*[^a-zA-Z0-9_])'"$var_name"'([^a-zA-Z0-9_]|$))'

  if [[ "$is_global" == "1" ]]; then
    # Global variable (declare -g*): search across all .sh files,
    # mirroring the cross-file strategy used for functions above.
    ref_count=$(
      cd "$REPO_ROOT" \
        && { grep -rnE --include='*.sh' "$_var_ref_re" . 2>/dev/null || true; } \
        | sed 's|^\./||' \
          | grep -vc "^${file}:${line}:"
    ) || ref_count=0
  else
    # File-scoped variable: search only in the defining file
    ref_count=$(
      { grep -nE "$_var_ref_re" "$full_path" 2>/dev/null || true; } \
        | grep -vc "^${line}:"
    ) || ref_count=0
  fi

  if [[ $ref_count -eq 0 ]]; then
    var_reports+=("$file:$line:$var_name")
    var_violations=$((var_violations + 1))
  fi
done

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

total_violations=$((func_violations + var_violations))

if [[ $func_violations -gt 0 ]]; then
  for report in "${func_reports[@]}"; do
    IFS=: read -r file line func_name <<<"$report"
    echo "UNUSED FUNCTION"
    echo "$file:$line"
    echo "    ${func_name}()"
    echo ""
  done
fi

if [[ $var_violations -gt 0 ]]; then
  for report in "${var_reports[@]}"; do
    IFS=: read -r file line var_name <<<"$report"
    echo "UNUSED VARIABLE"
    echo "$file:$line"
    echo "    $var_name"
    echo ""
  done
fi

if [[ $total_violations -gt 0 ]]; then
  echo "FAIL: $total_violations potentially dead code item(s) found"
  echo "To suppress a false positive, add:  # lint-ignore: dead-code"
  exit 1
fi

echo "PASS: dead-code lint clean"
exit 0
