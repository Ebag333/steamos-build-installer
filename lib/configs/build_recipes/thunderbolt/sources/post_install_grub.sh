#!/bin/bash
#
# post_install_grub.sh — Host-side post-install hook for Thunderbolt recipe.
# Adds thunderbolt.host_reset=0 to grub-steamos kernel parameters.
# Runs OUTSIDE the chroot on the host.
#
# Uses library-loader + load_workflow_libs for initialization so grub.sh (and
# its dependencies like common.sh's log()) are sourced through the canonical
# path — no local copy of grub.sh is bundled.
#
set -euo pipefail

echo "=== Thunderbolt post-install: adding grub parameter ==="

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
source "$SCRIPT_DIR/lib/library-loader.sh"
load_workflow_libs "build" "$SCRIPT_DIR/lib"

# ── 3. Patch grub-steamos with Thunderbolt kernel parameters ─────────────
GRUB_FILE="$MERGED/etc/default/grub-steamos"

if [[ ! -f "$GRUB_FILE" ]]; then
  echo "ERROR: grub-steamos not found at $GRUB_FILE" >&2
  exit 1
fi

_add_params_to_grub_steamos "$GRUB_FILE" "thunderbolt.host_reset=0"

echo "=== Thunderbolt post-install completed ==="
