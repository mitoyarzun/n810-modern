#!/usr/bin/env bash
# Cross-build curl for Maemo Diablo, against our OpenSSL.
#
#   tools/build-openssl.sh              # first -- curl links against it
#   tools/mk-truststore.sh              # and needs the CA bundle
#   tools/build-curl.sh
#
# The device ships libcurl3 7.15.5 linked against OpenSSL 0.9.8e, so it has the
# same problem as everything else: it cannot complete a modern handshake. This
# installs a current curl beside it under /opt/handshake, and does not touch
# the system library.
#
# curl also unlocks the rest of the ladder: git wants it, and NetSurf wants it.
set -euo pipefail

VERSION="${CURL_VERSION:-8.22.0}"
# Verified identical from curl.se and the GitHub release for 8.22.0.
SHA256="d54dd598bf05927a726deb38df31c6a255ba83ff1de57c5d1464dac3ed8f44a1"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$PWD/build}"
OUT="${OUT:-$PWD/out}"
JOBS="${JOBS:-$(nproc)}"
SSLDIR="$OUT/opt/handshake"

# shellcheck source=env.sh
. "$HERE/env.sh" "${DIABLO_SYSROOT:-$PWD/sysroot-diablo}"

[ -f "$SSLDIR/lib/libssl.so.3" ] || {
  echo "no OpenSSL at $SSLDIR -- run tools/build-openssl.sh first"; exit 1; }
[ -f "$SSLDIR/lib/libz.so" ] || {
  echo "no zlib at $SSLDIR -- run tools/build-zlib.sh first"; exit 1; }

mkdir -p "$WORK" && cd "$WORK"
tarball="curl-$VERSION.tar.gz"
if [ ! -f "$tarball" ]; then
  echo "==> Fetching curl $VERSION"
  curl -fsSL --retry 3 -O "https://curl.se/download/$tarball"
fi
got=$(sha256sum < "$tarball" | cut -d' ' -f1)
[ "$got" = "$SHA256" ] || { echo "SHA256 MISMATCH: want $SHA256, got $got"; exit 1; }
echo "    sha256 ok"

rm -rf "curl-$VERSION" && tar xzf "$tarball" && cd "curl-$VERSION"

echo "==> Configuring"
# --with-ca-bundle is baked in so nothing needs configuring on the device; it
# is the same path tools/mk-truststore.sh installs to.
#
# The disabled features are all things Diablo lacks or we do not ship:
#   ldap/ldaps  needs OpenLDAP
#   libpsl      needs libidn2, which needs libunistring -- a chain for a
#               cookie-domain nicety
#   brotli/zstd/nghttp2/libssh2/librtmp   not built for this target
#   manual      avoids needing nroff, and saves space on a 256 MB rootfs
#
# zlib is OURS, not the device's. Diablo has 1.2.3 from 2005, which predates
# `z_const` (zlib 1.2.6, 2012) so curl 8.x will not compile against it, and
# which carries known CVEs. tools/build-zlib.sh puts 1.3.2 in the same prefix.
./configure \
  --host=arm-linux-gnueabi \
  --prefix=/opt/handshake \
  --with-openssl="$SSLDIR" \
  --with-ca-bundle=/opt/handshake/ssl/cert.pem \
  --with-zlib="$SSLDIR" \
  --disable-ldap --disable-ldaps \
  --without-libpsl --without-libidn2 \
  --without-brotli --without-zstd \
  --without-nghttp2 --without-libssh2 --without-librtmp \
  --disable-manual \
  --enable-optimize

echo "==> Building (-j$JOBS)"
make -j"$JOBS"

echo "==> Staging into $OUT"
make DESTDIR="$OUT" install

echo "==> Stripping"
find "$OUT/opt/handshake" -type f \( -name 'curl' -o -name 'libcurl.so*' \) -print0 |
  while IFS= read -r -d '' f; do
    file "$f" | grep -q 'ELF 32-bit.*ARM' && "$STRIP" --strip-unneeded "$f" || true
  done

echo "==> Verifying"
mapfile -t artefacts < <(find "$OUT/opt/handshake" -type f \
  \( -name 'curl' -o -name 'libcurl.so.*' \) | sort)
[ ${#artefacts[@]} -gt 0 ] || { echo "no ARM binaries were built"; exit 1; }
EXTRA_LIBDIR="$OUT/opt/handshake/lib" "$HERE/check-artifact.sh" "${artefacts[@]}"

cat <<INFO

Built: ${artefacts[*]}

Next:
  tools/qemu-curl-test.sh      # fetch a real page over TLS 1.3
INFO
