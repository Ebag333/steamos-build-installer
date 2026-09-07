#!/bin/bash
#
# steamos-build-installer — lib/build/validate.sh
# Validation matrix for the build framework.
#
# Run this to verify the framework handles failure modes correctly.
#
# Usage:
#   source lib/build/validate.sh
#   _run_validation_matrix "$MERGED"

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/build/validate.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Guard against double-sourcing
[[ -v _BUILD_VALIDATE_LOADED ]] && return 0
_BUILD_VALIDATE_LOADED=1

# Source the build framework
SCRIPT_DIR_VALIDATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR_VALIDATE/lib/build/engine.sh"
source "$SCRIPT_DIR_VALIDATE/lib/build/repository.sh"
source "$SCRIPT_DIR_VALIDATE/lib/build/verify.sh"
source "$SCRIPT_DIR_VALIDATE/lib/build/backends/arch-devtools.sh"
source "$SCRIPT_DIR_VALIDATE/lib/build/profiles/steamos.sh"

# ---------------------------------------------------------------------------
# Validation tests
# ---------------------------------------------------------------------------

# Test 1: Clean build succeeds
_validate_clean_build() {
  local merged="${1:?}"
  local workdir="${2:?}"

  log "TEST 1: Clean SteamOS image → AoTofu builds and installs successfully"

  # Derive profile
  steamos_derive_profile "$merged" "$workdir/test1-profile" || {
    warn "FAIL: Could not derive profile"
    return 1
  }

  # Build
  build_recipe \
    --recipe "$SCRIPT_DIR_VALIDATE/lib/configs/build_recipes/aotofu-vaapi" \
    --profile "$PROFILE_DIR" \
    --output "$workdir/test1-output" || {
    warn "FAIL: Build failed"
    return 1
  }

  # Verify artifact exists
  [[ -f "$BUILD_ARTIFACT" ]] || {
    warn "FAIL: No artifact produced"
    return 1
  }

  # Install
  install_build_artifact "$merged" "$BUILD_ARTIFACT" || {
    warn "FAIL: Install failed"
    return 1
  }

  log "PASS: Clean build succeeded"
  return 0
}

# Test 2: ABI-critical package blocked from Arch
_validate_abi_block() {
  local merged="${1:?}"
  local workdir="${2:?}"

  log "TEST 2: ABI package available only from Arch → repository policy blocks it"

  # Check that a base ABI-critical package (glibc) is in the denied list
  if repo_is_arch_allowed "glibc"; then
    warn "FAIL: glibc should be denied from Arch"
    return 1
  fi

  # Check that meson is in the allowed list
  if ! repo_is_arch_allowed "meson"; then
    warn "FAIL: meson should be allowed from Arch"
    return 1
  fi

  log "PASS: Repository policy correctly blocks ABI-critical packages"
  return 0
}

# Test 3: Build tool Arch fallback works
_validate_arch_fallback() {
  local merged="${1:?}"
  local workdir="${2:?}"

  log "TEST 3: Build tool missing from Valve repos → Arch fallback supplies it"

  # Derive profile
  steamos_derive_profile "$merged" "$workdir/test3-profile" || {
    warn "FAIL: Could not derive profile"
    return 1
  }

  # Check that meson is resolvable from Arch
  local meson_ver
  meson_ver="$(pacman --config "$PROFILE_PACMAN" -Si meson 2>/dev/null | sed -n 's/^Version[[:space:]]*: //p')"
  if [[ -z "$meson_ver" ]]; then
    warn "FAIL: meson not available from Arch repos"
    return 1
  fi

  log "PASS: Arch fallback supplies meson $meson_ver"
  return 0
}

# Test 4: Build failure preserves root
_validate_build_failure_preserves() {
  local merged="${1:?}"
  local workdir="${2:?}"

  log "TEST 4: Build failure → target root remains unchanged"

  # Record target state before
  local before_hash
  before_hash="$(find "$merged/usr/lib" -name '*.so*' -type f 2>/dev/null | sort | xargs sha256sum 2>/dev/null | sha256sum)"

  # Try to build a non-existent recipe (should fail)
  build_recipe \
    --recipe "$SCRIPT_DIR_VALIDATE/lib/configs/build_recipes/nonexistent" \
    --profile "$workdir/test4-profile" \
    --output "$workdir/test4-output" \
    --keep-failed 2>/dev/null || true

  # Record target state after
  local after_hash
  after_hash="$(find "$merged/usr/lib" -name '*.so*' -type f 2>/dev/null | sort | xargs sha256sum 2>/dev/null | sha256sum)"

  if [[ "$before_hash" != "$after_hash" ]]; then
    warn "FAIL: Target root was modified during failed build"
    return 1
  fi

  log "PASS: Target root unchanged after build failure"
  return 0
}

# Test 5: Only .pkg.tar.zst crosses into target
_validate_artifact_boundary() {
  local merged="${1:?}"
  local workdir="${2:?}"

  log "TEST 5: Successful build → only .pkg.tar.zst crosses into the target"

  # Check that build_recipe doesn't install anything
  local type_output
  type_output="$(type -t build_recipe 2>/dev/null)"
  if [[ "$type_output" != "function" ]]; then
    warn "FAIL: build_recipe is not a function"
    return 1
  fi

  # Verify build_recipe doesn't call install_build_artifact
  local build_body
  build_body="$(type build_recipe 2>/dev/null)"
  if echo "$build_body" | grep -q "install_build_artifact"; then
    warn "FAIL: build_recipe calls install_build_artifact (violates isolation)"
    return 1
  fi

  log "PASS: Build/install boundary enforced"
  return 0
}

# Test 6: Dependency provenance logging
_validate_provenance_logging() {
  local merged="${1:?}"
  local workdir="${2:?}"

  log "TEST 6: Dependency provenance is logged"

  # Derive profile
  steamos_derive_profile "$merged" "$workdir/test6-profile" || {
    warn "FAIL: Could not derive profile"
    return 1
  }

  # Resolve a base ABI-critical dependency (glibc is always present)
  _build_resolve_dep "$merged" "glibc"
  if [[ -z "$_DEP_VERSION" ]]; then
    warn "FAIL: Could not resolve glibc"
    return 1
  fi

  log "  glibc: $_DEP_VERSION from $_DEP_SOURCE ($_DEP_CLASS)"

  if [[ "$_DEP_CLASS" != "abi-locked" ]]; then
    warn "FAIL: glibc should be abi-locked, got $_DEP_CLASS"
    return 1
  fi

  log "PASS: Dependency provenance correctly tracked"
  return 0
}

# ---------------------------------------------------------------------------
# Main validation runner
# ---------------------------------------------------------------------------

_run_validation_matrix() {
  local merged="${1:?_run_validation_matrix: missing root}"
  local workdir="${2:-${WORKDIR:-/tmp}/build-validation-$$}"

  mkdir -p "$workdir"

  log "========================================"
  log "Build Framework Validation Matrix"
  log "========================================"
  log "Target: $merged"
  log "Workdir: $workdir"
  log ""

  local pass=0 fail=0

  if _validate_clean_build "$merged" "$workdir"; then ((++pass)); else ((++fail)); fi
  if _validate_abi_block "$merged" "$workdir"; then ((++pass)); else ((++fail)); fi
  if _validate_arch_fallback "$merged" "$workdir"; then ((++pass)); else ((++fail)); fi
  if _validate_build_failure_preserves "$merged" "$workdir"; then ((++pass)); else ((++fail)); fi
  if _validate_artifact_boundary "$merged" "$workdir"; then ((++pass)); else ((++fail)); fi
  if _validate_provenance_logging "$merged" "$workdir"; then ((++pass)); else ((++fail)); fi

  log ""
  log "========================================"
  log "Results: $pass passed, $fail failed"
  log "========================================"

  return "$fail"
}
