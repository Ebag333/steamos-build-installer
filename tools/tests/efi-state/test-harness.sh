#!/bin/bash
#
# test-harness.sh — Core test infrastructure for EFI state tests
#
# Provides test lifecycle management, assertion helpers, cleanup
# registry, and subshell isolation for the EFI state test suite.
#
# Usage:
#   Source this file in test scripts:
#     source "$(dirname "$0")/../../test-harness.sh"
#
#   Then call the public API:
#     test_harness_init
#     trap test_harness_cleanup EXIT
#     test_harness_begin_test "description"
#     test_harness_assert_eq "$actual" "$expected"
#     test_harness_pass
#     test_harness_summary
#
# Public API:
#   test_harness_init                 — Initialize counters and cleanup registry
#   test_harness_cleanup              — Run all registered cleanup handlers
#   test_harness_register_cleanup     — Register a cleanup handler function
#   test_harness_begin_test           — Begin a new test case
#   test_harness_pass                 — Mark current test as passed
#   test_harness_fail                 — Mark current test as failed
#   _test_harness_skip                 — Mark current test as skipped
#   test_harness_assert_eq            — Assert two values are equal
#   test_harness_assert_file_exists   — Assert file exists
#   _test_harness_assert_file_not_exists — Assert file does not exist
#   test_harness_assert_dir_exists    — Assert directory exists
#   test_harness_assert_contains      — Assert string contains substring
#   test_harness_assert_not_contains  — Assert string does not contain substring
#   _test_harness_run_in_subshell      — Run a function in an isolated subshell
#   test_harness_summary              — Print test results summary
#   test_harness_exit_code            — Return 0 if all passed, 1 otherwise

# ---------------------------------------------------------------------------
# Guard: only run when executed directly, not when sourced
# ---------------------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "test-harness.sh is a library — source it, don't execute it directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# State (initialized by test_harness_init)
# ---------------------------------------------------------------------------

_TEST_HARNESS_PASS_COUNT=0
_TEST_HARNESS_FAIL_COUNT=0
_TEST_HARNESS_SKIP_COUNT=0
_TEST_HARNESS_TOTAL_COUNT=0
_TEST_HARNESS_CURRENT_TEST=""
_TEST_HARNESS_CURRENT_TEST_FAILED=0
_TEST_HARNESS_INITIALIZED=0
_TEST_HARNESS_CLEANUP_HANDLERS=()

# ---------------------------------------------------------------------------
# test_harness_init
#
# Initialize counters, cleanup registry, and mark harness as ready.
# Must be called before any other harness function.
# ---------------------------------------------------------------------------

test_harness_init() {
  _TEST_HARNESS_PASS_COUNT=0
  _TEST_HARNESS_FAIL_COUNT=0
  _TEST_HARNESS_SKIP_COUNT=0
  _TEST_HARNESS_TOTAL_COUNT=0
  _TEST_HARNESS_CURRENT_TEST=""
  _TEST_HARNESS_CURRENT_TEST_FAILED=0
  _TEST_HARNESS_INITIALIZED=1
  _TEST_HARNESS_CLEANUP_HANDLERS=()
}

# ---------------------------------------------------------------------------
# test_harness_cleanup
#
# Run all registered cleanup handlers in registration order.
# Safe to call multiple times (idempotent after first invocation).
# Designed to be used as a trap handler.
# ---------------------------------------------------------------------------

test_harness_cleanup() {
  local i handler
  for ((i = 0; i < ${#_TEST_HARNESS_CLEANUP_HANDLERS[@]}; i++)); do
    handler="${_TEST_HARNESS_CLEANUP_HANDLERS[$i]}"
    if declare -f "$handler" >/dev/null 2>&1; then
      "$handler" 2>/dev/null || true
    fi
  done
}

# ---------------------------------------------------------------------------
# test_harness_register_cleanup <function_name>
#
# Register a function to be called during test_harness_cleanup().
# The function must accept no arguments.
# ---------------------------------------------------------------------------

test_harness_register_cleanup() {
  local handler="${1:?test_harness_register_cleanup requires a function name}"
  if ! declare -f "$handler" >/dev/null 2>&1; then
    echo "WARNING: test_harness_register_cleanup: '$handler' is not a function" >&2
    return 1
  fi
  _TEST_HARNESS_CLEANUP_HANDLERS+=("$handler")
}

# ---------------------------------------------------------------------------
# test_harness_begin_test <description>
#
# Begin a new test case. Marks any previously pending test as failed
# (implicit fail if the test never called pass/fail/skip).
# ---------------------------------------------------------------------------

test_harness_begin_test() {
  local desc="${1:?test_harness_begin_test requires a description}"

  # Implicitly fail the previous test if it was never completed.
  if [[ -n "$_TEST_HARNESS_CURRENT_TEST" ]] \
    && [[ "$_TEST_HARNESS_CURRENT_TEST_FAILED" -eq 0 ]]; then
    _TEST_HARNESS_FAIL_COUNT=$((_TEST_HARNESS_FAIL_COUNT + 1))
    echo "  FAIL: '${_TEST_HARNESS_CURRENT_TEST}' (no result recorded)" >&2
  fi

  _TEST_HARNESS_CURRENT_TEST="$desc"
  _TEST_HARNESS_CURRENT_TEST_FAILED=0
  _TEST_HARNESS_TOTAL_COUNT=$((_TEST_HARNESS_TOTAL_COUNT + 1))
  echo "  BEGIN: $desc"
}

# ---------------------------------------------------------------------------
# test_harness_pass
#
# Mark the current test as passed.
# ---------------------------------------------------------------------------

test_harness_pass() {
  if [[ -z "$_TEST_HARNESS_CURRENT_TEST" ]]; then
    echo "WARNING: test_harness_pass called without a test in progress" >&2
    return 1
  fi

  _TEST_HARNESS_PASS_COUNT=$((_TEST_HARNESS_PASS_COUNT + 1))
  echo "  PASS: ${_TEST_HARNESS_CURRENT_TEST}"
  _TEST_HARNESS_CURRENT_TEST=""
  _TEST_HARNESS_CURRENT_TEST_FAILED=0
}

# ---------------------------------------------------------------------------
# test_harness_fail [message]
#
# Mark the current test as failed, with an optional message.
# ---------------------------------------------------------------------------

test_harness_fail() {
  local msg="${1:-}"

  if [[ -z "$_TEST_HARNESS_CURRENT_TEST" ]]; then
    echo "WARNING: test_harness_fail called without a test in progress" >&2
    return 1
  fi

  _TEST_HARNESS_FAIL_COUNT=$((_TEST_HARNESS_FAIL_COUNT + 1))
  _TEST_HARNESS_CURRENT_TEST_FAILED=1
  if [[ -n "$msg" ]]; then
    echo "  FAIL: ${_TEST_HARNESS_CURRENT_TEST} — $msg" >&2
  else
    echo "  FAIL: ${_TEST_HARNESS_CURRENT_TEST}" >&2
  fi
  _TEST_HARNESS_CURRENT_TEST=""
}

# ---------------------------------------------------------------------------
# _test_harness_skip [reason]
#
# Mark the current test as skipped, with an optional reason.
# ---------------------------------------------------------------------------

_test_harness_skip() {
  local reason="${1:-skipped}"

  if [[ -z "$_TEST_HARNESS_CURRENT_TEST" ]]; then
    echo "WARNING: _test_harness_skip called without a test in progress" >&2
    return 1
  fi

  _TEST_HARNESS_SKIP_COUNT=$((_TEST_HARNESS_SKIP_COUNT + 1))
  echo "  SKIP: ${_TEST_HARNESS_CURRENT_TEST} ($reason)"
  _TEST_HARNESS_CURRENT_TEST=""
  _TEST_HARNESS_CURRENT_TEST_FAILED=0
}

# ---------------------------------------------------------------------------
# test_harness_assert_eq <actual> <expected>
#
# Assert that two values are equal. On failure, marks the current test
# as failed and prints a diagnostic.
# ---------------------------------------------------------------------------

test_harness_assert_eq() {
  local actual="${1:?test_harness_assert_eq requires actual value}"
  local expected="${2:?test_harness_assert_eq requires expected value}"

  if [[ "$actual" == "$expected" ]]; then
    return 0
  fi

  echo "    ASSERTION FAILED: expected '$expected', got '$actual'" >&2
  test_harness_fail "assert_eq: expected '$expected', got '$actual'"
}

# ---------------------------------------------------------------------------
# test_harness_assert_file_exists <path>
#
# Assert that a file exists at the given path.
# ---------------------------------------------------------------------------

test_harness_assert_file_exists() {
  local path="${1:?test_harness_assert_file_exists requires a path}"

  if [[ -f "$path" ]]; then
    return 0
  fi

  echo "    ASSERTION FAILED: file does not exist: '$path'" >&2
  test_harness_fail "expected file to exist: '$path'"
}

# ---------------------------------------------------------------------------
# _test_harness_assert_file_not_exists <path>
#
# Assert that a file does NOT exist at the given path.
# ---------------------------------------------------------------------------

_test_harness_assert_file_not_exists() {
  local path="${1:?_test_harness_assert_file_not_exists requires a path}"

  if [[ ! -f "$path" ]]; then
    return 0
  fi

  echo "    ASSERTION FAILED: file exists but should not: '$path'" >&2
  test_harness_fail "expected file not to exist: '$path'"
}

# ---------------------------------------------------------------------------
# test_harness_assert_dir_exists <path>
#
# Assert that a directory exists at the given path.
# ---------------------------------------------------------------------------

test_harness_assert_dir_exists() {
  local path="${1:?test_harness_assert_dir_exists requires a path}"

  if [[ -d "$path" ]]; then
    return 0
  fi

  echo "    ASSERTION FAILED: directory does not exist: '$path'" >&2
  test_harness_fail "expected directory to exist: '$path'"
}

# ---------------------------------------------------------------------------
# test_harness_assert_contains <haystack> <needle>
#
# Assert that the haystack string contains the needle substring.
# ---------------------------------------------------------------------------

test_harness_assert_contains() {
  local haystack="${1:?test_harness_assert_contains requires haystack}"
  local needle="${2:?test_harness_assert_contains requires needle}"

  if [[ "$haystack" == *"$needle"* ]]; then
    return 0
  fi

  echo "    ASSERTION FAILED: string does not contain '$needle'" >&2
  echo "      haystack: '$haystack'" >&2
  test_harness_fail "expected string to contain '$needle'"
}

# ---------------------------------------------------------------------------
# test_harness_assert_not_contains <haystack> <needle>
#
# Assert that the haystack string does NOT contain the needle substring.
# ---------------------------------------------------------------------------

test_harness_assert_not_contains() {
  local haystack="${1:?test_harness_assert_not_contains requires haystack}"
  local needle="${2:?test_harness_assert_not_contains requires needle}"

  if [[ "$haystack" != *"$needle"* ]]; then
    return 0
  fi

  echo "    ASSERTION FAILED: string contains '$needle' but should not" >&2
  echo "      haystack: '$haystack'" >&2
  test_harness_fail "expected string not to contain '$needle'"
}

# ---------------------------------------------------------------------------
# _test_harness_run_in_subshell <function_name> [args...]
#
# Run a function in an isolated subshell. The function and all its
# effects (file creation, variable changes, etc.) are confined to
# the subshell and will not affect the parent process.
#
# The subshell's exit code is returned. If the function does not
# exist, returns 1.
# ---------------------------------------------------------------------------

_test_harness_run_in_subshell() {
  local func="${1:?_test_harness_run_in_subshell requires a function name}"
  shift

  if ! declare -f "$func" >/dev/null 2>&1; then
    echo "ERROR: _test_harness_run_in_subshell: '$func' is not a function" >&2
    return 1
  fi

  # shellcheck disable=SC2016
  ("$func" "$@")
}

# ---------------------------------------------------------------------------
# test_harness_summary
#
# Print a summary of all test results.
# Returns 0 if all tests passed, 1 otherwise.
# ---------------------------------------------------------------------------

test_harness_summary() {
  # Implicitly fail any pending test.
  if [[ -n "$_TEST_HARNESS_CURRENT_TEST" ]]; then
    _TEST_HARNESS_FAIL_COUNT=$((_TEST_HARNESS_FAIL_COUNT + 1))
    echo "  FAIL: '${_TEST_HARNESS_CURRENT_TEST}' (no result recorded)" >&2
    _TEST_HARNESS_CURRENT_TEST=""
  fi

  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "  Test Results"
  echo "═══════════════════════════════════════════════════════════"
  echo "  Total:   $_TEST_HARNESS_TOTAL_COUNT"
  echo "  Passed:  $_TEST_HARNESS_PASS_COUNT"
  echo "  Failed:  $_TEST_HARNESS_FAIL_COUNT"
  echo "  Skipped: $_TEST_HARNESS_SKIP_COUNT"
  echo "═══════════════════════════════════════════════════════════"

  if [[ "$_TEST_HARNESS_FAIL_COUNT" -eq 0 ]]; then
    echo "  ALL PASSED"
  else
    echo "  SOME TESTS FAILED"
  fi
  echo "═══════════════════════════════════════════════════════════"
  echo ""
}

# ---------------------------------------------------------------------------
# test_harness_exit_code
#
# Return an appropriate exit code: 0 if all tests passed (zero failures),
# 1 otherwise. Intended to be the final command in a test script.
# ---------------------------------------------------------------------------

test_harness_exit_code() {
  if [[ "$_TEST_HARNESS_FAIL_COUNT" -gt 0 ]]; then
    return 1
  fi
  return 0
}
