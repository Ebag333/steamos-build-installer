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

# pin_pkg <pkg> <spec> — resolve one package and add it to the pinned set.
# spec "latest" = what current Arch has (archive URL when it's there yet,
# else the mirror); anything else = newest archived build whose version
# starts with that prefix ("580", "580.105.08", "580.105.08-4").
pin_pkg() {
  local pkg="$1" spec="$2" repo ver file url
  if [[ "$spec" == latest ]]; then
    read -r ver file repo < <(curl -sfL "https://archlinux.org/packages/search/json/?name=$pkg" \
      | python3 -c 'import json,sys
r=[p for p in json.load(sys.stdin)["results"]
   if p["repo"] in ("core","extra","multilib") and p["arch"] == "x86_64"]
if not r: raise SystemExit(1)
p=r[0]; print(p["pkgver"]+"-"+str(p["pkgrel"]), p["filename"], p["repo"])') \
      || die "Could not resolve $pkg from archlinux.org"
    url="$ARCHIVE_URL/${pkg:0:1}/$pkg/$file"
    if ! curl -sfIL "$url" -o /dev/null; then
      url="https://geo.mirror.pkgbuild.com/$repo/os/x86_64/$file"
      curl -sfIL "$url" -o /dev/null || die "$pkg $ver not on archive.archlinux.org nor the mirror"
      warn "$pkg not yet in the Arch archive — pinning mirror URL (may go stale)"
    fi
  else
    # the archive keeps every build ever released; newest match wins
    file="$(curl -sfL "$ARCHIVE_URL/${pkg:0:1}/$pkg/" \
            | grep -oE "${pkg}-${spec}[.-][^\"<]*-x86_64\.pkg\.tar\.zst" | sort -uV | tail -1 || true)"
    [[ -n "$file" ]] || die "No $pkg build matching '$spec' in the Arch archive (bad --driver value, or no network)"
    ver="${file#"$pkg"-}"; ver="${ver%-x86_64.pkg.tar.zst}"
    url="$ARCHIVE_URL/${pkg:0:1}/$pkg/$file"
  fi
  PKG_URLS+="${PKG_URLS:+ }$url"
  PKG_URL_ARR+=("$url")
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
      curl -sfL "${PKG_URL_ARR[$i]}" -o "$WORKDIR/pkgs/$f.part" \
        || die "download failed: ${PKG_URL_ARR[$i]}"
      mv "$WORKDIR/pkgs/$f.part" "$WORKDIR/pkgs/$f"
    fi
  done
  FETCHED=${#PKG_FILES[@]}
}

# Resolve nvidia-utils (+ companions and Arch-only deps) and download them.
resolve_driver_packages() {
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
  COMPANION_SPEC="$DRIVER_SPEC"
  [[ "$COMPANION_SPEC" == latest ]] || COMPANION_SPEC="$NV_PKGVER"
  for pkg in nvidia-open-dkms lib32-nvidia-utils; do
    pin_pkg "$pkg" "$COMPANION_SPEC"
    [[ "$PIN_VER" == "$NV_PKGVER"-* ]] \
      || die "Version skew: $pkg is $PIN_VER but nvidia-utils is $DRIVER_VERSION (mirror mid-update?) — retry in an hour"
  done

  # ...plus the support packages Valve's frozen repo doesn't carry at all, so
  # they can only come from Arch. Every other nvidia-utils dependency
  # (libglvnd, egl-wayland, egl-gbm, egl-x11) is resolved inside the build
  # chroot from Valve's own mirror, which keeps the image self-consistent —
  # don't add them here. egl-wayland2 only became a dependency at branch 590,
  # so which of these apply depends on the driver actually chosen.
  ARCH_ONLY_DEPS=" egl-wayland2 "
  while read -r dep; do
    [[ -n "$dep" && "$ARCH_ONLY_DEPS" == *" $dep "* ]] || continue
    log "  $DRIVER_VERSION also needs $dep, which Valve's repo predates"
    pin_pkg "$dep" latest
  done < <(tar -xOf "$WORKDIR/pkgs/${PKG_FILES[0]}" .PKGINFO \
           | awk '$1 == "depend" { print $3 }' | sed 's/[<>=].*//')
  fetch_pins
}

# Verify the downloaded payload doesn't require a newer glibc than the image.
check_glibc_compat() {
  # Current Arch compiles against a newer glibc than frozen SteamOS ships.
  # NVIDIA's own blobs target ancient glibc so they're fine, but anything
  # Arch-compiled (egl-wayland2, and whoever joins the dep list in future
  # driver releases) can silently require symbols the image doesn't have.
  # Extract everything and refuse to build if any ELF needs more than the
  # image's glibc.
  IMG_GLIBC="$(basename "$(echo "$PACDB"/glibc-[0-9]*)" | sed -E 's/^glibc-([0-9]+\.[0-9]+).*/\1/')"
  [[ "$IMG_GLIBC" =~ ^[0-9]+\.[0-9]+$ ]] || die "Could not determine image glibc version"
  log "Checking payload glibc requirements against image glibc $IMG_GLIBC"
  SCAN="$WORKDIR/glibc-scan"
  rm -rf "$SCAN"; mkdir -p "$SCAN"
  for f in "${PKG_FILES[@]}"; do
    mkdir -p "$SCAN/${f%%.pkg.tar.zst}"
    tar -xf "$WORKDIR/pkgs/$f" -C "$SCAN/${f%%.pkg.tar.zst}"
  done
  # readelf fails on non-ELF executables (scripts) — mustn't kill the pipeline
  MAX_GLIBC="$({ find "$SCAN" -type f \( -name '*.so*' -o -perm -111 \) \
    -exec readelf -V {} + 2>/dev/null || true; } | grep -o 'GLIBC_[0-9.]*' \
    | sed 's/^GLIBC_//' | sort -uV | tail -1)"
  [[ -n "$MAX_GLIBC" ]] || die "glibc scan found no ELF version references — scan broken?"
  if [[ "$(printf '%s\n' "$MAX_GLIBC" "$IMG_GLIBC" | sort -V | tail -1)" != "$IMG_GLIBC" ]]; then
    die "Driver payload needs glibc $MAX_GLIBC but the image only has $IMG_GLIBC — current Arch has drifted too far; this needs the .run-installer approach instead"
  fi
  log "OK: payload needs at most glibc $MAX_GLIBC (image has $IMG_GLIBC)"
  rm -rf "$SCAN"
}