#!/bin/bash
#
# Example: Using the build framework
#
# This shows how to integrate the clean-room build framework
# into the existing installer workflow.

# Source the build framework
source "$SCRIPT_DIR/lib/build/engine.sh"
source "$SCRIPT_DIR/lib/build/repository.sh"
source "$SCRIPT_DIR/lib/build/verify.sh"
source "$SCRIPT_DIR/lib/build/backends/arch-devtools.sh"
source "$SCRIPT_DIR/lib/build/profiles/steamos.sh"

# Example 1: Build AoTofu using the framework
build_aotofu_with_framework() {
  local workdir="${1:?}"
  local merged="${2:?}"

  # Step 1: Derive a build profile from the target image
  log "Deriving build profile from target image"
  steamos_derive_profile "$merged" "$workdir/profile"

  # Step 2: Build the recipe
  log "Building AoTofu VA-API driver"
  build_recipe \
    --recipe "$SCRIPT_DIR/configs/build_recipes/aotofu-vaapi" \
    --profile "$PROFILE_DIR" \
    --output "$workdir/packages" \
    --keep-failed

  # Step 3: Install the artifact
  log "Installing AoTofu into target"
  install_build_artifact "$merged" "$BUILD_ARTIFACT"

  log "AoTofu build complete"
}

# Example 2: Build with custom options
build_custom_package() {
  local recipe="${1:?}"
  local merged="${2:?}"
  local output="${3:?}"

  # Derive profile
  build_profile_from_root "$merged"

  # Build with keep-failed for debugging
  build_recipe \
    --recipe "$recipe" \
    --profile "$PROFILE_DIR" \
    --output "$output" \
    --keep-failed || {
    warn "Build failed — check $output for details"
    return 1
  }

  # Verify the artifact
  verify_package_inspect "$BUILD_ARTIFACT"

  # Install
  install_build_artifact "$merged" "$BUILD_ARTIFACT"
}

# Example 3: Check repository policy
check_repo_policy() {
  local merged="${1:?}"
  local -a packages=(meson ninja glibc gcc-libs)

  log "Checking repository policy for: ${packages[*]}"

  for pkg in "${packages[@]}"; do
    if repo_is_arch_allowed "$pkg"; then
      log "  $pkg: allowed from Arch"
    else
      log "  $pkg: must come from target"
    fi
  done
}
