#!/bin/bash
#
# Lint: undefined-funcs
#
# Detects _prefix mismatches between function calls and definitions.
# When "foo" is called but "_foo" is defined (or vice versa), suggests
# the correction ("did you mean _foo?").
#
# Inline suppression:  # lint-ignore: undefined-funcs
#
# Usage:
#   tools/lint/undefined-funcs.sh [--repo-root DIR]
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
# Phase 1: Collect function definitions
# ---------------------------------------------------------------------------

declare -A defined_funcs=()

while IFS= read -r -d '' file; do
  lineno=0
  in_heredoc=0
  heredoc_delim=""

  while IFS= read -r line; do
    lineno=$((lineno + 1))

    # Track heredoc state
    if [[ $in_heredoc -eq 1 ]]; then
      if [[ "$line" == "$heredoc_delim" ]]; then
        in_heredoc=0
        heredoc_delim=""
      fi
      continue
    fi

    # Detect heredoc start: <<WORD or <<-WORD
    if [[ "$line" =~ \<\<-?[[:space:]]*\'?([a-zA-Z_][a-zA-Z0-9_]*)\'? ]]; then
      heredoc_delim="${BASH_REMATCH[1]}"
      in_heredoc=1
    fi

    # Match function definitions:
    #   name() {
    #   function name {
    #   function name() {
    if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)\(\)[[:space:]]*\{ ]] \
      || [[ "$line" =~ ^[[:space:]]*function[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\{ ]] \
      || [[ "$line" =~ ^[[:space:]]*function[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)\(\)[[:space:]]*\{ ]]; then
      func_name="${BASH_REMATCH[1]}"
      defined_funcs["$func_name"]="$file:$lineno"
    fi
  done <"$file"
done < <(find "$REPO_ROOT" -name '*.sh' -not -path '*/.git/*' -print0)

# ---------------------------------------------------------------------------
# Phase 2: Find _prefix mismatches
# ---------------------------------------------------------------------------

violations=0

while IFS= read -r -d '' file; do
  rel="${file#"$REPO_ROOT"/}"
  lineno=0
  in_heredoc=0
  heredoc_delim=""

  while IFS= read -r line; do
    lineno=$((lineno + 1))

    # Track heredoc state
    if [[ $in_heredoc -eq 1 ]]; then
      if [[ "$line" == "$heredoc_delim" ]]; then
        in_heredoc=0
        heredoc_delim=""
      fi
      continue
    fi

    # Detect heredoc start
    if [[ "$line" =~ \<\<-?[[:space:]]*\'?([a-zA-Z_][a-zA-Z0-9_]*)\'? ]]; then
      heredoc_delim="${BASH_REMATCH[1]}"
      in_heredoc=1
    fi

    # Skip comments
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    # Skip blank lines
    [[ -z "${line// /}" ]] && continue

    # Skip lint-ignore lines
    [[ "$line" =~ lint-ignore:[[:space:]]*undefined-funcs ]] && continue

    # Skip function definition lines
    [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)\(\)[[:space:]]*\{ ]] && continue
    [[ "$line" =~ ^[[:space:]]*function[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*) ]] && continue

    # Extract first word at command position (pure bash, no subshells)
    first_word=""
    if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*) ]]; then
      first_word="${BASH_REMATCH[1]}"
    fi

    # Skip if empty
    [[ -z "$first_word" ]] && continue

    # Skip bash keywords and builtins (case statement, ~60 entries)
    # shellcheck disable=SC1010
    case "$first_word" in
      if | for | while | case | select | until | do | done | then | else | elif | fi | esac | in | time | coproc | function) continue ;;
      return | exit | local | declare | export | readonly | unset | set | shift | eval | exec) continue ;;
      trap | echo | printf | read | cd | pwd | pushd | popd | test | true | false | source) continue ;;
      break | continue | let | getopts | builtin | command | type | hash | mapfile) continue ;;
      readarray | compgen | complete | jobs | bg | fg | disown) continue ;;
    esac

    # Skip if it's already a defined function
    [[ ${defined_funcs[$first_word]+_} ]] && continue

    # Only check for _prefix mismatches
    if [[ "${first_word##_}" != "$first_word" ]]; then
      # Word starts with _ — check if version without _ is defined
      bare="${first_word#_}"
      if [[ -n "$bare" ]] && [[ ${defined_funcs[$bare]+_} ]]; then
        echo "undefined-funcs: $rel:$lineno: '$first_word' is not defined (did you mean '$bare'?)"
        violations=$((violations + 1))
      fi
    else
      # Word does NOT start with _ — check if version with _ is defined
      if [[ ${defined_funcs[_$first_word]+_} ]]; then
        echo "undefined-funcs: $rel:$lineno: '$first_word' is not defined (did you mean '_$first_word'?)"
        violations=$((violations + 1))
      fi
    fi
  done <"$file"
done < <(find "$REPO_ROOT" -name '*.sh' -not -path '*/.git/*' -print0)

# ---------------------------------------------------------------------------
# Exit
# ---------------------------------------------------------------------------

if [[ $violations -gt 0 ]]; then
  echo ""
  echo "FAIL: $violations undefined function call(s) found"
  echo "To suppress a false positive, add:  # lint-ignore: undefined-funcs"
  exit 1
fi

echo "PASS: undefined-funcs lint clean"
exit 0
