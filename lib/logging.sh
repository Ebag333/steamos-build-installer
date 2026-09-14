#!/bin/bash
#
# steamos-nvidia-installer — lib/logging.sh
# Centralized structured logging library.
#
# Emits JSON Lines to a log file and human-readable lines to stderr.
# Safe for concurrent access, subshells, and early returns.
#
# Usage:
#   source lib/logging.sh
#   log_init --log-file /tmp/build.jsonl --console-level info --console-category "build,install"
#   log_info build start "Starting build" arch x86_64
#   log_notice build milestone "Build halfway done" progress 50
#   log_close
#
# Do NOT run directly — source from your script.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/logging.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Module-level state
# ---------------------------------------------------------------------------

# File descriptor for the JSON Lines log file. Empty when no file is open.
: "${_LOG_FD:=}"

# Path to the current log file (for reference / error messages).
: "${_LOG_FILE_PATH:=}"

# Minimum level for file output (0=debug 1=info 3=notice 4=warn 5=error).
# -1 disables file output entirely.
_LOG_FILE_LEVEL=1

# Minimum level for console output (0=debug 1=info 3=notice 4=warn 5=error).
# -1 disables console output entirely.
_LOG_CONSOLE_LEVEL=3

# Comma-separated category whitelist for console output.
# Empty string means "all categories pass".
: "${_LOG_CONSOLE_CATEGORIES:=}"

# Associative array mapping level names to numeric values.
declare -gA _LOG_LEVEL_NUM=(
  [debug]=0
  [info]=1
  [notice]=3
  [warn]=4
  [error]=5
)

# ANSI color codes (empty when color is disabled).
: "${_LOG_C_DEBUG:=}"
: "${_LOG_C_INFO:=}"
: "${_LOG_C_NOTICE:=}"
: "${_LOG_C_WARN:=}"
: "${_LOG_C_ERROR:=}"
: "${_LOG_RESET:=}"

# Whether console color is enabled (1=yes, 0=no).
_LOG_COLOR=1

# Redaction key patterns (lowercase). Values whose key name (the even-position
# argument to _log_emit) matches any of these are replaced with <REDACTED>.
declare -ga _LOG_REDACT_KEYS=(
  password
  passwd
  token
  secret
  api_key
  apikey
  access_key
  access_secret
  private_key
  credential
  credentials
  auth
  authorization
)

# Patterns to search-and-replace inside *values* (extended regex).
declare -ga _LOG_REDACT_PATTERNS=(
  'password=[^ ]*'
  'Authorization: Bearer [^ ]*'
  'https?://[^@/]+:[^@/]+@'
)

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _log_json_escape STRING
#   Emit STRING with JSON-safe escaping to stdout.
#   Handles: backslash, double-quote, newline, tab, carriage return,
#   form feed, backspace, and generic control chars (\u00XX).
_log_json_escape() {
  local s="$1"
  local out=""
  local i c code

  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    # shellcheck disable=SC1003  # \\ inside single quotes is not an escape
    case "$c" in
      '\\') out+='\\' ;;
      '"') out+='\"' ;;
      $'\n') out+='\n' ;;
      $'\t') out+='\t' ;;
      $'\r') out+='\r' ;;
      $'\f') out+='\f' ;;
      $'\b') out+='\b' ;;
      *)
        # Check for control characters (U+0000..U+001F)
        printf -v code '%d' "'$c" 2>/dev/null || code=0
        if ((code >= 0 && code < 32)); then
          out+="$(printf '\\u%04x' "$code")"
        else
          out+="$c"
        fi
        ;;
    esac
  done

  printf '%s' "$out"
}

# _log_redact KEY VALUE
#   Apply redaction rules to VALUE based on KEY name and content patterns.
#   Prints the (possibly redacted) value to stdout.
_log_redact() {
  local key="$1"
  local val="$2"
  local lower_key pattern

  # Redact by key name (case-insensitive match).
  lower_key="${key,,}"
  local rk
  for rk in "${_LOG_REDACT_KEYS[@]}"; do
    if [[ "$lower_key" == "$rk" || "$lower_key" == *"_${rk}" || "$lower_key" == "${rk}_"* ]]; then
      printf '%s' '<REDACTED>'
      return
    fi
  done

  # Redact by content patterns (extended regex via Bash =~).
  for pattern in "${_LOG_REDACT_PATTERNS[@]}"; do
    if [[ "$val" =~ $pattern ]]; then
      printf '%s' '<REDACTED>'
      return
    fi
  done

  printf '%s' "$val"
}

# _log_level_num LEVEL_NAME
#   Print the numeric value for a level name.  Defaults to 1 (info) if unknown.
_log_level_num() {
  local name="$1"
  if [[ ${_LOG_LEVEL_NUM[$name]+_} ]]; then
    printf '%d' "${_LOG_LEVEL_NUM[$name]}"
  else
    printf '%d' 1
  fi
}

# _log_should_console CATEGORY LEVEL_NUM
#   Return 0 if the message should be printed to the console, 1 otherwise.
_log_should_console() {
  local category="$1"
  local level_num="$2"

  # Console disabled.
  ((_LOG_CONSOLE_LEVEL < 0)) && return 1

  # Level filter.
  ((level_num < _LOG_CONSOLE_LEVEL)) && return 1

  # Category whitelist filter (empty = all pass).
  if [[ -n "$_LOG_CONSOLE_CATEGORIES" ]]; then
    local IFS=','
    # shellcheck disable=SC2206  # IFS=',' is set on line above — intentional comma-splitting
    local -a allowed=($_LOG_CONSOLE_CATEGORIES)
    local cat
    local found=0
    for cat in "${allowed[@]}"; do
      if [[ "$cat" == "$category" ]]; then
        found=1
        break
      fi
    done
    ((found)) || return 1
  fi

  return 0
}

# _log_render_console LEVEL CATEGORY EVENT MESSAGE [KEY VALUE]...
#   Render a structured log record to a human-readable line on stderr.
#   Format: HH:MM:SS.mmm LEVEL [category] event: message key=val ...
_log_render_console() {
  local level="$1"
  local category="$2"
  local event="$3"
  local message="$4"
  shift 4

  # Build timestamp from EPOCHREALTIME (no external commands).
  local ts="$EPOCHREALTIME"
  # Convert epoch seconds to HH:MM:SS.mmm using pure bash arithmetic.
  local int_part="${ts%%.*}"
  local frac_part="${ts#*.}"
  frac_part="${frac_part:0:3}"
  local secs=$((int_part % 60))
  local mins=$(((int_part / 60) % 60))
  local hours=$(((int_part / 3600) % 24))
  local ts_fmt
  printf -v ts_fmt '%02d:%02d:%02d.%s' "$hours" "$mins" "$secs" "$frac_part"

  # Level tag — uppercase, padded to 5 chars.
  local level_tag="${level^^}"
  printf -v level_tag '%-5s' "$level_tag"

  # Choose color.
  local c_start="" c_end=""
  if ((_LOG_COLOR)); then
    c_end="$_LOG_RESET"
    case "$level" in
      debug) c_start="$_LOG_C_DEBUG" ;;
      info) c_start="$_LOG_C_INFO" ;;
      notice) c_start="$_LOG_C_NOTICE" ;;
      warn) c_start="$_LOG_C_WARN" ;;
      error) c_start="$_LOG_C_ERROR" ;;
    esac
  fi

  # Build key=value tail.
  local kv_tail=""
  while (($# >= 2)); do
    local k="$1" v="$2"
    shift 2
    v="$(_log_redact "$k" "$v")"
    kv_tail+=" ${k}=${v}"
  done

  # Emit to stderr (never stdout).
  printf '%s %s%s%s [%s] %s: %s%s\n' \
    "$ts_fmt" \
    "$c_start" "$level_tag" "$c_end" \
    "$category" \
    "$event" \
    "$message" \
    "$kv_tail" \
    >&2
}

# ---------------------------------------------------------------------------
# Initialization / teardown
# ---------------------------------------------------------------------------

# log_init [--log-file PATH] [--file-level LEVEL] [--console-level LEVEL] [--console-category CATS] [--gui] [--no-color]
#   Initialize the logging subsystem.
#   Call once at program start before any _log_emit calls.
log_init() {
  local log_file="" file_level="info" console_level="notice" console_categories="" no_color=0 gui=0

  while (($# > 0)); do
    case "$1" in
      --log-file)
        log_file="${2:?log_init: --log-file requires a path}"
        shift 2
        ;;
      --file-level)
        file_level="${2:?log_init: --file-level requires a level}"
        shift 2
        ;;
      --console-level)
        console_level="${2:?log_init: --console-level requires a level}"
        shift 2
        ;;
      --console-category)
        console_categories="${2:-}"
        shift 2
        ;;
      --gui)
        gui=1
        shift
        ;;
      --no-color)
        no_color=1
        shift
        ;;
      *)
        echo "log_init: unknown option: $1" >&2
        shift
        ;;
    esac
  done

  # GUI mode overrides console level to info (unless user explicitly set --console-level after --gui).
  if ((gui)); then
    _LOG_GUI=1
    console_level="info"
  fi

  # Set file level.
  _LOG_FILE_LEVEL="$(_log_level_num "$file_level")"

  # Set console level.
  _LOG_CONSOLE_LEVEL="$(_log_level_num "$console_level")"

  # Set category whitelist.
  _LOG_CONSOLE_CATEGORIES="$console_categories"

  # Configure colors.
  if ((no_color)) || [[ ! -t 2 ]]; then
    _LOG_COLOR=0
    _LOG_C_DEBUG=""
    _LOG_C_INFO=""
    _LOG_C_NOTICE=""
    _LOG_C_WARN=""
    _LOG_C_ERROR=""
    _LOG_RESET=""
  else
    _LOG_COLOR=1
    _LOG_C_DEBUG=$'\e[0;37m'  # dim white (gray)
    _LOG_C_INFO=$'\e[1;35m'   # bold magenta (matches existing log())
    _LOG_C_NOTICE=$'\e[1;36m' # bold cyan
    _LOG_C_WARN=$'\e[1;33m'   # bold yellow
    _LOG_C_ERROR=$'\e[1;31m'  # bold red
    _LOG_RESET=$'\e[0m'
  fi

  # Open log file if requested.
  if [[ -n "$log_file" ]]; then
    _LOG_FILE_PATH="$log_file"
    # Use a dedicated file descriptor for atomic appends.
    # exec with >> creates the file if needed and supports concurrent writers.
    exec {_LOG_FD}>>"$log_file"
    if [[ -z "$_LOG_FD" ]]; then
      echo "log_init: failed to open log file: $log_file" >&2
      _LOG_FD=""
      _LOG_FILE_PATH=""
    fi
  fi
}

# log_close
#   Flush and close the log file descriptor.
#   Safe to call multiple times or when no file was opened.
log_close() {
  if [[ -n "${_LOG_FD}" ]]; then
    exec {_LOG_FD}>&- 2>/dev/null || true
    _LOG_FD=""
  fi
  _LOG_FILE_PATH=""
}

# ---------------------------------------------------------------------------
# Core emission
# ---------------------------------------------------------------------------

# _log_emit LEVEL CATEGORY EVENT MESSAGE [KEY VALUE]...
#   Emit a structured log record.
#   - Writes JSON Lines to the log file (if open).
#   - Renders a human-readable line to stderr (if level >= console threshold).
#   LEVEL: debug|info|notice|warn|error
#   CATEGORY: freeform string (e.g. build, install, network)
#   EVENT: short event identifier (e.g. start, complete, failed)
#   MESSAGE: human-readable message
#   KEY VALUE: zero or more key-value pairs (alternating).
_log_emit() {
  local level="${1:?_log_emit: missing LEVEL}"
  local category="${2:?_log_emit: missing CATEGORY}"
  local event="${3:?_log_emit: missing EVENT}"
  local message="${4:-}"
  shift 4

  local level_num
  level_num="$(_log_level_num "$level")"

  # --- JSON Lines output (to log file) ---
  if [[ -n "${_LOG_FD}" ]] && ((level_num >= _LOG_FILE_LEVEL)); then
    local ts="$EPOCHREALTIME"
    local pid="$$"
    local subshell="${BASH_SUBSHELL}"

    # Build JSON manually (no jq dependency).
    local json="{\"schema\":1"
    json+=",\"ts\":\"$(_log_json_escape "$ts")\""
    json+=",\"level\":\"$(_log_json_escape "$level")\""
    json+=",\"pid\":$pid"
    json+=",\"subshell\":$subshell"
    json+=",\"category\":\"$(_log_json_escape "$category")\""
    json+=",\"event\":\"$(_log_json_escape "$event")\""
    json+=",\"msg\":\"$(_log_json_escape "$message")\""

    # Key-value pairs.
    while (($# >= 2)); do
      local k="$1" v="$2"
      shift 2
      v="$(_log_redact "$k" "$v")"
      json+=",\"$(_log_json_escape "$k")\":\"$(_log_json_escape "$v")\""
    done

    json+="}"

    # Single printf to fd for atomicity (safe for concurrent writes to the
    # same file via >>, which is line-atomic on Linux for writes <= PIPE_BUF).
    # shellcheck disable=SC2261  # stdout→fd, stderr→/dev/null — intentional, no conflict
    printf '%s\n' "$json" >&"${_LOG_FD}" 2>/dev/null || true
  fi

  # --- Console output (to stderr) ---
  if _log_should_console "$category" "$level_num"; then
    _log_render_console "$level" "$category" "$event" "$message" "$@"
  fi
  return 0
}

# _log_emit_to_fd FD LEVEL CATEGORY EVENT MESSAGE [KEY VALUE]...
#   Like _log_emit but writes JSONL to a specific file descriptor.
_log_emit_to_fd() {
  local target_fd="${1:?_log_emit_to_fd: missing FD}"
  local level="${2:?_log_emit_to_fd: missing LEVEL}"
  local category="${3:?_log_emit_to_fd: missing CATEGORY}"
  local event="${4:?_log_emit_to_fd: missing EVENT}"
  local message="${5:-}"
  shift 5

  local level_num
  level_num="$(_log_level_num "$level")"

  # --- JSON Lines output to specified fd ---
  local ts="$EPOCHREALTIME"
  local pid="$$"
  local subshell="${BASH_SUBSHELL}"

  local json="{\"schema\":1"
  json+=",\"ts\":\"$(_log_json_escape "$ts")\""
  json+=",\"level\":\"$(_log_json_escape "$level")\""
  json+=",\"pid\":$pid"
  json+=",\"subshell\":$subshell"
  json+=",\"category\":\"$(_log_json_escape "$category")\""
  json+=",\"event\":\"$(_log_json_escape "$event")\""
  json+=",\"msg\":\"$(_log_json_escape "$message")\""

  while (($# >= 2)); do
    local k="$1" v="$2"
    shift 2
    v="$(_log_redact "$k" "$v")"
    json+=",\"$(_log_json_escape "$k")\":\"$(_log_json_escape "$v")\""
  done

  json+="}"

  printf '%s\n' "$json" >"${target_fd}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Convenience wrappers
# ---------------------------------------------------------------------------

# log_debug CATEGORY EVENT MESSAGE [KEY VALUE]...
log_debug() { _log_emit debug "$@"; }

# log_info CATEGORY EVENT MESSAGE [KEY VALUE]...
log_info() { _log_emit info "$@"; }

# log_notice CATEGORY EVENT MESSAGE [KEY VALUE]...
log_notice() { _log_emit notice "$@"; }

# log_warn CATEGORY EVENT MESSAGE [KEY VALUE]...
log_warn() { _log_emit warn "$@"; }

# log_error CATEGORY EVENT MESSAGE [KEY VALUE]...
log_error() { _log_emit error "$@"; }

# log_die CATEGORY EVENT MESSAGE [KEY VALUE]...
#   Emit an error-level record, then exit with code 1.
log_die() {
  _log_emit error "$@"
  exit 1
}

# ---------------------------------------------------------------------------
# Stream capture
# ---------------------------------------------------------------------------

# log_capture_stream [--fd FD] CATEGORY LEVEL EVENT [KEY VALUE]...
#   Read stdin line-by-line and emit each line as a structured log record.
#   Useful for capturing command output into the structured log.
#   With --fd, write JSONL to the given file descriptor instead of the default.
#   Example: some_command 2>&1 | log_capture_stream build info cmd-output
log_capture_stream() {
  local target_fd=""

  # Parse optional --fd flag.
  while [[ "${1:-}" == --fd ]]; do
    shift
    target_fd="${1:?log_capture_stream: --fd requires an argument}"
    shift
    if ! [[ "$target_fd" =~ ^[0-9]+$ ]]; then
      log_warn pipeline log "log_capture_stream: --fd requires a numeric argument, got: $target_fd"
      target_fd=""
    fi
  done

  local category="${1:?log_capture_stream: missing CATEGORY}"
  local level="${2:?log_capture_stream: missing LEVEL}"
  local event="${3:?log_capture_stream: missing EVENT}"
  shift 3

  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$target_fd" ]]; then
      _log_emit_to_fd "$target_fd" "$level" "$category" "$event" "$line" "$@"
    else
      _log_emit "$level" "$category" "$event" "$line" "$@"
    fi
  done
}

# ---------------------------------------------------------------------------
# Step / stage / progress helpers
# ---------------------------------------------------------------------------

# logging_set_step STEP_NAME
#   Sets the current step name for structured logging.
logging_set_step() {
  _LOG_CURRENT_STEP="${1:-}"
}

# log_stage CATEGORY STAGE [MESSAGE]
#   Logs a stage header (replaces stage_header).  Emits a structured event
#   AND renders a visual separator to stderr.
log_stage() {
  local category="${1:-pipeline}"
  local stage="${2:-}"
  local message="${3:-}"
  # Emit structured record
  _log_emit notice "$category" stage_start "$message" stage "$stage"
  # Render visual separator to stderr
  local _sep='============================================================'
  printf '%s\n' "$_sep" >&2
  printf '  %s\n' "${stage^^}" >&2
  printf '%s\n' "$_sep" >&2
}

# log_progress CATEGORY STEP PERCENT
#   Logs a progress event (replaces progress_emit).
#   In GUI mode emits @@PROGRESS:XX@@ to stdout.
#   In CLI mode, emits structured record only.
log_progress() {
  local category="${1:-pipeline}"
  local step="${2:-}"
  local percent="${3:-0}"
  # Emit structured record
  _log_emit info "$category" progress "" step "$step" percent "$percent"
  # In GUI mode, also emit progress marker to stdout
  if [[ "${_LOG_GUI:-0}" == 1 ]]; then
    printf '@@PROGRESS:%s@@\n' "$percent" >&1
  fi
}
