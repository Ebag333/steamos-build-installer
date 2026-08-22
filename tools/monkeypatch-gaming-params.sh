#!/bin/bash
#
# monkeypatch-gaming-params.sh — fix missing gaming kernel params on a running
# steamos-nvidia system, and patch the self-heal repatch script so future
# OS updates also get the fix.
#
# Run as root on the affected device:
#   sudo bash tools/monkeypatch-gaming-params.sh
#
set -euo pipefail

# ── Params to ensure are present ──────────────────────────────────────────────

GAMING_PARAMS=(
  "pci=realloc=on"
  "thunderbolt.host_reset=0"
  "nvidia.NVreg_EnableResizableBar=1"
)

# ── Helpers ───────────────────────────────────────────────────────────────────

die()  { echo "FATAL: $*" >&2; exit 1; }
log()  { echo "  $*"; }
ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; }

# ── Multiline grub-steamos helpers ────────────────────────────────────────────
# SteamOS uses multiline GRUB_CMDLINE_LINUX with backslash continuations.
# Simple sed on the first line does nothing.

# Read the full value of GRUB_CMDLINE_LINUX, joining continuation lines.
_read_grub_steamos_value() {
  local file="$1"
  local full_value="" in_block=0 line
  while IFS= read -r line; do
    if [[ "$line" =~ ^GRUB_CMDLINE_LINUX= ]]; then
      in_block=1
      line="${line#GRUB_CMDLINE_LINUX=\"}"
    elif [[ $in_block -eq 0 ]]; then
      continue
    fi
    if [[ $in_block -eq 1 ]]; then
      if [[ "$line" == *\\ ]]; then
        line="${line%\\}"
        full_value+="$line "
      else
        line="${line%\"*}"
        line="${line%"${line##*[![:space:]]}"}"
        full_value+="$line"
        break
      fi
    fi
  done < "$file"
  echo "$full_value"
}

# Add params to a multiline grub-steamos file.
_add_params_to_grub_steamos() {
  local file="$1"; shift
  local params_to_add=("$@")

  local current_value
  current_value="$(_read_grub_steamos_value "$file")"

  local last_line_num
  last_line_num="$(awk '
    /^GRUB_CMDLINE_LINUX=/ { found=1 }
    found && /[^\\]"$/ { print NR; exit }
  ' "$file")"

  [[ -z "$last_line_num" ]] && { fail "Could not find end of GRUB_CMDLINE_LINUX block"; return 1; }

  local param
  for param in "${params_to_add[@]}"; do
    if ! echo " $current_value " | grep -qF " $param "; then
      log "Adding $param to grub-steamos"
      sed -i "${last_line_num}s|\"$| \\\\|" "$file"
      sed -i "${last_line_num}a\\  ${param} \"" "$file"
      current_value+=" $param"
      last_line_num=$((last_line_num + 1))
    else
      ok "$param already in grub-steamos"
    fi
  done
}

# ── Sanity checks ─────────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || die "Run as root."

GRUB_CFG=""
for candidate in /efi/EFI/steamos/grub.cfg /esp/EFI/steamos/grub.cfg; do
  [[ -f "$candidate" ]] && { GRUB_CFG="$candidate"; break; }
done
[[ -n "$GRUB_CFG" ]] || die "EFI grub.cfg not found (checked /efi and /esp)"

GRUB_DEFAULT="/etc/default/grub"
GRUB_STEAMOS="/etc/default/grub-steamos"
REPATCH="/usr/lib/steamos-nvidia/repatch.sh"
DRIVER_CONF="/usr/lib/steamos-nvidia/driver.conf"

echo
echo "Monkeypatching gaming kernel params"
echo "────────────────────────────────────────────────────────────"
echo "  grub.cfg:     $GRUB_CFG"
echo "  grub default: $GRUB_DEFAULT"
echo "  grub-steamos: $GRUB_STEAMOS"
echo "  repatch.sh:   $REPATCH"
echo "  driver.conf:  $DRIVER_CONF"
echo "────────────────────────────────────────────────────────────"
echo

# ── 1. Show current state ─────────────────────────────────────────────────────

echo "Current kernel cmdline (from /proc/cmdline):"
CMDLINE=$(cat /proc/cmdline)
for param in "${GAMING_PARAMS[@]}"; do
  if echo " $CMDLINE " | grep -qF " $param "; then
    ok "$param"
  else
    fail "$param (MISSING)"
  fi
done
echo

# ── 2. Patch grub.cfg ────────────────────────────────────────────────────────

echo "Patching $GRUB_CFG ..."
for param in "${GAMING_PARAMS[@]}"; do
  if grep 'steamenv_boot.*linux.*/boot/vmlinuz' "$GRUB_CFG" 2>/dev/null \
       | grep -qF -- "$param"; then
    ok "$param on kernel line"
  elif grep -qF -- "$param" "$GRUB_CFG" 2>/dev/null; then
    ok "$param in grub.cfg (non-kernel line)"
  else
    log "Adding $param to grub.cfg"
    sed -i -E \
      's#(steamenv_boot[[:space:]]+linux[[:space:]]+/boot/vmlinuz[^\n]*)#\1 '"$param"'#' \
      "$GRUB_CFG"
    if grep -qF -- "$param" "$GRUB_CFG"; then
      ok "$param added to grub.cfg"
    else
      fail "$param — sed failed (grub.cfg format may differ)"
    fi
  fi
done
echo

# ── 3. Patch /etc/default/grub ────────────────────────────────────────────────

if [[ -f "$GRUB_DEFAULT" ]]; then
  echo "Patching $GRUB_DEFAULT ..."
  for param in "${GAMING_PARAMS[@]}"; do
    local_value="$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_DEFAULT" 2>/dev/null || true)"
    local_value="${local_value#*\"}"
    local_value="${local_value%\"*}"
    if echo " $local_value " | grep -qF " $param "; then
      ok "$param in GRUB_CMDLINE_LINUX_DEFAULT"
    else
      log "Adding $param to GRUB_CMDLINE_LINUX_DEFAULT"
      sed -i -E "s#^(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*)#\1 $param#" "$GRUB_DEFAULT"
      ok "$param added"
    fi
  done
  echo
else
  echo "Skipping $GRUB_DEFAULT (not found)"
  echo
fi

# ── 4. Patch grub-steamos (multiline-aware) ───────────────────────────────────

if [[ -f "$GRUB_STEAMOS" ]]; then
  echo "Patching $GRUB_STEAMOS (multiline-aware) ..."
  _add_params_to_grub_steamos "$GRUB_STEAMOS" "${GAMING_PARAMS[@]}"

  # Ensure atomic-update keep-list persists grub-steamos across A/B updates
  KEEP_DIR="/etc/atomic-update.conf.d"
  KEEP_FILE="$KEEP_DIR/steamos-nvidia-installer.conf"
  if [[ -d "$KEEP_DIR" ]]; then
    if ! grep -q '/etc/default/grub-steamos' "$KEEP_FILE" 2>/dev/null; then
      mkdir -p "$KEEP_DIR"
      echo "/etc/default/grub-steamos" >> "$KEEP_FILE"
      ok "Added grub-steamos to atomic-update keep-list"
    else
      ok "grub-steamos already in atomic-update keep-list"
    fi
  else
    echo "  ⚠ $KEEP_DIR not found — grub-steamos may not persist across updates"
  fi
  echo
else
  echo "Skipping $GRUB_STEAMOS (not found)"
  echo
fi

# ── 5. Patch driver.conf — store resolved params as EXTRA_CMDLINE_ADD ─────────

if [[ -f "$DRIVER_CONF" ]]; then
  echo "Patching $DRIVER_CONF ..."

  # Build the canonical param string
  params_str="${GAMING_PARAMS[*]}"

  if grep -q '^EXTRA_CMDLINE_ADD=' "$DRIVER_CONF"; then
    current="$(grep '^EXTRA_CMDLINE_ADD=' "$DRIVER_CONF" | head -1 | sed 's/EXTRA_CMDLINE_ADD="//;s/"//')"
    # Merge, dedup
    merged="$current $params_str"
    merged="$(echo "$merged" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')"
    merged="${merged% }"
    sed -i "s|^EXTRA_CMDLINE_ADD=.*|EXTRA_CMDLINE_ADD=\"$merged\"|" "$DRIVER_CONF"
    ok "EXTRA_CMDLINE_ADD updated: $merged"
  else
    log "Adding EXTRA_CMDLINE_ADD to driver.conf"
    sed -i '/^DEBUG_BOOT=/a EXTRA_CMDLINE_ADD="'"$params_str"'"' "$DRIVER_CONF"
    ok "EXTRA_CMDLINE_ADD added: $params_str"
  fi
  echo
else
  echo "Skipping $DRIVER_CONF (not found)"
  echo
fi

# ── 6. Patch repatch.sh — ensure correct GRUB ordering ────────────────────────

if [[ -f "$REPATCH" ]]; then
  echo "Checking $REPATCH GRUB ordering ..."

  # The correct order is: patch_persistent_defaults → update-grub → patch_kernel_cmdline → finalize_grub
  # If repatch.sh has the old pattern (update-grub before patch_kernel_cmdline without patch_persistent_defaults),
  # we need to fix it.
  content="$(cat "$REPATCH")"

  if echo "$content" | grep -q 'patch_persistent_defaults'; then
    ok "repatch.sh already uses patch_persistent_defaults"
  elif echo "$content" | grep -q 'DRIVER_NEEDS_REBUILD'; then
    ok "repatch.sh already uses DRIVER_NEEDS_REBUILD"
    # But might need the GRUB ordering fix
    if echo "$content" | grep -q 'patch_persistent_defaults'; then
      ok "repatch.sh GRUB ordering correct"
    else
      log "Patching repatch.sh GRUB section — adding patch_persistent_defaults"
      # Replace the old GRUB section with the new phased approach
      python3 - "$REPATCH" <<'PYEOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    content = f.read()

old_block = """# Attempt update-grub, then patch_kernel_cmdline guarantees every param
# is present in the EFI grub.cfg regardless of whether update-grub succeeded.
chroot "$NEWROOT" update-grub 2>/dev/null \\
  || log "update-grub failed — grub.sh will patch EFI grub.cfg directly"

patch_kernel_cmdline
finalize_grub"""

new_block = """# Phase 1: write all params to persistent defaults FIRST.
patch_persistent_defaults

# Phase 2: regenerate grub.cfg from persistent defaults (best-effort).
log "Attempting update-grub (non-fatal if it fails)"
chroot "$NEWROOT" update-grub 2>/dev/null \\
  || log "update-grub failed — will patch EFI grub.cfg directly"

# Phase 3: authoritative direct patch of EFI grub.cfg.
patch_kernel_cmdline

# Phase 4: validate everything landed.
finalize_grub"""

if old_block in content:
    content = content.replace(old_block, new_block)
    with open(path, 'w') as f:
        f.write(content)
    print("  ✓ repatch.sh GRUB section updated")
else:
    print("  ⚠ Could not find old GRUB pattern — manual check needed")
PYEOF
    fi
  else
    log "repatch.sh has old format — needs full update from repo"
    echo "  ⚠ Copy the updated lib/repatch.sh to $REPATCH"
  fi
  echo
else
  echo "Skipping $REPATCH (not found)"
  echo
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo "────────────────────────────────────────────────────────────"
echo "Done. Changes applied to:"
echo "  - $GRUB_CFG"
[[ -f "$GRUB_DEFAULT" ]]   && echo "  - $GRUB_DEFAULT"
[[ -f "$GRUB_STEAMOS" ]]   && echo "  - $GRUB_STEAMOS"
[[ -f "$DRIVER_CONF" ]]    && echo "  - $DRIVER_CONF"
[[ -f "$REPATCH" ]]        && echo "  - $REPATCH"
echo
echo "Reboot to pick up the new params. After reboot, verify with:"
echo "  cat /proc/cmdline | tr ' ' '\\n' | grep -E 'pci=|thunderbolt|NVreg'"
echo "────────────────────────────────────────────────────────────"
