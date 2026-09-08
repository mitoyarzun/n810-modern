#!/usr/bin/env bash
# Build a Maemo 4.1.2 (Diablo) armel sysroot for cross-compiling to the N800/N810.
#
# This is what lets a modern cross-GCC target a 2008 device: we compile against
# the device's own glibc 2.5 headers and libraries. Nothing here is rebuilt or
# replaced on the device.
#
# Package versions and MD5s are pinned in diablo-sysroot.manifest so the result
# is reproducible and does not depend on any one mirror staying up.
#
# Usage: mk-sysroot.sh [sysroot-dir]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$HERE/diablo-sysroot.manifest"
SYSROOT="${1:-$PWD/sysroot-diablo}"
CACHE="${CACHE:-$PWD/.deb-cache}"

# repository.maemo.org itself has been down since ~2021. These are community
# mirrors of it, tried in order. The viniciuspaes mirror uses Referer-based
# hotlink protection and rate-limits bursts, so it is second: be gentle with it.
MIRRORS=(
  "http://maemo.wunderwungiel.pl/repository.maemo.org"
  "http://maemo.viniciuspaes.com"
)
UA="Mozilla/5.0 (X11; Linux x86_64)"

mkdir -p "$CACHE" "$SYSROOT"

get() { # pool-path outfile
  local path="$1" out="$2" m
  for m in "${MIRRORS[@]}"; do
    if curl -fsSL --retry 3 --retry-delay 5 -m 600 \
         -A "$UA" -e "$m/" -o "$out.part" "$m/$path"; then
      mv "$out.part" "$out"; echo "$m"; return 0
    fi
    rm -f "$out.part"
  done
  return 1
}

echo "==> Sysroot: $SYSROOT"
while IFS=$'\t' read -r pkg ver md5 path; do
  case "$pkg" in ''|\#*) continue ;; esac
  deb="$CACHE/$(basename "$path")"
  if [ ! -f "$deb" ] || [ "$(md5sum < "$deb" | cut -d' ' -f1)" != "$md5" ]; then
    printf '    %-22s %-28s ' "$pkg" "$ver"
    src=$(get "$path" "$deb") || { echo "FAILED (all mirrors)"; exit 1; }
    got=$(md5sum < "$deb" | cut -d' ' -f1)
    [ "$got" = "$md5" ] || { echo "MD5 MISMATCH (want $md5, got $got)"; rm -f "$deb"; exit 1; }
    echo "ok  <- ${src#http://}"
  else
    printf '    %-22s %-28s cached\n' "$pkg" "$ver"
  fi
  dpkg-deb -x "$deb" "$SYSROOT"
done < "$MANIFEST"

# Absolute symlinks inside a sysroot resolve against the HOST filesystem, so
# /usr/lib/libz.so -> /lib/libz.so.1 would silently link the host's library.
# Rewrite them relative. (GNU ld already applies --sysroot to absolute paths
# inside linker scripts such as /usr/lib/libc.so, so those need no fixing.)
n=0
while IFS= read -r -d '' link; do
  t=$(readlink "$link")
  case "$t" in /*) ln -sfn "$(realpath -m --relative-to="$(dirname "$link")" "$SYSROOT$t")" "$link"; n=$((n+1)) ;; esac
done < <(find "$SYSROOT" -type l -print0)

kver=$(awk '/LINUX_VERSION_CODE/{c=$3} END{printf "%d.%d.%d", int(c/65536), int(c/256)%256, c%256}' \
       "$SYSROOT/usr/include/linux/version.h" 2>/dev/null || echo "?")
echo
echo "    glibc            $(ls "$SYSROOT"/lib/libc-*.so 2>/dev/null | sed 's/.*libc-\(.*\)\.so/\1/' | head -1)"
echo "    kernel headers   $kver"
echo "    relative links   $n rewritten"
echo "    size             $(du -sh "$SYSROOT" | cut -f1)"
echo "==> Ready. Source tools/env.sh to use it."
