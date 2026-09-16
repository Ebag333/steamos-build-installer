#!/bin/bash
#
# compare-repo-versions.sh — Compare package versions between Valve and Arch repos.
#
# Modes:
#   (default)     Compare Valve repo versions vs Arch repo versions for hw-packages
#   --upgrades    Show what would upgrade on your system if you switched to Arch repos
#
# Usage: ./tools/compare-repo-versions.sh [--upgrades]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HW_PACKAGES_CONF="$REPO_ROOT/lib/configs/hw-packages.conf"
ARCH_PACMAN_CONF="$REPO_ROOT/lib/configs/pacman-arch.conf"

ARCH_DBPATH="/var/lib/pacman-arch"

MODE="compare"
[[ "${1:-}" == "--upgrades" ]] && MODE="upgrades"

for f in "$HW_PACKAGES_CONF" "$ARCH_PACMAN_CONF"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: Required config not found: $f" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Extract package names from hw-packages.conf filtered by TYPE.
# ---------------------------------------------------------------------------
_extract_packages() {
  local conf="$1"
  local type_filter="$2"
  awk -F'|' -v t="$type_filter" '!/^\s*(#|$)/ && $1 == t {print $2}' "$conf" | sort -u
}

# ---------------------------------------------------------------------------
# Query a package version from a repo.
#   $1 = package name
#   $2 = "" for system repos, or "--config <path> --dbpath <path>" for Arch
#
# Prints "version" or "NOT FOUND".
# ---------------------------------------------------------------------------
_query_version() {
  local pkg="$1"
  local extra_args="${2:-}"
  local raw

  if [[ -n "$extra_args" ]]; then
    # shellcheck disable=SC2086 # extra_args is intentionally word-split
    raw=$(pacman $extra_args -Si "$pkg" 2>&1) || true
  else
    raw=$(pacman -Si "$pkg" 2>&1) || true
  fi

  if ! echo "$raw" | grep -q '^Version'; then
    echo "NOT FOUND"
  else
    echo "$raw" | awk -F': ' '/^Version/ {print $2; exit}'
  fi
}

# ---------------------------------------------------------------------------
# Sync Arch databases into isolated dbpath
# ---------------------------------------------------------------------------
echo "Syncing Arch databases to $ARCH_DBPATH..."
sudo mkdir -p "$ARCH_DBPATH"
sudo pacman --config "$ARCH_PACMAN_CONF" --dbpath "$ARCH_DBPATH" -Sy
echo ""

# ---------------------------------------------------------------------------
# Mode: compare — Valve repo vs Arch repo for hw-packages
# ---------------------------------------------------------------------------
if [[ "$MODE" == "compare" ]]; then
  mapfile -t packages < <(
    {
      _extract_packages "$HW_PACKAGES_CONF" "pacman"
    } | sort -u
  )

  if [[ ${#packages[@]} -eq 0 ]]; then
    echo "No packages found in config files." >&2
    exit 1
  fi

  echo "Comparing ${#packages[@]} packages between Valve and Arch repos..."
  echo "Valve: system pacman repos"
  echo "Arch:  $ARCH_PACMAN_CONF (dbpath: $ARCH_DBPATH)"
  echo ""

  printf "%-35s %-22s %-22s %s\n" "PACKAGE" "VALVE" "ARCH" "STATUS"
  printf "%-35s %-22s %-22s %s\n" "-------" "-----" "----" "------"

  same=0
  different=0
  valve_only=0
  arch_only=0
  both_missing=0

  for pkg in "${packages[@]}"; do
    valve_ver=$(_query_version "$pkg")
    arch_ver=$(_query_version "$pkg" "--config $ARCH_PACMAN_CONF --dbpath $ARCH_DBPATH")

    if [[ "$valve_ver" == "NOT FOUND" && "$arch_ver" == "NOT FOUND" ]]; then
      status="BOTH MISSING"
      ((++both_missing)) || true
    elif [[ "$valve_ver" == "NOT FOUND" ]]; then
      status="ARCH ONLY"
      ((++arch_only)) || true
    elif [[ "$arch_ver" == "NOT FOUND" ]]; then
      status="VALVE ONLY"
      ((++valve_only)) || true
    elif [[ "$valve_ver" == "$arch_ver" ]]; then
      status="SAME"
      ((++same)) || true
    else
      status="DIFFERENT"
      ((++different)) || true
    fi

    printf "%-35s %-22s %-22s %s\n" "$pkg" "$valve_ver" "$arch_ver" "$status"
  done

  echo ""
  echo "=== Summary ==="
  echo "Total packages:  ${#packages[@]}"
  echo "Same version:    $same"
  echo "Different:       $different"
  echo "Valve only:      $valve_only"
  echo "Arch only:       $arch_only"
  echo "Both missing:    $both_missing"

# ---------------------------------------------------------------------------
# Mode: upgrades — what would upgrade if you switched to Arch repos
# ---------------------------------------------------------------------------
elif [[ "$MODE" == "upgrades" ]]; then
  echo "Checking installed packages against Arch repos..."
  echo ""

  printf "%-35s %-22s %-22s %s\n" "PACKAGE" "INSTALLED" "ARCH" "UPGRADE"
  printf "%-35s %-22s %-22s %s\n" "-------" "---------" "----" "-------"

  upgrades=0
  up_to_date=0
  not_in_arch=0

  while IFS=' ' read -r pkg installed_ver; do
    arch_ver=$(_query_version "$pkg" "--config $ARCH_PACMAN_CONF --dbpath $ARCH_DBPATH")

    if [[ "$arch_ver" == "NOT FOUND" ]]; then
      printf "%-35s %-22s %-22s %s\n" "$pkg" "$installed_ver" "NOT IN ARCH" "-"
      ((++not_in_arch)) || true
      continue
    fi

    if [[ "$installed_ver" == "$arch_ver" ]]; then
      ((++up_to_date)) || true
      continue
    fi

    # Use vercmp to determine if Arch version is actually newer
    cmp=$(vercmp "$installed_ver" "$arch_ver" 2>/dev/null || echo "0")
    if [[ "$cmp" -lt 0 ]]; then
      printf "%-35s %-22s %-22s %s\n" "$pkg" "$installed_ver" "$arch_ver" "YES"
      ((++upgrades)) || true
    else
      ((++up_to_date)) || true
    fi
  done < <(pacman -Q 2>/dev/null)

  echo ""
  echo "=== Summary ==="
  echo "Would upgrade:   $upgrades"
  echo "Up to date:      $up_to_date"
  echo "Not in Arch:     $not_in_arch"
fi
