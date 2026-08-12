#!/bin/bash
#
# steamos-nvidia-installer — lib/resolve-driver.sh
# Stage 2: resolve the NVIDIA driver packages from Arch, download them pinned
# to permanent archive.archlinux.org URLs, and verify none needs a newer glibc
# than the image ships.
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/resolve-driver.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# The driver set comes from Arch, not Valve's frozen mirror (which pins an
# older 575.x). Default is whatever current Arch ships; --driver <branch>
# takes the newest build of that branch out of the Arch archive instead.
# Either way the resolved URLs are pinned to permanent
# archive.archlinux.org paths (mirror URLs die when Arch bumps the version)
# — the same URLs are recorded in the image for the self-heal repatch.
ARCHIVE_URL=https://archive.archlinux.org/packages

PKG_URLS=""            # pinned URLs, space-separated (also goes in driver.conf)
PKG_URL_ARR=()         # same, indexable alongside PKG_FILES
PKG_FILES=()           # local filenames in $WORKDIR/pkgs
FETCHED=0              # how many of PKG_FILES are already downloaded
DRIVER_VERSION=""      # nvidia-utils pkgver-pkgrel
NV_PKGVER=""           # pkgver only, for cross-package consistency check
PIN_VER=""             # version pin_pkg just resolved

# curl_retry MAX_RETRIES [curl args...]
# Retry a curl command with exponential backoff.  Dies on final failure.
curl_retry() {
  local max="$1"; shift
  local attempt delay=1
  for (( attempt=1; attempt<=max; attempt++ )); do
    if curl "$@"; then
      return 0
    fi
    if (( attempt < max )); then
      warn "curl attempt $attempt/$max failed, retrying in ${delay}s..."
      sleep "$delay"
      (( delay *= 2 ))
    fi
  done
  die "curl failed after $max attempts: $*"
}

# pin_pkg <pkg> <spec> — resolve one package and add it to the pinned set.
# spec "latest" = what current Arch has (archive URL when it's there yet,
# else the mirror); anything else = newest archived build whose version
# starts with that prefix ("580", "580.105.08") or matches exactly ("580.105.08-4").
pin_pkg() {
  local pkg="$1" spec="$2" repo ver file url download_url pinned_url
  # Validate spec: must be "latest" or a version-like string (digits.dots with optional -pkgrel)
  [[ "$spec" == latest || "$spec" =~ ^[0-9]+(\.[0-9]+)*(-[0-9]+(\.[0-9]+)*)?$ ]] \
    || die "Invalid --driver value: $spec (expected 'latest', branch like '580', version like '580.105.08', or exact like '580.105.08-4')"
  if [[ "$spec" == latest ]]; then
    read -r ver file repo < <(curl_retry 3 -sfL "https://archlinux.org/packages/search/json/?name=$pkg" \
      | python3 -c 'import json,sys
r=[p for p in json.load(sys.stdin)["results"]
   if p["repo"] in ("core","extra","multilib") and p["arch"] == "x86_64"]
if not r: raise SystemExit(1)
p=r[0]; print(p["pkgver"]+"-"+str(p["pkgrel"]), p["filename"], p["repo"])') \
      || die "Could not resolve $pkg from archlinux.org"
    url="$ARCHIVE_URL/${pkg:0:1}/$pkg/$file"
    if ! curl_retry 3 -sfIL "$url" -o /dev/null; then
      download_url="https://geo.mirror.pkgbuild.com/$repo/os/x86_64/$file"
      curl_retry 3 -sfIL "$download_url" -o /dev/null || die "$pkg $ver not on archive.archlinux.org nor the mirror"
      warn "$pkg not yet in the Arch archive — downloading from mirror (archive will catch up)"
    else
      download_url="$url"
    fi
    # Always pin the archive URL for self-healing — mirror URLs go stale when
    # Arch bumps the version, but the archive is permanent.
    pinned_url="$ARCHIVE_URL/${pkg:0:1}/$pkg/$file"
  else
    # the archive keeps every build ever released; newest match wins.
    # Distinguish exact pkgver-pkgrel (contains a hyphen) from a prefix.
    local pattern
    if [[ "$spec" == *-* ]]; then
      # Exact: 580.105.08-4 → match nvidia-utils-580.105.08-4-x86_64.pkg.tar.zst exactly
      pattern="${pkg}-${spec}-x86_64\\.pkg\\.tar\\.zst"
    else
      # Prefix: 580 → match nvidia-utils-580.*-x86_64.pkg.tar.zst
      pattern="${pkg}-${spec}[.-][^\"<]*-x86_64\\.pkg\\.tar\\.zst"
    fi
    file="$(curl_retry 3 -sfL "$ARCHIVE_URL/${pkg:0:1}/$pkg/" \
            | grep -oE "$pattern" | sort -uV | tail -1 || true)"
    [[ -n "$file" ]] || die "No $pkg build matching '$spec' in the Arch archive (bad --driver value, or no network)"
    ver="${file#"$pkg"-}"; ver="${ver%-x86_64.pkg.tar.zst}"
    download_url="$ARCHIVE_URL/${pkg:0:1}/$pkg/$file"
    pinned_url="$download_url"
  fi
  PKG_URLS+="${PKG_URLS:+ }$pinned_url"
  PKG_URL_ARR+=("$download_url")
  PKG_FILES+=("$file")
  PIN_VER="$ver"
  log "  $pkg $ver"
}

# fetch_pins — download whatever pin_pkg has added since the last call
fetch_pins() {
  mkdir -p "$WORKDIR/pkgs"
  local i f
  for (( i=FETCHED; i<${#PKG_FILES[@]}; i++ )); do
    f="${PKG_FILES[$i]}"
    if [[ -s "$WORKDIR/pkgs/$f" ]]; then
      log "Cached: $f"
    else
      log "Downloading $f"
      curl_retry 3 -sfL "${PKG_URL_ARR[$i]}" -o "$WORKDIR/pkgs/$f.part" \
        || die "download failed: ${PKG_URL_ARR[$i]}"
      mv "$WORKDIR/pkgs/$f.part" "$WORKDIR/pkgs/$f"
    fi
  done
  FETCHED=${#PKG_FILES[@]}
}

# Resolve nvidia-utils (+ companions and Arch-only deps) and download them.
resolve_driver_packages() {
  local companion_spec pkg dep
  local arch_only_deps=" egl-wayland2 "
  log "Resolving NVIDIA driver packages from Arch Linux (--driver $DRIVER_SPEC)"
  pin_pkg nvidia-utils "$DRIVER_SPEC"
  DRIVER_VERSION="$PIN_VER"; NV_PKGVER="${PIN_VER%-*}"
  log "Driver pinned: nvidia-open $DRIVER_VERSION"

  # Fetch nvidia-utils first: its own dependency list decides which support
  # packages have to come from Arch too — egl-wayland2 only became a
  # dependency at 590, so pulling it in for older branches would be wrong.
  fetch_pins

  # Module source + 32-bit userspace must match nvidia-utils exactly. On
  # "latest" they're resolved the same way (a just-bumped package may not be
  # in the archive yet); the skew check catches a mirror caught mid-bump.
  companion_spec="$DRIVER_SPEC"
  [[ "$companion_spec" == latest ]] || companion_spec="$NV_PKGVER"
  for pkg in nvidia-open-dkms lib32-nvidia-utils; do
    pin_pkg "$pkg" "$companion_spec"
    [[ "$PIN_VER" == "$NV_PKGVER"-* ]] \
      || die "Version skew: $pkg is $PIN_VER but nvidia-utils is $DRIVER_VERSION (mirror mid-update?) — retry in an hour"
  done

  # ...plus the support packages Valve's frozen repo doesn't carry at all, so
  # they can only come from Arch. Every other nvidia-utils dependency
  # (libglvnd, egl-wayland, egl-gbm, egl-x11) is resolved inside the build
  # chroot from Valve's own mirror, which keeps the image self-consistent —
  # don't add them here. egl-wayland2 only became a dependency at branch 590,
  # so which of these apply depends on the driver actually chosen.
  while read -r dep; do
    [[ -n "$dep" && "$arch_only_deps" == *" $dep "* ]] || continue
    log "  $DRIVER_VERSION also needs $dep, which Valve's repo predates"
    pin_pkg "$dep" latest
  done < <(tar -xOf "$WORKDIR/pkgs/${PKG_FILES[0]}" .PKGINFO \
           | awk '$1 == "depend" { print $3 }' | sed 's/[<>=].*//')
  fetch_pins
}

# Verify the downloaded payload doesn't require a newer glibc than the image.
check_glibc_compat() {
  local img_glibc scan max_glibc
  # Current Arch compiles against a newer glibc than frozen SteamOS ships.
  # NVIDIA's own blobs target ancient glibc so they're fine, but anything
  # Arch-compiled (egl-wayland2, and whoever joins the dep list in future
  # driver releases) can silently require symbols the image doesn't have.
  # Extract everything and refuse to build if any ELF needs more than the
  # image's glibc.
  img_glibc="$(basename "$(echo "$PACDB"/glibc-[0-9]*)" | sed -E 's/^glibc-([0-9]+\.[0-9]+).*/\1/')"
  [[ "$img_glibc" =~ ^[0-9]+\.[0-9]+$ ]] || die "Could not determine image glibc version"
  log "Checking payload glibc requirements against image glibc $img_glibc"
  scan="$WORKDIR/glibc-scan"
  rm -rf "$scan"; mkdir -p "$scan"
  for f in "${PKG_FILES[@]}"; do
    mkdir -p "$scan/${f%%.pkg.tar.zst}"
    tar -xf "$WORKDIR/pkgs/$f" -C "$scan/${f%%.pkg.tar.zst}"
  done
  # readelf fails on non-ELF executables (scripts) — mustn't kill the pipeline
  max_glibc="$({ find "$scan" -type f \( -name '*.so*' -o -perm -111 \) \
    -exec readelf -V {} + 2>/dev/null || true; } | grep -o 'GLIBC_[0-9.]*' \
    | sed 's/^GLIBC_//' | sort -uV | tail -1)"
  [[ -n "$max_glibc" ]] || die "glibc scan found no ELF version references — scan broken?"
  if [[ "$(printf '%s\n' "$max_glibc" "$img_glibc" | sort -V | tail -1)" != "$img_glibc" ]]; then
    die "Driver payload needs glibc $max_glibc but the image only has $img_glibc — current Arch has drifted too far; this needs the .run-installer approach instead"
  fi
  log "OK: payload needs at most glibc $max_glibc (image has $img_glibc)"
  rm -rf "$scan"
}