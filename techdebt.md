# Technical Debt & Larger Refactors

This file tracks issues that require larger refactors, logic changes, or impacts outside a single function's scope. These are deferred for later resolution.

---

## Fixed Items (This Session)

### lib/common.sh
- ✅ cleanup() ERR trap not disabled — added `trap - ERR`
- ✅ _persist_project_files_cp cp -a nesting — changed to `cp -a src/. dest/`
- ✅ chmod 777 on recovery dir — changed to `chmod 1777`
- ✅ debug_cmd triggers ERR trap — added `|| true`
- ✅ compare_system_state empty comm — wrapped with `grep -v '^$'`
- ✅ _persist_project_files_cp permissions — changed `cp -f` to `cp -fp`
- ✅ log() sends to stdout — added `>&2` to both printf calls
- ✅ compute_payload input validation — added guards for MNT, MERGED, UPPER, KVER, WORKDIR
- ✅ cleanup warning missing WORKDIR path — added `${WORKDIR:-}` to message
- ✅ curl_retry fixed backoff — changed to exponential `sleep $((2 ** (i - 1)))`

### lib/args.sh
- ✅ _ARG_SHIFT not initialized — added `_ARG_SHIFT=0` at function top
- ✅ Header comment incomplete — added VALIDATE_OUTPUT_FILE, DEBUG, VERBOSE
- ✅ --key=value syntax not supported — added `--*=*` case pattern

### lib/library-loader.sh
- ✅ warn called before common.sh sourced — replaced with `printf >&2`
- ✅ _load_lib warn before common.sh — replaced with `printf >&2` with base_dir context

### lib/backend.sh
- ✅ local in pipe subshell — replaced pipe with heredoc `<<<` approach
- ✅ _cleanup_done not local — added `local` declaration
- ✅ Arithmetic under set -e — changed `(( ))` to `[[ ]]` test
- ✅ Unquoted $rc in return — added quotes
- ✅ validate_cleanup blind set -e restore — save/restore with `_had_e`

### lib/common_drivers.sh
- ✅ generate_payload_filelist empty array — added guard
- ✅ register_payload_pkgs empty array — added guard
- ✅ construct_hdr_url no validation — added die checks for jupiter_repo and mirror

### lib/common_modules.sh
- ✅ modinfo not chrooted — added chroot branch for root != /
- ✅ ((failed)) fragile pattern — changed to `[[ "$failed" -ne 0 ]]`
- ✅ _ok naming inverted — renamed to `failed`

### lib/common_system.sh
- ✅ untrack_mount grep exit code — fix tracking file cleanup
- ✅ Duplicate rm -rf line — removed duplicate
- ✅ Negative freed_kb — added `((freed_kb < 0)) && freed_kb=0`
- ✅ Misleading log message — "Strict" → "Regular"
- ✅ mount_chroot_fs no cleanup — added error handling with umount on failure
- ✅ ls | head fragile — replaced with glob

### lib/check-deps.sh
- ✅ Exit code wrapping — changed to `exit 1`
- ✅ No CLI arg validation — added case statement
- ✅ read on EOF kills script — added `|| { echo "Aborted."; exit 1; }`
- ✅ Unquoted assoc array keys — replaced with `while read` + process substitution

### lib/overlay.sh
- ✅ die in pipe subshell — replaced with process substitution
- ✅ Missing IFS="" — added to inner read
- ✅ read without newline guard — split into read || true + [[ -n ]] check
- ✅ truncate/mkfs no error handling — added `|| die`
- ✅ in_chroot "$*" — changed to "$1"

### lib/flash.sh
- ✅ dd pipe subshell swallows errors — process substitution + dd_exit capture
- ✅ findmnt in arithmetic — extracted to variable with fallback
- ✅ Missing -n guard on ws_disk — added guard

### lib/pipeline.sh
- ✅ define_pipeline no empty-args guard — added guard + consistent unset+declare
- ✅ register_phase :? kills process — replaced with manual checks + declare -F validation
- ✅ run_pipeline silent no-op on zero phases — added guard
- ✅ run_pipeline no pre-validation — added pre-validation loop
- ✅ ((++phase_num)) fragile — changed to arithmetic assignment
- ✅ Duplicated timing code — refactored to phase_rc pattern
- ✅ _pipeline_report_failure uses wrong phase list — now accepts active_phases
- ✅ ((found)) fragile — changed to [[ $found -ne 0 ]]

### lib/customization.sh
- ✅ hw-packages.conf parser missing group field (CRITICAL) — added group to all 3 read statements
- ✅ Missing newline guards on all 4 while-read loops — added || [[ -n "$var" ]]
- ✅ get_build_recipe silent failure — added warn message
- ✅ Unquoted $items glob risk — added set -f / set +f
- ✅ Shellcheck comments incorrect — updated to reflect group field

### lib/update-strategy.sh
- ✅ Unquoted $UPDATE_MODE — quoted all 3 comparisons
- ✅ No MNT/SCRIPT_DIR validation — added guards at function top
- ✅ Default UPDATE_MODE — added ${UPDATE_MODE:-selfheal}
- ✅ ln -sf without mkdir -p — added mkdir -p before both calls
- ✅ Hold loop no logging — added per-binary skip/error logging
- ✅ Hold loop mv no error handling — added || { warn; continue }
- ✅ Selfheal blocks no error handling — added mv/install error handling + logging
- ✅ No handling of unrecognized UPDATE_MODE — added elif guard
- ✅ Stock mode triggered unknown warning — fixed with elif != stock

### lib/update-wrapper.sh
- ✅ mkdir/chmod on recovery dir unconditional — guarded behind EUID check
- ✅ chmod 777 — changed to 755
- ✅ Relative symlink target — changed to absolute path
- ✅ echo with unquoted expansion — changed to printf

### lib/pci-discovery.sh
- ✅ 2>/dev/null on basename instead of readlink — moved to readlink with temp variable
- ✅ Comment/code header mismatch — CLASS_TYPE → CATEGORY

### lib/system-upgrade.sh
- ✅ Pre-flight skip returns 0 (success) — changed to return 1
- ✅ Missing guard on host resolv.conf — added -f check
- ✅ _raw_log default overrides global — changed to match common.sh default
- ✅ Empty before_file silent — added warning
- ✅ Empty after_file silent — added warning
- ✅ find searches entire $MNT — scoped to etc/usr/boot
- ✅ .pacsave removal unconditional — added existence check and log

### lib/scan-hardware.sh
- ✅ Hardcoded 0000: PCI domain — now detects domain presence
- ✅ ${modules%% *} no-op — changed to ${modules%%$'\n'*}
- ✅ pipefail causes loaded-module check to fail — wrapped in subshell with set +o pipefail
- ✅ Unquoted $desc in echo — changed to printf

### lib/detect-hw-packages.sh
- ✅ Duplicate key 17cb — consolidated to single mapping
- ✅ Wrong Cirrus Logic vendor IDs (1102/1106) — fixed to 1013
- ✅ Class code substring length mismatch — changed to 8 chars
- ✅ pacman -F output includes repo prefix — added sed strip
- ✅ nvidia module mapped to linux-firmware-nvidia — removed (proprietary bundles own firmware)
- ✅ head -5 may miss firmware files — increased to head -20

### lib/repatch.sh
- ✅ failure_journal_context missing trailing newline — added \n to printf
- ✅ patch_record no argument validation — added guards for name and status
- ✅ patch_record no status validation — added ok/fail check

### lib/system-config.sh
- ✅ verify_system_config expected defaults to empty — changed to :? required
- ✅ read_system_config silent on unknown items — added warn
- ✅ _apply_update_branch branch name not validated — added regex guard
- ✅ _apply_update_branch echo >> os-release trailing newline — changed to printf
- ✅ _apply_variant variant name not validated — added regex guard
- ✅ _apply_variant echo >> os-release trailing newline — changed to printf

### lib/workflow-common.sh
- ✅ configure_desktop_session return code not propagated — added || return 1
- ✅ run_custom_script exit code not captured — added local _rc=$? and included in warning
- ✅ ensure_flatpak_service mkdir not checked — added || { warn; return 1 }
- ✅ install_flatpak_packages $rc not quoted — added quotes

## Deferred Items

### 1. Boolean flags have no negation counterparts
**Severity:** Low  
**Lines:** 58-81  
**Issue:** `--allow-system-disk`, `--debug`, `--verbose` have no `--no-debug`, `--no-verbose`, or `--no-allow-system-disk` counterparts. Once set, there's no way to clear them.  
**Fix direction:** Add `--no-*` patterns or document the limitation.  
**Impact:** Minor UX limitation.

### 2. All variables are intentionally global — fragile by design
**Severity:** Low  
**Lines:** 26-85  
**Issue:** `parse_common_arg` sets all output variables (ACTION, IMG, etc.) as globals without `local`. This is by design for the callers, but fragile — any new caller that accidentally calls this function will have its variables silently overwritten.  
**Fix direction:** Document the global-variable contract more prominently, or consider an alternative interface.  
**Impact:** Maintenance hazard; no current bug.

---
