#!/usr/bin/env bash
# Cross-build zlib for Maemo Diablo.
#
#   tools/build-zlib.sh
#
# The device has zlib 1.2.3, from 2005. Two reasons not to use it:
#
#   1. It predates `z_const`, which arrived in zlib 1.2.6 (2012). curl 8.x
#      assumes it exists, and the build dies with:
#          content_encoding.c:278: error: 'z_const' undeclared
#      That alone could be papered over with -Dz_const= , which is even
#      semantically right for the old API.
#   2. zlib 1.2.3 carries known CVEs. Linking a TLS stack against a 2005
#      compression library with published vulnerabilities defeats the point of
#      the exercise.
#
# So we ship our own, under /opt/handshake, alongside the system one. Same rule
# as everything else here: coexist, never replace.
set -euo pipefail

VERSION="${ZLIB_VERSION:-1.3.2}"
# Published on zlib.net alongside the tarball, and verified against a fresh
# download before being written here.
SHA256="bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$PWD/build}"
OUT="${OUT:-$PWD/out}"
JOBS="${JOBS:-$(nproc)}"

# shellcheck source=env.sh
. "$HERE/env.sh" "${DIABLO_SYSROOT:-$PWD/sysroot-diablo}"

mkdir -p "$WORK" && cd "$WORK"
tarball="zlib-$VERSION.tar.gz"
if [ ! -f "$tarball" ]; then
  echo "==> Fetching zlib $VERSION"
  curl -fsSL --retry 3 -O "https://www.zlib.net/$tarball"
fi
got=$(sha256sum < "$tarball" | cut -d' ' -f1)
[ "$got" = "$SHA256" ] || { echo "SHA256 MISMATCH: want $SHA256, got $got"; exit 1; }
echo "    sha256 ok"

rm -rf "zlib-$VERSION" && tar xzf "$tarball" && cd "zlib-$VERSION"

echo "==> Configuring"
# zlib's configure is hand-written, not autoconf: no --host, it takes the
# compiler from the environment, which tools/env.sh has already set.
CHOST="$TARGET" ./configure --prefix=/opt/handshake

echo "==> Building (-j$JOBS)"
make -j"$JOBS"

echo "==> Staging into $OUT"
make DESTDIR="$OUT" install

echo "==> Stripping"
find "$OUT/opt/handshake" -type f -name 'libz.so*' -print0 |
  while IFS= read -r -d '' f; do
    file "$f" | grep -q 'ELF 32-bit.*ARM' && "$STRIP" --strip-unneeded "$f" || true
  done

echo "==> Verifying"
mapfile -t artefacts < <(find "$OUT/opt/handshake" -type f -name 'libz.so.*' | sort)
[ ${#artefacts[@]} -gt 0 ] || { echo "no ARM libraries were built"; exit 1; }
EXTRA_LIBDIR="$OUT/opt/handshake/lib" "$HERE/check-artifact.sh" "${artefacts[@]}"

echo
echo "Built: ${artefacts[*]}"
