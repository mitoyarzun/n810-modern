#!/usr/bin/env bash
# Cross-build stunnel for Maemo Diablo, against our OpenSSL.
#
#   tools/build-openssl.sh              # first -- stunnel links against it
#   tools/build-stunnel.sh
#
# Why stunnel before wget: it is a TLS wrapper, not a client. Point any stock
# Diablo application at localhost:<port> and it reaches a modern TLS site,
# without rebuilding that application. One package, every consumer.
#
# Installs into ./out alongside OpenSSL, laid out as it will sit on the device
# under /opt/handshake.
set -euo pipefail

VERSION="${STUNNEL_VERSION:-5.80}"
SHA256="6d0841d48de07cbbaf4a055919065bf7bb5ebc63cc15c97a2c76caa2bf285513"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$PWD/build}"
OUT="${OUT:-$PWD/out}"
JOBS="${JOBS:-$(nproc)}"
SSLDIR="$OUT/opt/handshake"

# shellcheck source=env.sh
. "$HERE/env.sh" "${DIABLO_SYSROOT:-$PWD/sysroot-diablo}"

[ -f "$SSLDIR/lib/libssl.so.3" ] || {
  echo "no OpenSSL at $SSLDIR -- run tools/build-openssl.sh first"; exit 1; }

mkdir -p "$WORK" && cd "$WORK"
tarball="stunnel-$VERSION.tar.gz"
if [ ! -f "$tarball" ]; then
  echo "==> Fetching stunnel $VERSION"
  curl -fsSL --retry 3 -O "https://www.stunnel.org/downloads/$tarball"
fi
got=$(sha256sum < "$tarball" | cut -d' ' -f1)
[ "$got" = "$SHA256" ] || { echo "SHA256 MISMATCH: want $SHA256, got $got"; exit 1; }
echo "    sha256 ok"

rm -rf "stunnel-$VERSION" && tar xzf "$tarball" && cd "stunnel-$VERSION"

echo "==> Configuring"
# --host is what makes autoconf cross-compile rather than build for the host.
#
# --disable-systemd  : Diablo predates systemd by five years.
# --disable-libwrap  : tcp_wrappers is not in the Diablo index, and stunnel's
#                      own access control covers what we need.
# --disable-fips     : needs a FIPS-validated provider we are not shipping.
#
# ac_cv_* cache variables: autoconf normally answers these by RUNNING a test
# program, which it cannot do when cross-compiling, so it either guesses or
# stops. These are the answers for glibc 2.5 on ARM, and every one of them is
# a property of the target rather than a preference.
./configure \
  --host=arm-linux-gnueabi \
  --prefix=/opt/handshake \
  --sysconfdir=/opt/handshake/etc \
  --localstatedir=/opt/handshake/var \
  --with-ssl="$SSLDIR" \
  --disable-systemd \
  --disable-libwrap \
  --disable-fips \
  ac_cv_func_malloc_0_nonnull=yes \
  ac_cv_func_realloc_0_nonnull=yes

echo "==> Building (-j$JOBS)"
make -j"$JOBS"

echo "==> Staging into $OUT"
make DESTDIR="$OUT" install

echo "==> Stripping"
find "$OUT/opt/handshake" -type f -name 'stunnel*' -print0 |
  while IFS= read -r -d '' f; do
    file "$f" | grep -q 'ELF 32-bit.*ARM' && "$STRIP" --strip-unneeded "$f" || true
  done

echo "==> Verifying"
mapfile -t artefacts < <(find "$OUT/opt/handshake" -type f -name 'stunnel*' |
                         xargs -r file | grep 'ELF 32-bit.*ARM' | cut -d: -f1 | sort)
[ ${#artefacts[@]} -gt 0 ] || { echo "no ARM binaries were built"; exit 1; }
EXTRA_LIBDIR="$OUT/opt/handshake/lib" "$HERE/check-artifact.sh" "${artefacts[@]}"

cat <<INFO

Built: ${artefacts[*]}

Next:
  tools/qemu-smoke.sh          # proves openssl still loads
  tools/qemu-stunnel-test.sh   # proves stunnel loads and wraps a connection
INFO
