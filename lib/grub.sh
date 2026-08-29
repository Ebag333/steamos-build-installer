#!/bin/bash
#
# steamos-build-installer — lib/grub.sh
# Centralized GRUB/kernel command line management.
#
# All kernel parameters that need to land on the boot command line are
# accumulated here via add_kernel_param(), then applied idempotently
# by patch_persistent_defaults(), patch_kernel_cmdline(), and verified
# by finalize_grub().  reconcile_grub() owns the complete mounted-target flow.
#
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/grub.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Accumulated extra kernel parameters (beyond NVIDIA_CMDLINE_ADD / DEBUG_CMDLINE_ADD).
# Use add_kernel_param() to append — never set directly.
# := prevents erasing accumulated state if grub.sh is sourced more than once.
: "${EXTRA_CMDLINE_ADD:=}"

# Add a kernel parameter to the build's command line.
# Idempotent: duplicates are silently ignored.
# Args: $1 = parameter (e.g. "pci=realloc=on")
add_kernel_param() {
  local param="${1:?add_kernel_param: missing parameter}"
  case " $EXTRA_CMDLINE_ADD " in
    *" $param "*) ;; # already present
    *) EXTRA_CMDLINE_ADD="${EXTRA_CMDLINE_ADD:+$EXTRA_CMDLINE_ADD }$param" ;;
  esac
}

# Build the complete list of kernel parameters for this build.
# Returns the full parameter string via stdout.
_build_all_params() {
  local all_params="$NVIDIA_CMDLINE_ADD"
  [[ -n "${EXTRA_CMDLINE_ADD:-}" ]] && all_params+=" $EXTRA_CMDLINE_ADD"
  [[ "${DEBUG_BOOT:-0}" -eq 1 ]] && all_params+=" $DEBUG_CMDLINE_ADD"
  echo "$all_params"
}

# ── Token matching ────────────────────────────────────────────────────────────
# All param-presence checks use _has_token to avoid substring false positives.
# e.g. "foo=1" must NOT match "foo=10".

# Check if a space-separated string contains an exact token.
# Args: $1 = haystack, $2 = needle
_has_token() {
  local haystack=" $1 " needle="$2"
  [[ "$haystack" == *" $needle "* ]]
}

# Check if a parameter is present on ALL steamenv_boot linux lines in grub.cfg.
# Returns failure if ANY kernel entry is missing the parameter.
# Args: $1 = grub.cfg path, $2 = parameter
_param_on_kernel_line() {
  local grub_cfg="$1" param="$2"
  local found_any=0 line
  while IFS="" read -r line; do
    line="${line%%#*}"
    found_any=1
    _has_token "$line" "$param" || return 1
  done < <(grep 'steamenv_boot.*linux.*/boot/vmlinuz' "$grub_cfg" 2>/dev/null)
  [[ $found_any -eq 1 ]] || return 1 # no kernel lines at all = fail
  return 0
}

# Check if a parameter is present in GRUB_CMDLINE_LINUX_DEFAULT (single-line).
# Uses whole-token matching.
# Args: $1 = grub-default path, $2 = parameter
_param_in_grub_default() {
  local grub_default="$1" param="$2"
  local value
  value="$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_default" 2>/dev/null)"
  [[ -n "$value" ]] || return 1
  # Extract contents between first " and last "
  value="${value#*\"}"
  value="${value%\"*}"
  _has_token "$value" "$param"
}

# ── Multiline grub-steamos helpers ────────────────────────────────────────────
# SteamOS's /etc/default/grub-steamos uses multiline continuation:
#
#   GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX} \
#   log_buf_len=4M \
#   ... \
#   fsck.repair=preen \
#   "
#
# We must parse the full value across continuation lines, add missing params,
# and write back preserving the multiline structure.

# Read the full value of GRUB_CMDLINE_LINUX from a file, joining continuation
# lines.  Returns the value (without the variable name and quotes).
# Args: $1 = file path
_read_grub_steamos_value() {
  local file="$1"
  local full_value="" in_block=0
  local line
  while IFS="" read -r line; do
    if [[ "$line" =~ ^GRUB_CMDLINE_LINUX= ]]; then
      in_block=1
      # Get everything after GRUB_CMDLINE_LINUX="
      line="${line#GRUB_CMDLINE_LINUX=\"}"
    elif [[ $in_block -eq 0 ]]; then
      continue
    fi

    if [[ $in_block -eq 1 ]]; then
      # Check for continuation
      if [[ "$line" == *\\ ]]; then
        line="${line%\\}"
        full_value+="$line "
      else
        # Last line — strip trailing quote and whitespace
        line="${line%\"*}"
        line="${line%"${line##*[![:space:]]}"}" # trim trailing whitespace
        full_value+="$line"
        break
      fi
    fi
  done <"$file"
  echo "$full_value"
}

# Check if a parameter is present in grub-steamos (multiline-aware).
# Args: $1 = file path, $2 = parameter
_param_in_grub_steamos() {
  local file="$1" param="$2"
  local value
  value="$(_read_grub_steamos_value "$file")"
  _has_token "$value" "$param"
}

# Add parameters to grub-steamos, preserving multiline format.
# Uses awk to reconstruct the block cleanly: existing lines keep their
# structure, new params are appended as continuation lines before the
# closing quote.
# Args: $1 = file path, $2... = parameters to add
_add_params_to_grub_steamos() {
  local file="$1"
  shift
  local params_to_add=("$@")

  local current_value
  current_value="$(_read_grub_steamos_value "$file")"

  # Collect only the params that are actually missing
  local new_params=()
  local param
  for param in "${params_to_add[@]}"; do
    if ! _has_token "$current_value" "$param"; then
      new_params+=("$param")
    fi
  done

  if [[ ${#new_params[@]} -eq 0 ]]; then
    log "  All params already in grub-steamos"
    return 0
  fi

  for param in "${new_params[@]}"; do
    log "  Adding $param to grub-steamos"
  done

  # Reconstruct the file: pass non-GRUB lines through, for the
  # GRUB_CMDLINE_LINUX block find the closing-quote line and insert
  # the new params before it with proper continuation.
  awk -v new_params="${new_params[*]}" '
    BEGIN {
      n = split(new_params, np, " ")
      in_block = 0
    }
    /^GRUB_CMDLINE_LINUX=/ {
      in_block = 1
      print
      next
    }
    in_block && !/\\[[:space:]]*$/ {
      # Closing-quote line: not a continuation (no trailing \).
      # May be just " or something like fsck.repair=preen "
      # Strip the closing quote and whitespace, then reconstruct
      # with new params appended.
      line = $0
      sub(/[[:space:]]*"$/, "", line)
      if (line != "") {
        # There is content before the quote — turn into continuation
        print line " \\"
      }
      for (i = 1; i <= n; i++) {
        if (i < n) {
          print "  " np[i] " \\"
        } else {
          print "  " np[i] "\""
        }
      }
      in_block = 0
      next
    }
    in_block && /\\[[:space:]]*$/ {
      # Continuation line inside the block — pass through
      print
      next
    }
    { print }
  ' "$file" >"$file.tmp" && mv "$file.tmp" "$file"
}

# ── Phase 1: persistent defaults ─────────────────────────────────────────────
# Write accumulated params to /etc/default/grub and /etc/default/grub-steamos.
# These files survive regenerations and A/B updates.  Call BEFORE update-grub
# so that regeneration picks up the full parameter set.

patch_persistent_defaults() {
  local grub_default="$MNT/etc/default/grub"
  local grub_steamos="$MNT/etc/default/grub-steamos"

  local all_params
  all_params="$(_build_all_params)"

  # ── /etc/default/grub (single-line GRUB_CMDLINE_LINUX_DEFAULT="...") ────
  # Only strip "quiet" — do NOT inject our params here.  grub-steamos
  # (GRUB_CMDLINE_LINUX) is the sole persistent source; writing to both
  # caused the entire parameter set to appear twice on /proc/cmdline
  # because the grub generator consumes both variables.
  if [[ -f "$grub_default" ]]; then
    log "Stripping quiet from /etc/default/grub"
    _remove_quiet_from_grub_default "$grub_default"
  fi

  # ── /etc/default/grub-steamos (multiline GRUB_CMDLINE_LINUX="...") ──────
  if [[ -f "$grub_steamos" ]]; then
    log "Patching /etc/default/grub-steamos persistent defaults"

    # Collect params that need adding
    local params_to_add=()
    local param
    for param in $all_params; do
      if ! _param_in_grub_steamos "$grub_steamos" "$param"; then
        params_to_add+=("$param")
      fi
    done

    if [[ ${#params_to_add[@]} -gt 0 ]]; then
      _add_params_to_grub_steamos "$grub_steamos" "${params_to_add[@]}"
    else
      log "  All params already in grub-steamos"
    fi

    # Always ensure the atomic-update keep-list entry exists (idempotent).
    _ensure_grub_steamos_keep_list
  fi
}

# Ensure grub-steamos is in the atomic-update keep-list.
# Idempotent: safe to call every time regardless of whether params changed.
_ensure_grub_steamos_keep_list() {
  local keep_dir="$MNT/etc/atomic-update.conf.d"
  local keep_file="$keep_dir/steamos-build-installer.conf"
  if [[ -d "$keep_dir" ]]; then
    if ! grep -q '/etc/default/grub-steamos' "$keep_file" 2>/dev/null; then
      mkdir -p "$keep_dir"
      echo "/etc/default/grub-steamos" >>"$keep_file"
      log "  Added grub-steamos to atomic-update keep-list"
    fi
  else
    warn "atomic-update.conf.d not found — grub-steamos may not persist across updates"
  fi
}

# Remove "quiet" from GRUB_CMDLINE_LINUX_DEFAULT, handling both:
#   GRUB_CMDLINE_LINUX_DEFAULT="foo quiet bar"
#   GRUB_CMDLINE_LINUX_DEFAULT="quiet"
# Token loop — no pipelines, safe under set -euo pipefail.
_remove_quiet_from_grub_default() {
  local grub_default="$1"
  local line value

  line="$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_default" 2>/dev/null)" || return 0
  value="${line#*\"}"
  value="${value%\"*}"

  local new_value="" token
  for token in $value; do
    [[ "$token" == "quiet" ]] && continue
    new_value="${new_value:+$new_value }$token"
  done

  if [[ "$value" != "$new_value" ]]; then
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\".*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"$new_value\"|" \
      "$grub_default"
    log "  Removed quiet from /etc/default/grub"
  fi
}

# ── Phase 2: EFI grub.cfg ────────────────────────────────────────────────────
# Directly patch the EFI grub.cfg kernel lines with all accumulated params.
# Call AFTER patch_persistent_defaults() and AFTER update-grub (if used).
# This is the authoritative patch — what's in grub.cfg at boot is what counts.

patch_kernel_cmdline() {
  local grub_cfg="$EFIMNT/EFI/steamos/grub.cfg"

  [[ -f "$grub_cfg" ]] \
    || die "EFI grub.cfg not found: $grub_cfg"

  local all_params
  all_params="$(_build_all_params)"

  log "Patching EFI grub.cfg kernel lines"

  # Remove quiet from all kernel lines
  local quiet_sed='s/(^|[[:space:]])quiet([[:space:]]|$)/\1/g'
  sed -i -E "$quiet_sed" "$grub_cfg"

  # Patch each kernel line (there may be multiple steamenv_boot entries).
  # Add param only to lines that don't already have it (avoids duplication).
  local param
  for param in $all_params; do
    if ! _param_on_kernel_line "$grub_cfg" "$param"; then
      log "  Adding $param to EFI grub.cfg"
      awk -v param="$param" '
        /steamenv_boot[[:space:]]+linux[[:space:]]+\/boot\/vmlinuz/ {
          n = split($0, tokens, " ")
          found = 0
          for (i = 1; i <= n; i++) { if (tokens[i] == param) { found = 1; break } }
          if (!found) print $0 " " param; else print
          next
        }
        { print }
      ' "$grub_cfg" >"$grub_cfg.tmp" && mv "$grub_cfg.tmp" "$grub_cfg"
    fi
  done
}

# ── Validation ────────────────────────────────────────────────────────────────
# Validate that every requested parameter is present in EFI grub.cfg,
# /etc/default/grub, and /etc/default/grub-steamos.
# Dies on failure — the image must not be published with missing boot params.

finalize_grub() {
  local grub_cfg="$EFIMNT/EFI/steamos/grub.cfg"
  local grub_default="$MNT/etc/default/grub"
  local grub_steamos="$MNT/etc/default/grub-steamos"

  [[ -f "$grub_cfg" ]] \
    || die "EFI grub.cfg not found for validation: $grub_cfg"

  local all_params
  all_params="$(_build_all_params)"

  log "Validating kernel command line"

  local failed=0
  local param

  # ── EFI grub.cfg ──
  for param in $all_params; do
    if ! _param_on_kernel_line "$grub_cfg" "$param"; then
      warn "  MISSING from EFI grub.cfg kernel line: $param"
      failed=1
    else
      log "  OK grub.cfg: $param"
    fi
  done

  # ── /etc/default/grub ──
  # Only verify quiet was stripped — our params live in grub-steamos only.
  if [[ -f "$grub_default" ]]; then
    if _param_in_grub_default "$grub_default" "quiet"; then
      warn "  quiet still present in /etc/default/grub"
      failed=1
    else
      log "  OK grub default: quiet removed"
    fi
  fi

  # ── /etc/default/grub-steamos ──
  if [[ -f "$grub_steamos" ]]; then
    for param in $all_params; do
      if ! _param_in_grub_steamos "$grub_steamos" "$param"; then
        warn "  MISSING from grub-steamos: $param"
        failed=1
      else
        log "  OK grub-steamos: $param"
      fi
    done

    # Validate atomic-update keep-list
    local keep_file="$MNT/etc/atomic-update.conf.d/steamos-build-installer.conf"
    if [[ -d "$MNT/etc/atomic-update.conf.d" ]]; then
      if ! grep -q '/etc/default/grub-steamos' "$keep_file" 2>/dev/null; then
        warn "  MISSING: grub-steamos not in atomic-update keep-list"
        failed=1
      else
        log "  OK keep-list: grub-steamos present"
      fi
    fi
  else
    warn "  MISSING: /etc/default/grub-steamos not found"
    failed=1
  fi

  if [[ $failed -eq 1 ]]; then
    die "Kernel command line validation failed — build aborted"
  fi

  log "Kernel command line verified: $all_params"
}

# Reconcile GRUB for a mounted target rootfs/EFI device.
#
# Owns the complete order required by SteamOS:
#   mount EFI + chroot support filesystems
#   patch persistent defaults
#   run update-grub best-effort
#   directly patch EFI grub.cfg authoritatively
#   validate
#   sync + unmount
#
# Args:
#   $1 = target rootfs mountpoint
#   $2 = target EFI block device
#   $3 = optional human-readable slot/partset label
reconcile_grub() {
  local root="${1:?reconcile_grub: missing target root}"
  local efi_dev="${2:?reconcile_grub: missing EFI device}"
  local label="${3:-target}"

  # Existing GRUB helpers intentionally use MNT/EFIMNT globals.  Bash's dynamic
  # scoping lets these locals provide the expected values without mutating the
  # caller's global state.
  local MNT="$root"
  local EFIMNT="$root/efi"

  [[ -d "$root" ]] \
    || die "GRUB target root not found: $root"
  [[ -b "$efi_dev" ]] \
    || die "GRUB EFI device is not a block device: $efi_dev"

  mkdir -p "$EFIMNT"

  if mountpoint -q "$EFIMNT" 2>/dev/null; then
    die "Refusing to stack EFI mount on existing mountpoint: $EFIMNT"
  fi

  log "Mounting $label EFI: $efi_dev -> $(readlink -f "$efi_dev" 2>/dev/null || echo '<unresolved>')"
  mount "$efi_dev" "$EFIMNT" \
    || die "Could not mount EFI for $label"

  log "Target EFI mount: $(findmnt -rn -o SOURCE,FSTYPE,OPTIONS,TARGET "$EFIMNT" 2>/dev/null || echo '<unknown>')"

  if [[ -d "$EFIMNT/SteamOS/partsets" ]]; then
    local efi_line
    while IFS="" read -r efi_line; do
      log "  target EFI partsets: $efi_line"
    done < <(ls -la "$EFIMNT/SteamOS/partsets" 2>&1)
  else
    log "  target EFI partsets: <missing>"
  fi

  mount_chroot_fs "$root"

  # ERR trap ensures teardown runs even if patching or validation calls die().
  # Uses the permissive chroot cleanup variant (lazy-unmount fallback, never
  # dies) so the trap itself cannot fail while we are already handling an error.
  # shellcheck disable=SC2317  # Called via trap _reconcile_grub_cleanup ERR below
  _reconcile_grub_cleanup() {
    set +e
    umount_chroot_fs "$root" 2>/dev/null
    umount "$EFIMNT" 2>/dev/null || umount -l "$EFIMNT" 2>/dev/null
  }
  trap _reconcile_grub_cleanup ERR

  # Persistent defaults must be patched before update-grub so regeneration
  # sees the complete desired parameter set.
  patch_persistent_defaults

  log "Attempting update-grub (non-fatal if it fails)"
  chroot "$root" update-grub 2>/dev/null \
    || log "update-grub failed — will patch EFI grub.cfg directly"

  # Authoritative patch + validation.  Do not rely on update-grub alone.
  patch_kernel_cmdline
  finalize_grub

  trap - ERR

  log "Syncing $label rootfs and EFI"
  btrfs filesystem sync "$root"
  sync -f "$root"
  sync -f "$EFIMNT" 2>/dev/null || sync

  umount_chroot_fs "$root" strict
  umount "$EFIMNT"
}

# ── Compatibility wrappers ────────────────────────────────────────────────────
# patch_grub_steamos() is kept for callers that only need grub-steamos patching
# (e.g. install-driver.sh).  It now delegates to patch_persistent_defaults()
# which handles both grub and grub-steamos.

patch_grub_steamos() {
  patch_persistent_defaults
}
