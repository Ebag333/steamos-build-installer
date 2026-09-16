#!/bin/bash
#
# Lint: logging
#
# Detects shell patterns that bypass structured logging in lib/:
#   silenced-stdout  — >/dev/null (stdout thrown away entirely)
#   silenced-stderr  — 2>/dev/null (stderr thrown away entirely)
#   merged-streams   — >file 2>&1 where file is NOT /dev/null
#   exec-redirect    — exec N>file (global fd redirections)
#   tee-redirect     — tee writing to flat files
#
# Only checks files under lib/ and its subdirectories.
#
# Inline suppression:  # lint-ignore: <check-name>
#   e.g., # lint-ignore: silenced-stdout
#         # lint-ignore: silenced-stderr
#         # lint-ignore: merged-streams
#         # lint-ignore: exec-redirect
#         # lint-ignore: tee-redirect
#
# Usage:
#   tools/lint/logging.sh [--repo-root DIR]
#
# Exit codes:
#   0 — no violations
#   1 — violations found
#   2 — usage error

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

printf 'Scanning: %s/lib\n\n' "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------

total=0

_check_silenced_stdout() {
  local label="silenced-stdout"
  local desc='output lost entirely (>/dev/null)'
  local count=0

  printf -- '--- %-16s — %s ---\n' "$label" "$desc"

  while IFS=: read -r file line code; do
    # Skip comments
    [[ "$code" =~ ^[[:space:]]*# ]] && continue
    # Skip lines with lint-ignore directive for this check
    local ignore_re="# *lint-ignore: *$label"
    [[ "$code" =~ $ignore_re ]] && continue
    # Skip lines with 2>/dev/null (stderr silencing, handled by check 2)
    [[ "$code" =~ 2\>/dev/null ]] && continue
    # Skip lines with 2>&1 (merged streams, handled by check 3)
    [[ "$code" =~ 2\>\&1 ]] && continue
    # Skip lines with &>/dev/null (both streams silenced, not just stdout)
    [[ "$code" =~ \&\>/dev/null ]] && continue
    # Must contain >/dev/null (stdout silenced)
    [[ "$code" =~ \>/dev/null ]] || continue

    local trimmed
    trimmed="$(printf '%s' "$code" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    printf '  [%-17s] %s:%s  %s\n' "$label" "$file" "$line" "$trimmed"
    ((++count)) || true
  done < <(
    grep -rnE '>/dev/null' --include='*.sh' "$REPO_ROOT/lib" 2>/dev/null || true
  )

  if ((count == 0)); then
    printf '  (none found)\n'
  fi
  printf '\n'
  total=$((total + count))
}

_check_silenced_stderr() {
  local label="silenced-stderr"
  local desc='output lost entirely (2>/dev/null)'
  local count=0

  printf -- '--- %-16s — %s ---\n' "$label" "$desc"

  while IFS=: read -r file line code; do
    # Skip comments
    [[ "$code" =~ ^[[:space:]]*# ]] && continue
    # Skip lines with lint-ignore directive for this check
    local ignore_re="# *lint-ignore: *$label"
    [[ "$code" =~ $ignore_re ]] && continue
    # Skip lines with > /dev/null 2>&1 (merged streams / silenced both, handled elsewhere)
    [[ "$code" =~ \>/dev/null\ 2\>\&1 ]] && continue
    # Must contain 2>/dev/null (stderr silenced)
    [[ "$code" =~ 2\>/dev/null ]] || continue

    # Extract the actual command name, skipping common wrappers
    local cmd="$code"
    # Strip leading whitespace
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"
    # Strip leading pipe (continuation of previous pipeline)
    case "$cmd" in
      "||"*) cmd="${cmd#||}" ;;
      "&&"*) cmd="${cmd#&&}" ;;
      "|"*)  cmd="${cmd#|}" ;;
    esac
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"
    # Skip past wrapper commands: chroot, in_chroot, sudo, su
    while [[ "$cmd" =~ ^(chroot|in_chroot|sudo|su|run_dangerous_cmd|_run_in_root)\ .+ ]]; do
      local _wrapper="${BASH_REMATCH[1]}"
      # Strip the wrapper command name and first space
      cmd="${cmd#* }"
      cmd="${cmd#"${cmd%%[![:space:]]*}"}"
      # After chroot/su/sudo, the next argument is PATH/USER/FLAGS — skip it
      # Handle: "quoted arg", 'quoted arg', or bare-word
      if [[ "$_wrapper" != "run_dangerous_cmd" && "$_wrapper" != "_run_in_root" ]]; then
        case "$cmd" in
          \"*\") cmd="${cmd#*\"}" ; cmd="${cmd#*\"}" ;;
          \'*\') cmd="${cmd#*\'}" ; cmd="${cmd#*\'}" ;;
          *)     cmd="${cmd#* }"  ;;
        esac
        cmd="${cmd#"${cmd%%[![:space:]]*}"}"
      fi
    done
    # Strip shell control keywords that precede the actual command
    cmd="${cmd#if }"
    cmd="${cmd#while }"
    cmd="${cmd#until }"
    cmd="${cmd#! }"
    # Re-strip leading whitespace after keyword removal
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"
    # Strip case statement prefixes: pattern) cmd... or pattern)cmd...
    if [[ "$cmd" =~ ^[^[:space:]]+\)[[:space:]]* ]]; then
      cmd="${cmd#*)}"
      cmd="${cmd#"${cmd%%[![:space:]]*}"}"
    fi
    # Skip past variable assignments: var="$(cmd ...)", var='$(cmd ...)', or var=$(cmd ...)
    if [[ "$cmd" =~ ^[a-zA-Z_][a-zA-Z0-9_]*=.*\$\(\ * ]]; then
      cmd="${cmd#*\$(}"
      cmd="${cmd#"${cmd%%[![:space:]]*}"}"
    fi

    # Check if the command is in the safe-to-suppress list
    case "$cmd" in
      grep* | cut* | stat* | base64* | read* | true* | false* | kill* | wait* | type* | command* | which* | file* | ls* | find* | test* | \[* | shift* | export* | unset* | set* | shopt* | dirname* | basename* | realpath* | head* | tail* | wc* | sort* | uniq* | tr* | sed* | awk* | mktemp* | du* | df* | arch* | uname* | date* | seq* | losetup* | blkid* | modinfo* | modprobe* | rm* | rmdir* | umount* | mount* | pgrep* | fuser* | journalctl* | sync* | udevadm* | blockdev* | chmod* | chown* | mkdir* | cp* | mv* | steamos-bootconf* | rauc* | logger* | systemctl* | sysctl* | getent* | usermod* | passwd* | depmod* | btrfs* | parted* | sgdisk* | wipefs* | rsync* | git* | zenity* | nvidia-smi* | update-grub* | mkfs.vfat* | partx* | dmsetup* | rauc-bootconf* | id* | runuser* | systemd-tmpfiles* | cat* | readlink* | pacman* | printf* | eval* | exec* | trap* | source* | lspci* | safe_rmdir* | log* | warn* | done* | numfmt* | touch* | swapon* | xargs* | compgen* | curl* | dkms* | echo* | cleanup_unmount_registered* | unmount_effective_etc* | _run_in_root* | ln* | dmesg* | run_in_root* | _boot_value* | _slot_other* | _read_slot_build_id* | failure_journal_context* | _resolve_module_file* | _cp_if* | save* | _pf_* | _canonicalize_* | _efi_dev_* | _pf_fs_* | _pf_rfs_* | _pf_gen_* | _pf_map_* | _pf_path_* | _pf_resolve_* | strings* | mokutil* | od* | sha256sum* | systemd-machine-id-setup* | python3* | /bin/bash* | readelf* | bsdtar* | makepkg* | vercmp* | diff* | timeout* | pkg-config* | mapfile* | return* | gcc* | meson* | ninja* | fakeroot* | binutils* | debugedit* | bzip2* | gzip* | xz* | zstd* | cc* | verify_optimization_for_item* | cleanup_environment* | cleanup_release* | cleanup_set_workspace*)
        continue
        ;;
    esac

    local trimmed
    trimmed="$(printf '%s' "$code" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    printf '  [%-17s] %s:%s  %s\n' "$label" "$file" "$line" "$trimmed"
    ((++count)) || true
  done < <(
    grep -rnE '2>/dev/null' --include='*.sh' "$REPO_ROOT/lib" 2>/dev/null || true
  )

  if ((count == 0)); then
    printf '  (none found)\n'
  fi
  printf '\n'
  total=$((total + count))
}

_check_merged_streams() {
  local label="merged-streams"
  local desc='stdout+stderr merged into flat file (>file 2>&1)'
  local count=0

  printf -- '--- %-16s — %s ---\n' "$label" "$desc"

  while IFS=: read -r file line code; do
    # Skip comments
    [[ "$code" =~ ^[[:space:]]*# ]] && continue
    # Skip lines with lint-ignore directive for this check
    local ignore_re="# *lint-ignore: *$label"
    [[ "$code" =~ $ignore_re ]] && continue
    # Skip > /dev/null 2>&1 (silenced both streams)
    [[ "$code" =~ \>/dev/null\ 2\>\&1 ]] && continue
    # Skip &>/dev/null (silenced both streams, bash shorthand)
    [[ "$code" =~ \&\>/dev/null ]] && continue
    # Must match >something 2>&1 where something is NOT /dev/null
    [[ "$code" =~ \>([^ ]*)\ 2\>\&1 ]] || continue
    local target="${BASH_REMATCH[1]}"
    # Skip if target is /dev/null
    [[ "$target" == "/dev/null" ]] && continue
    # Skip if target is empty (bare > 2>&1)
    [[ -z "$target" ]] && continue

    local trimmed
    trimmed="$(printf '%s' "$code" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    printf '  [%-17s] %s:%s  %s\n' "$label" "$file" "$line" "$trimmed"
    ((++count)) || true
  done < <(
    grep -rnE '>[^ ]+ 2>&1' --include='*.sh' "$REPO_ROOT/lib" 2>/dev/null || true
  )

  if ((count == 0)); then
    printf '  (none found)\n'
  fi
  printf '\n'
  total=$((total + count))
}

_check_exec_redirect() {
  local label="exec-redirect"
  local desc='global fd redirections (exec N>file)'
  local count=0

  printf -- '--- %-16s — %s ---\n' "$label" "$desc"

  while IFS=: read -r file line code; do
    # Skip comments
    [[ "$code" =~ ^[[:space:]]*# ]] && continue
    # Skip lines with lint-ignore directive for this check
    local ignore_re="# *lint-ignore: *$label"
    [[ "$code" =~ $ignore_re ]] && continue
    # Skip exec 7>&1 8>&2 style (saving fd numbers, not redirecting to files)
    [[ "$code" =~ exec\ [0-9]+\>\& ]] && continue
    # Skip exec > >(tee ...) (tee with passthrough is fine)
    [[ "$code" =~ exec\ \>\ \>\( ]] && continue
    [[ "$code" =~ exec\ \>\>\ \>\( ]] && continue
    # Skip exec {fd}>&- (closing fds)
    [[ "$code" =~ exec\ \{[^}]+\}\>\&- ]] && continue
    # Skip exec {fd}>>file (appending to log file — this is log infrastructure)
    [[ "$code" =~ exec\ \{[^}]+\}\>\> ]] && continue
    # Must be exec with > but not >& (not saving fd numbers)
    [[ "$code" =~ exec\ .*\> ]] || continue
    # Skip lines that are only >& (fd-to-fd) redirections
    [[ "$code" =~ exec\ [0-9]+\>\&[0-9]+ ]] && continue

    # Now check: does it have a > that is NOT >& (file redirect, not fd redirect)?
    if ! printf '%s' "$code" | grep -qE 'exec\s+[0-9]*>[^&]'; then
      # Also check for eval "exec N>" pattern
      if ! printf '%s' "$code" | grep -qE 'eval\s+"exec\s+[0-9]*>|"exec\s+[0-9]*>'; then
        continue
      fi
    fi

    local trimmed
    trimmed="$(printf '%s' "$code" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    printf '  [%-17s] %s:%s  %s\n' "$label" "$file" "$line" "$trimmed"
    ((++count)) || true
  done < <(
    grep -rnE 'exec\s.*>' --include='*.sh' "$REPO_ROOT/lib" 2>/dev/null || true
  )

  if ((count == 0)); then
    printf '  (none found)\n'
  fi
  printf '\n'
  total=$((total + count))
}

_check_tee_redirect() {
  local label="tee-redirect"
  local desc="output tee'd to flat file"
  local count=0

  printf -- '--- %-16s — %s ---\n' "$label" "$desc"

  while IFS=: read -r file line code; do
    # Skip comments
    [[ "$code" =~ ^[[:space:]]*# ]] && continue
    # Skip lines with lint-ignore directive for this check
    local ignore_re="# *lint-ignore: *$label"
    [[ "$code" =~ $ignore_re ]] && continue
    # Skip tee /dev/null (discarding, not logging)
    [[ "$code" =~ tee\ /dev/null ]] && continue
    # Skip tee with no file argument (just passthrough)
    [[ "$code" =~ tee(\ -[a]*)?\ .+ ]] || continue

    local trimmed
    trimmed="$(printf '%s' "$code" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    printf '  [%-17s] %s:%s  %s\n' "$label" "$file" "$line" "$trimmed"
    ((++count)) || true
  done < <(
    grep -rnE '\btee\b' --include='*.sh' "$REPO_ROOT/lib" 2>/dev/null || true
  )

  if ((count == 0)); then
    printf '  (none found)\n'
  fi
  printf '\n'
  total=$((total + count))
}

# ---------------------------------------------------------------------------
# Run all checks
# ---------------------------------------------------------------------------

_check_silenced_stdout
_check_silenced_stderr
_check_merged_streams
_check_exec_redirect
_check_tee_redirect

# ---------------------------------------------------------------------------
# Exit
# ---------------------------------------------------------------------------

if [[ $total -gt 0 ]]; then
  echo ""
  echo "FAIL: $total logging bypass pattern(s) found"
  echo "To suppress a false positive, add:  # lint-ignore: <check-name>"
  exit 1
fi

echo "PASS: logging lint clean"
exit 0
