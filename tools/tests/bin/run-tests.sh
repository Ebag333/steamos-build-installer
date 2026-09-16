#!/bin/bash
#
# Minimal test runner: build + validate every *.conf against a source image.
#
# Usage: ./tools/tests/bin/run-tests.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="$SCRIPT_DIR/.."
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
STEAMOS_BUILD="$PROJECT_DIR/steamos-build.sh"
BUILD_DIR="$CONF_DIR/build"
OUTPUT_DIR="$CONF_DIR/output"

# Base image — from run-tests.conf
source "$SCRIPT_DIR/run-tests.conf"
SOURCE_IMG="${SOURCE_IMG:?SOURCE_IMG not set in run-tests.conf}"

# Derive output image name: <basename_without_ext>-nvidia-usbinstall.img
SOURCE_BASE="$(basename "$SOURCE_IMG")"
SOURCE_BASE="${SOURCE_BASE%.bz2}"
SOURCE_BASE="${SOURCE_BASE%.gz}"
SOURCE_BASE="${SOURCE_BASE%.xz}"
SOURCE_BASE="${SOURCE_BASE%.zst}"
SOURCE_BASE="${SOURCE_BASE%.img}"
OUT_IMG="$BUILD_DIR/${SOURCE_BASE}-nvidia-usbinstall.img"

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

passed=0
failed=0

for conf in "$CONF_DIR"/*.conf; do
  [[ -f "$conf" ]] || continue
  [[ "$(basename "$conf")" == "run-tests.conf" ]] && continue

  name="$(basename "$conf" .conf)"
  json="$OUTPUT_DIR/${name}.json"

  echo ""
  echo "--- $name ---"

  # Clean stale state from previous runs
  cd "$PROJECT_DIR"
  sudo "$STEAMOS_BUILD" --action cleanup --purge || true

  # ── Build ────────────────────────────────────────────────────────────
  if sudo "$STEAMOS_BUILD" \
    --action build \
    --image "$SOURCE_IMG" \
    --config "$conf" \
    --output-dir "$BUILD_DIR"; then
    echo "  Build OK"
  else
    echo "  BUILD FAILED"
    ((++failed))
    continue
  fi

  # Verify output image exists
  if [[ ! -f "$OUT_IMG" ]]; then
    echo "  Output image not found: $OUT_IMG"
    ((++failed))
    continue
  fi

  # ── Validate ─────────────────────────────────────────────────────────
  if sudo "$STEAMOS_BUILD" \
    --action validate \
    --image "$OUT_IMG" \
    --config "$conf" \
    --output "$json"; then
    echo "  Validate OK -> $json"
    ((++passed))
  else
    echo "  VALIDATION FAILED"
    ((++failed))
  fi

  # ── Cleanup ──────────────────────────────────────────────────────────
  sudo "$STEAMOS_BUILD" --action cleanup --purge
done

echo ""
echo "Results: $passed passed, $failed failed"

[[ $failed -eq 0 ]]
