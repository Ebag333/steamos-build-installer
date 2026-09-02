#!/usr/bin/env bash
set -euo pipefail

# pacman-provenance-audit.sh
#
# Compare installed SteamOS packages against:
#   1. Current Valve-configured repositories
#   2. A separate upstream Arch pacman configuration
#
# Default output is CSV for easy parsing. JSON, TSV, and a human-readable
# table are also available.
#
# Examples:
#   ./pacman-provenance-audit.sh \
#       --arch-conf /path/to/pacman-arch.conf > packages.csv
#
#   ./pacman-provenance-audit.sh \
#       --arch-conf /path/to/pacman-arch.conf \
#       --format json > packages.json
#
#   ./pacman-provenance-audit.sh \
#       --arch-conf /path/to/pacman-arch.conf \
#       --format table mesa libva systemd

ARCH_CONF=""
FORMAT="csv"
HAVE_BASE_SET=0

usage() {
  cat <<'EOF_USAGE'
Usage:
  pacman-provenance-audit.sh --arch-conf FILE [OPTIONS] [PACKAGE...]

Options:
  --arch-conf FILE      pacman.conf configured for upstream Arch repositories
  --format FORMAT       Output format: csv, json, tsv, or table (default: csv)
  --csv                 Alias for --format csv
  --json                Alias for --format json
  --tsv                 Alias for --format tsv
  --table               Alias for --format table
  -h, --help            Show this help

With no PACKAGE arguments, all installed packages are examined.

Source classes:
  SHARED_UPSTREAM          Valve core/extra/multilib and Arch both provide it
  VALVE_PLATFORM_OVERRIDE Valve holo/jupiter and Arch both provide it
  VALVE_PLATFORM_ONLY     Valve holo/jupiter only
  VALVE_BASE_REPO_ONLY    Valve core/extra/multilib only
  SHARED_OTHER            Other Valve repo and Arch both provide it
  VALVE_OTHER_ONLY        Other Valve repo only
  ARCH_ONLY               Only upstream Arch currently provides it
  LOCAL_ONLY              Installed, but in neither current repository universe

Important:
  Repository availability is current-state metadata. pacman does not reliably
  record the sync repository an already-installed package originally came from.
EOF_USAGE
}

packages=()

while (($#)); do
  case "$1" in
    --arch-conf)
      ARCH_CONF="${2:?Missing value for --arch-conf}"
      shift 2
      ;;
    --format)
      FORMAT="${2:?Missing value for --format}"
      shift 2
      ;;
    --csv)
      FORMAT="csv"
      shift
      ;;
    --json)
      FORMAT="json"
      shift
      ;;
    --tsv)
      FORMAT="tsv"
      shift
      ;;
    --table)
      FORMAT="table"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      packages+=("$@")
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      packages+=("$1")
      shift
      ;;
  esac
done

case "$FORMAT" in
  csv | json | tsv | table) ;;
  *)
    echo "ERROR: invalid output format: $FORMAT" >&2
    echo "       expected one of: csv, json, tsv, table" >&2
    exit 2
    ;;
esac

[[ -n "$ARCH_CONF" ]] || {
  echo "ERROR: --arch-conf is required" >&2
  exit 2
}

[[ -f "$ARCH_CONF" ]] || {
  echo "ERROR: Arch pacman config not found: $ARCH_CONF" >&2
  exit 2
}

for cmd in pacman pacman-conf awk sort vercmp; do
  command -v "$cmd" >/dev/null || {
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  }
done

if [[ "$FORMAT" == "json" ]] && ! command -v python3 >/dev/null; then
  echo "ERROR: --format json requires python3" >&2
  exit 1
fi

declare -A INSTALLED_VER=()
declare -A INSTALLED_PACKAGER=()
declare -A INSTALLED_REASON=()
declare -A INSTALLED_REQBY=()

declare -A VALVE_PREF_REPO=()
declare -A VALVE_PREF_VER=()
declare -A VALVE_PLATFORM_REPO=()
declare -A VALVE_PLATFORM_VER=()
declare -A VALVE_BASE_REPO=()
declare -A VALVE_BASE_VER=()
declare -A VALVE_ALL=()

declare -A ARCH_PREF_REPO=()
declare -A ARCH_PREF_VER=()
declare -A ARCH_ALL=()

declare -A BASE_SET=()

###############################################################################
# Helpers used while loading repositories
###############################################################################

is_valve_platform_repo() {
  local repo="$1"

  case "$repo" in
    holo | holo-* | jupiter | jupiter-*)
      return 0
      ;;
  esac

  return 1
}

is_valve_base_repo() {
  local repo="$1"

  case "$repo" in
    core | core-* | extra | extra-* | multilib | multilib-*)
      return 0
      ;;
  esac

  return 1
}

###############################################################################
# Installed package metadata
#
# Do one pacman -Qi for the entire system instead of spawning pacman thousands
# of times.
###############################################################################

while IFS=$'\t' read -r name ver packager reason reqby; do
  [[ -n "$name" ]] || continue

  INSTALLED_VER["$name"]="$ver"
  INSTALLED_PACKAGER["$name"]="$packager"
  INSTALLED_REASON["$name"]="$reason"
  INSTALLED_REQBY["$name"]="$reqby"
done < <(
  LC_ALL=C pacman -Qi \
    | awk '
        BEGIN {
            RS=""
            FS="\n"
            OFS="\t"
        }

        {
            # Join wrapped pacman fields onto their preceding line.
            rec=$0
            gsub(/\n[[:space:]]+/, " ", rec)

            n=split(rec, lines, "\n")

            name=""
            version=""
            packager=""
            reason=""
            required=""

            for (i=1; i<=n; i++) {
                line=lines[i]

                pos=index(line, ":")
                if (!pos)
                    continue

                key=substr(line, 1, pos-1)
                val=substr(line, pos+1)

                sub(/[[:space:]]+$/, "", key)
                sub(/^[[:space:]]+/, "", val)

                if (key == "Name")
                    name=val
                else if (key == "Version")
                    version=val
                else if (key == "Packager")
                    packager=val
                else if (key == "Install Reason")
                    reason=val
                else if (key == "Required By")
                    required=val
            }

            if (reason ~ /^Explicitly installed/)
                reason="EXPLICIT"
            else if (reason ~ /^Installed as a dependency/)
                reason="DEPENDENCY"

            reqcount=0

            if (required != "" && required != "None")
                reqcount=split(required, tmp, /[[:space:]]+/)

            if (name != "")
                print name, version, packager, reason, reqcount
        }
    '
)

###############################################################################
# Repository inventories
###############################################################################

echo "Loading Valve repository inventories..." >&2

mapfile -t valve_repos < <(
  LC_ALL=C pacman-conf --repo-list
)

for repo in "${valve_repos[@]}"; do
  [[ -n "$repo" ]] || continue

  echo "  Valve: $repo" >&2

  if ! repo_data="$(
    LC_ALL=C pacman -Sl "$repo" 2>/dev/null
  )"; then
    echo "    WARNING: unable to read $repo" >&2
    continue
  fi

  while read -r actual_repo pkg ver _rest; do
    [[ -n "$pkg" ]] || continue

    # First occurrence follows pacman repository priority and is therefore
    # the package Valve's configured repo order would normally resolve.
    if [[ ! ${VALVE_PREF_REPO[$pkg]+isset} ]]; then
      VALVE_PREF_REPO["$pkg"]="$actual_repo"
      VALVE_PREF_VER["$pkg"]="$ver"
    fi

    # Also retain the first platform and first ordinary base-repository
    # copy independently. This exposes deliberate holo/jupiter shadowing.
    if is_valve_platform_repo "$actual_repo" \
      && [[ ! ${VALVE_PLATFORM_REPO[$pkg]+isset} ]]; then
      VALVE_PLATFORM_REPO["$pkg"]="$actual_repo"
      VALVE_PLATFORM_VER["$pkg"]="$ver"
    fi

    if is_valve_base_repo "$actual_repo" \
      && [[ ! ${VALVE_BASE_REPO[$pkg]+isset} ]]; then
      VALVE_BASE_REPO["$pkg"]="$actual_repo"
      VALVE_BASE_VER["$pkg"]="$ver"
    fi

    if [[ -n ${VALVE_ALL[$pkg]-} ]]; then
      VALVE_ALL["$pkg"]+=","
    fi

    VALVE_ALL["$pkg"]+="${actual_repo}=${ver}"
  done <<<"$repo_data"
done

echo "Loading Arch repository inventories..." >&2

mapfile -t arch_repos < <(
  LC_ALL=C pacman-conf --config "$ARCH_CONF" --repo-list
)

for repo in "${arch_repos[@]}"; do
  [[ -n "$repo" ]] || continue

  echo "  Arch:  $repo" >&2

  if ! repo_data="$(
    LC_ALL=C pacman --config "$ARCH_CONF" -Sl "$repo" 2>/dev/null
  )"; then
    echo "    WARNING: unable to read Arch repo $repo" >&2
    continue
  fi

  while read -r actual_repo pkg ver _rest; do
    [[ -n "$pkg" ]] || continue

    if [[ ! ${ARCH_PREF_REPO[$pkg]+isset} ]]; then
      ARCH_PREF_REPO["$pkg"]="$actual_repo"
      ARCH_PREF_VER["$pkg"]="$ver"
    fi

    if [[ -n ${ARCH_ALL[$pkg]-} ]]; then
      ARCH_ALL["$pkg"]+=","
    fi

    ARCH_ALL["$pkg"]+="${actual_repo}=${ver}"
  done <<<"$repo_data"
done

###############################################################################
# Arch base dependency closure
#
# pactree may print versioned dependency expressions (for example glibc>=X).
# Normalize those to package names before populating BASE_SET. pactree is
# optional; without it, ARCH_BASE is emitted as unknown.
###############################################################################

if command -v pactree >/dev/null; then
  echo "Building Arch base-package dependency set..." >&2

  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    BASE_SET["$pkg"]=1
  done < <(
    LC_ALL=C pactree -u base 2>/dev/null \
      | sed -E \
        -e 's/^[^[:alnum:]@._+:-]*//' \
        -e 's/[[:space:]].*$//' \
        -e 's/[<>=].*$//' \
      | awk 'NF {print $1}' \
      | sort -u
  )

  # The root metapackage itself is part of the set by definition.
  BASE_SET[base]=1
  HAVE_BASE_SET=1
else
  echo "WARNING: pactree not installed (package: pacman-contrib); ARCH_BASE classification disabled" >&2
fi

###############################################################################
# Classification helpers
###############################################################################

version_delta() {
  local installed="${1:-}"
  local candidate="${2:-}"

  if [[ -z "$installed" || -z "$candidate" ]]; then
    printf '%s' "-"
    return
  fi

  local cmp
  cmp="$(vercmp "$candidate" "$installed")"

  if ((cmp > 0)); then
    printf '%s' "NEWER"
  elif ((cmp < 0)); then
    printf '%s' "OLDER"
  else
    printf '%s' "SAME"
  fi
}

# Compare Valve's preferred platform override with Valve's own ordinary
# core/extra/multilib copy. A same-pkgver but different pkgrel is called a
# REBUILD, which is a useful signal that Valve deliberately rebuilt the package.
valve_override_relation() {
  local platform_ver="${1:-}"
  local base_ver="${2:-}"

  if [[ -z "$platform_ver" || -z "$base_ver" ]]; then
    printf '%s' "-"
    return
  fi

  if [[ "$platform_ver" == "$base_ver" ]]; then
    printf '%s' "SAME"
    return
  fi

  local platform_pkgver="$platform_ver"
  local base_pkgver="$base_ver"

  if [[ "$platform_pkgver" == *-* ]]; then
    platform_pkgver="${platform_pkgver%-*}"
  fi

  if [[ "$base_pkgver" == *-* ]]; then
    base_pkgver="${base_pkgver%-*}"
  fi

  if [[ "$platform_pkgver" == "$base_pkgver" ]]; then
    printf '%s' "REBUILD"
    return
  fi

  local cmp
  cmp="$(vercmp "$platform_ver" "$base_ver")"

  if ((cmp > 0)); then
    printf '%s' "PLATFORM_NEWER"
  elif ((cmp < 0)); then
    printf '%s' "PLATFORM_OLDER"
  else
    printf '%s' "SAME"
  fi
}

repo_flags() {
  local entries="$1"
  local entry repo

  local platform=0
  local base_repo=0
  local other=0

  IFS=',' read -ra parts <<<"$entries"

  for entry in "${parts[@]}"; do
    [[ -n "$entry" ]] || continue

    repo="${entry%%=*}"

    if is_valve_platform_repo "$repo"; then
      platform=1
    elif is_valve_base_repo "$repo"; then
      base_repo=1
    else
      other=1
    fi
  done

  printf '%s:%s:%s' "$platform" "$base_repo" "$other"
}

source_class() {
  local valve_entries="$1"
  local arch_entries="$2"

  local platform=0
  local base_repo=0
  local other=0

  if [[ -n "$valve_entries" ]]; then
    IFS=: read -r platform base_repo other < <(
      repo_flags "$valve_entries"
    )
  fi

  if ((platform)); then
    if [[ -n "$arch_entries" ]]; then
      printf '%s' "VALVE_PLATFORM_OVERRIDE"
    else
      printf '%s' "VALVE_PLATFORM_ONLY"
    fi
    return
  fi

  if ((base_repo)); then
    if [[ -n "$arch_entries" ]]; then
      printf '%s' "SHARED_UPSTREAM"
    else
      printf '%s' "VALVE_BASE_REPO_ONLY"
    fi
    return
  fi

  if [[ -n "$valve_entries" ]]; then
    if [[ -n "$arch_entries" ]]; then
      printf '%s' "SHARED_OTHER"
    else
      printf '%s' "VALVE_OTHER_ONLY"
    fi
    return
  fi

  if [[ -n "$arch_entries" ]]; then
    printf '%s' "ARCH_ONLY"
  else
    printf '%s' "LOCAL_ONLY"
  fi
}

package_flags() {
  local pkg="$1"
  local valve_entries="$2"
  local reason="$3"
  local reqby="$4"
  local installed_ver="$5"
  local valve_ver="$6"
  local class="$7"
  local arch_base="$8"

  local flags=()
  local platform=0 base_repo=0 other=0

  if [[ -n "$valve_entries" ]]; then
    IFS=: read -r platform base_repo other < <(
      repo_flags "$valve_entries"
    )
  fi

  if ((platform)); then
    flags+=("VALVE_PLATFORM")
  fi

  if [[ "$arch_base" == "YES" ]]; then
    flags+=("ARCH_BASE")
  fi

  if [[ "$reqby" =~ ^[0-9]+$ ]] && ((reqby >= 25)); then
    flags+=("HIGH_RDEPS")
  fi

  # This describes pacman's install topology only; it deliberately does not
  # imply that the package is safe to remove or replace.
  if [[ "$reason" == "EXPLICIT" && "$reqby" == "0" ]]; then
    flags+=("TOPLEVEL_EXPLICIT")

    # A stronger bolt-on heuristic: explicit leaf + ordinary Valve
    # upstream repo + not in Arch's base dependency closure.
    if [[ "$class" == "SHARED_UPSTREAM" && "$arch_base" == "NO" ]]; then
      flags+=("BOLT_ON_CANDIDATE")
    fi
  fi

  if [[ "$installed_ver" =~ (jupiter|steamos|neptune|valve) ]] \
    || [[ "$valve_ver" =~ (jupiter|steamos|neptune|valve) ]]; then
    flags+=("CUSTOM_VERSION")
  fi

  if ((${#flags[@]} == 0)); then
    printf '%s' "-"
  else
    local IFS=','
    printf '%s' "${flags[*]}"
  fi
}

###############################################################################
# Package list
###############################################################################

if ((${#packages[@]} == 0)); then
  mapfile -t packages < <(
    printf '%s\n' "${!INSTALLED_VER[@]}" | sort
  )
fi

###############################################################################
# Build normalized TSV internally, then render the requested output format.
###############################################################################

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "PACKAGE" \
  "INSTALLED" \
  "VALVE_PREFERRED_REPO" \
  "VALVE_PREFERRED_VERSION" \
  "VALVE_DELTA" \
  "VALVE_PLATFORM_REPO" \
  "VALVE_PLATFORM_VERSION" \
  "VALVE_BASE_REPO" \
  "VALVE_BASE_VERSION" \
  "VALVE_OVERRIDE_RELATION" \
  "VALVE_ALL_REPOS" \
  "ARCH_PREFERRED_REPO" \
  "ARCH_PREFERRED_VERSION" \
  "ARCH_DELTA" \
  "ARCH_ALL_REPOS" \
  "PACKAGER" \
  "REASON" \
  "REQBY" \
  "ARCH_BASE" \
  "SOURCE_CLASS" \
  "FLAGS" \
  >"$out"

for pkg in "${packages[@]}"; do
  installed="${INSTALLED_VER[$pkg]-}"
  packager="${INSTALLED_PACKAGER[$pkg]-}"
  reason="${INSTALLED_REASON[$pkg]-}"
  reqby="${INSTALLED_REQBY[$pkg]-}"

  valve_repo="${VALVE_PREF_REPO[$pkg]-}"
  valve_ver="${VALVE_PREF_VER[$pkg]-}"
  valve_platform_repo="${VALVE_PLATFORM_REPO[$pkg]-}"
  valve_platform_ver="${VALVE_PLATFORM_VER[$pkg]-}"
  valve_base_repo="${VALVE_BASE_REPO[$pkg]-}"
  valve_base_ver="${VALVE_BASE_VER[$pkg]-}"
  valve_all="${VALVE_ALL[$pkg]-}"

  arch_repo="${ARCH_PREF_REPO[$pkg]-}"
  arch_ver="${ARCH_PREF_VER[$pkg]-}"
  arch_all="${ARCH_ALL[$pkg]-}"

  [[ -n "$installed" ]] || installed="-"
  [[ -n "$packager" ]] || packager="-"
  [[ -n "$reason" ]] || reason="-"
  [[ -n "$reqby" ]] || reqby="-"
  [[ -n "$valve_repo" ]] || valve_repo="-"
  [[ -n "$valve_ver" ]] || valve_ver="-"
  [[ -n "$valve_platform_repo" ]] || valve_platform_repo="-"
  [[ -n "$valve_platform_ver" ]] || valve_platform_ver="-"
  [[ -n "$valve_base_repo" ]] || valve_base_repo="-"
  [[ -n "$valve_base_ver" ]] || valve_base_ver="-"
  [[ -n "$valve_all" ]] || valve_all="-"
  [[ -n "$arch_repo" ]] || arch_repo="-"
  [[ -n "$arch_ver" ]] || arch_ver="-"
  [[ -n "$arch_all" ]] || arch_all="-"

  if [[ ${BASE_SET[$pkg]+isset} ]]; then
    arch_base="YES"
  elif ((HAVE_BASE_SET)); then
    arch_base="NO"
  else
    arch_base="?"
  fi

  vdelta="$(
    version_delta "${INSTALLED_VER[$pkg]-}" "${VALVE_PREF_VER[$pkg]-}"
  )"

  adelta="$(
    version_delta "${INSTALLED_VER[$pkg]-}" "${ARCH_PREF_VER[$pkg]-}"
  )"

  override_relation="$(
    valve_override_relation \
      "${VALVE_PLATFORM_VER[$pkg]-}" \
      "${VALVE_BASE_VER[$pkg]-}"
  )"

  class="$(
    source_class "${VALVE_ALL[$pkg]-}" "${ARCH_ALL[$pkg]-}"
  )"

  flags_str="$(
    package_flags \
      "$pkg" \
      "${VALVE_ALL[$pkg]-}" \
      "${INSTALLED_REASON[$pkg]-}" \
      "${INSTALLED_REQBY[$pkg]-}" \
      "${INSTALLED_VER[$pkg]-}" \
      "${VALVE_PREF_VER[$pkg]-}" \
      "$class" \
      "$arch_base"
  )"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$pkg" \
    "$installed" \
    "$valve_repo" \
    "$valve_ver" \
    "$vdelta" \
    "$valve_platform_repo" \
    "$valve_platform_ver" \
    "$valve_base_repo" \
    "$valve_base_ver" \
    "$override_relation" \
    "$valve_all" \
    "$arch_repo" \
    "$arch_ver" \
    "$adelta" \
    "$arch_all" \
    "$packager" \
    "$reason" \
    "$reqby" \
    "$arch_base" \
    "$class" \
    "$flags_str" \
    >>"$out"
done

case "$FORMAT" in
  tsv)
    cat "$out"
    ;;

  table)
    if command -v column >/dev/null; then
      column -t -s $'\t' "$out"
    else
      echo "WARNING: column not installed; falling back to TSV" >&2
      cat "$out"
    fi
    ;;

  csv)
    # RFC-4180-style quoting: quote every field and double embedded quotes.
    # Internal fields are guaranteed not to contain tabs/newlines because
    # they originate from pacman metadata normalized above.
    awk -F '\t' '
            {
                for (i=1; i<=NF; i++) {
                    gsub(/"/, "\"\"", $i)
                    printf "%s\"%s\"", (i == 1 ? "" : ","), $i
                }
                printf "\n"
            }
        ' "$out"
    ;;

  json)
    python3 - "$out" <<'PY'
import csv
import json
import sys

path = sys.argv[1]

with open(path, "r", encoding="utf-8", newline="") as f:
    rows = list(csv.DictReader(f, delimiter="\t"))

for row in rows:
    reqby = row.get("REQBY", "-")
    row["REQBY"] = int(reqby) if reqby.isdigit() else None

    arch_base = row.get("ARCH_BASE")
    if arch_base == "YES":
        row["ARCH_BASE"] = True
    elif arch_base == "NO":
        row["ARCH_BASE"] = False
    else:
        row["ARCH_BASE"] = None

    flags = row.get("FLAGS", "-")
    row["FLAGS"] = [] if flags in ("", "-") else flags.split(",")

json.dump(rows, sys.stdout, indent=2, ensure_ascii=False)
sys.stdout.write("\n")
PY
    ;;
esac
