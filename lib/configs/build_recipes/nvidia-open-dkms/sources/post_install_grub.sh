#!/bin/bash
#
# post_install_grub.sh — Host-side post-install hook for nvidia-open-dkms recipe.
# Adds NVIDIA kernel cmdline parameters to grub-steamos and EFI grub.cfg.
# Runs OUTSIDE the chroot on the host.
#
# Uses library-loader + load_workflow_libs for initialization so grub.sh (and
# its dependencies like common.sh's log()) are sourced through the canonical
# path — no local copy of grub.sh is bundled.
#
set -euo pipefail

echo "=== NVIDIA post-install: adding grub parameters ==="

# ── 1. Validate required environment ──────────────────────────────────────
# SCRIPT_DIR and MERGED are set by install-hw-libs.sh when invoking
# POST_INSTALL hooks.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
  echo "ERROR: SCRIPT_DIR is not set" >&2
  exit 1
fi

if [[ -z "${MERGED:-}" ]]; then
  echo "ERROR: MERGED is not set" >&2
  exit 1
fi

# ── 2. Source the project's library loader ────────────────────────────────
# load_workflow_libs loads grub.sh (and its dependency common.sh) via the
# repo's lib/ directory — no local copy is needed.
source "$SCRIPT_DIR/lib/library-loader.sh" # lint-ignore: single-source
load_workflow_libs "build" "$SCRIPT_DIR/lib"

# ── 3. Patch grub-steamos with NVIDIA kernel parameters ──────────────────
GRUB_FILE="$MERGED/etc/default/grub-steamos"

if [[ ! -f "$GRUB_FILE" ]]; then
  echo "ERROR: grub-steamos not found at $GRUB_FILE" >&2
  exit 1
fi

# NVIDIA_CMDLINE_ADD is defined by common_drivers.sh (loaded via the loader).
# Add each parameter idempotently — add_params_to_grub_steamos skips
# parameters that are already present.
# shellcheck disable=SC2086  # word splitting intentional: each param is a separate arg
add_params_to_grub_steamos "$GRUB_FILE" $NVIDIA_CMDLINE_ADD

# ── 4. Patch EFI grub.cfg with NVIDIA kernel parameters ──────────────────
# When EFIMNT is available and the EFI grub.cfg exists, idempotently add the
# same NVIDIA parameters to the EFI grub.cfg kernel lines so the recipe owns
# both grub-steamos and EFI cmdline params.
if [[ -n "${EFIMNT:-}" && -f "$EFIMNT/EFI/steamos/grub.cfg" ]]; then
  echo "Patching EFI grub.cfg at $EFIMNT/EFI/steamos/grub.cfg"
  # shellcheck disable=SC2086  # word splitting intentional: each param is a separate arg
  add_params_to_efi_grub_cfg "$EFIMNT/EFI/steamos/grub.cfg" $NVIDIA_CMDLINE_ADD
elif [[ -n "${EFIMNT:-}" ]]; then
  echo "EFI grub.cfg not found at $EFIMNT/EFI/steamos/grub.cfg — skipping EFI write"
fi

echo "=== NVIDIA post-install completed ==="
