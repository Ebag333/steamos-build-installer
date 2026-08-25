# Build Framework

Clean-room build framework for steamos-nvidia-installer.

## Core Principle

> **Nothing compiles in the target OS. Every build happens in a disposable build root and produces a pacman package as its artifact.**

## Architecture

```
lib/build/
├── engine.sh          # Main build engine
├── profile.sh         # Profile management
├── repository.sh      # Repository policy enforcement
├── artifact.sh        # Artifact handling
├── verify.sh          # Package verification
├── backends/
│   └── arch-devtools.sh  # mkarchroot/makechrootpkg backend
└── profiles/
    └── steamos.sh     # SteamOS-specific profile handling

recipes/
├── aotofu-vaapi/
│   ├── recipe.conf
│   └── PKGBUILD
└── ...
```

## Concepts

### Profile

Describes the target environment (OS, ABI, repositories).

```bash
build_profile_from_root "$MERGED"
```

### Recipe

Describes what to build (source, dependencies, verification).

```
recipes/aotofu-vaapi/
├── recipe.conf    # Framework metadata
└── PKGBUILD       # Arch package specification
```

### Backend

Isolates the build from the host and target.

- `arch-devtools`: Uses `mkarchroot`/`makechrootpkg` for clean builds

### Artifact

The output of a build: a `.pkg.tar.zst` package.

## Usage

### Build a recipe

```bash
# Derive profile from target image
build_profile_from_root "$MERGED"

# Build the recipe
build_recipe \
    --recipe "$SCRIPT_DIR/recipes/aotofu-vaapi" \
    --profile "$PROFILE_DIR" \
    --output "$WORKDIR/packages"

# The artifact is in BUILD_ARTIFACT
echo "Built: $BUILD_ARTIFACT"
```

### Install an artifact

```bash
install_build_artifact "$MERGED" "$BUILD_ARTIFACT"
```

### Keep failed builds for debugging

```bash
build_recipe \
    --recipe "$SCRIPT_DIR/recipes/aotofu-vaapi" \
    --profile "$PROFILE_DIR" \
    --keep-failed
```

## Repository Policy

The framework enforces which packages can come from Arch repos:

- **Allowed**: Build tools (meson, ninja, cmake, git, etc.)
- **Denied**: ABI-critical libraries (glibc, libdrm, libva, mesa, etc.)

This prevents cross-distro contamination while allowing build tools to be installed.

## Verification

Every artifact is verified:

1. Package metadata is valid
2. ABI compatibility with the target
3. SHA256 checksum

## Adding a New Recipe

1. Create a directory under `recipes/`
2. Add `recipe.conf` with metadata
3. Add `PKGBUILD` with build instructions
4. The framework handles everything else

## Testing

### End-to-End Test

Run the AoTofu end-to-end test against a SteamOS image:

```bash
./test-aotofu-e2e.sh /path/to/steamdeck-oobe-repair.img
```

This validates:
1. Profile derivation from the target image
2. Clean-room build (target unchanged during compilation)
3. ABI-critical package handling (libdrm version mismatch)
4. Arch fallback for build tools
5. Artifact verification and installation

### Validation Matrix

Run the full validation matrix:

```bash
source lib/build/validate.sh
run_validation_matrix "$MERGED"
```

This tests all failure modes:
- Clean build succeeds
- ABI-critical packages blocked from Arch
- Build tool Arch fallback works
- Build failure preserves target root
- Only .pkg.tar.zst crosses into target
- Dependency provenance tracked correctly
