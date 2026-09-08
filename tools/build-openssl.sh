#!/usr/bin/env bash
# Cross-build OpenSSL for Maemo 4.1.2 (Diablo) on the Nokia N800/N810.
#
#   tools/mk-sysroot.sh                 # once
#   tools/build-openssl.sh              # then this
#   tools/check-artifact.sh out/opt/handshake/lib/lib*.so.3 ...
#
# Installs into ./out, laid out as it will sit on the device under
# /opt/handshake. Nothing here touches the device's own OpenSSL 0.9.8e.
set -euo pipefail

VERSION="${OPENSSL_VERSION:-3.5.8}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$PWD/build}"
OUT="${OUT:-$PWD/out}"
JOBS="${JOBS:-$(nproc)}"

# shellcheck source=env.sh
. "$HERE/env.sh" "${DIABLO_SYSROOT:-$PWD/sysroot-diablo}"

mkdir -p "$WORK" && cd "$WORK"
tarball="openssl-$VERSION.tar.gz"
if [ ! -f "$tarball" ]; then
  echo "==> Fetching OpenSSL $VERSION"
  curl -fsSL --retry 3 -O "https://github.com/openssl/openssl/releases/download/openssl-$VERSION/$tarball" ||
  curl -fsSL --retry 3 -O "https://openssl-library.org/source/$tarball"
fi
rm -rf "openssl-$VERSION" && tar xzf "$tarball" && cd "openssl-$VERSION"

echo "==> Configuring"
# linux-armv4 is OpenSSL's generic 32-bit ARM target. Its assembly modules all
# have ARMv4-baseline code paths, so they run on the ARM1136 and are worth
# keeping on a 400 MHz core.
#
# --with-rand-seed=devrandom  : getrandom() is kernel 3.17+; this device is 2.6.21.
# no-afalgeng                 : AF_ALG needs a far newer kernel.
# no-async                    : glibc 2.5/arm has no getcontext/setcontext/makecontext,
#                               so OpenSSL's fibre-based ASYNC could never work.
# no-tests / no-docs          : we cannot run tests here, and docs need extra perl.
./Configure linux-armv4 \
  --prefix=/opt/handshake \
  --openssldir=/opt/handshake/ssl \
  --with-rand-seed=devrandom \
  --libdir=lib \
  shared threads no-tests no-docs no-afalgeng no-async

echo "==> Building (-j$JOBS)"
make -j"$JOBS"

echo "==> Staging into $OUT"
rm -rf "$OUT" && make DESTDIR="$OUT" install_sw install_ssldirs

# GCC 4.7+ emits calls into libatomic for 64-bit atomics on ARMv6, which has no
# 64-bit atomic instructions. Diablo's newest compiler is GCC 4.2, so it has no
# libatomic at all -- it is absent from every Diablo package index. Ship the
# toolchain's, which we verify needs nothing newer than GLIBC_2.4.
if "$STRIP" --version >/dev/null 2>&1 &&
   $TARGET-readelf -d "$OUT/opt/handshake/lib/libcrypto.so.3" | grep -q 'libatomic\.so\.1'; then
  echo "==> Bundling libatomic.so.1 (absent from Diablo)"
  src=$($TARGET-gcc -print-file-name=libatomic.so.1)
  [ -e "$src" ] || { echo "    cannot find libatomic.so.1"; exit 1; }
  cp -L "$src" "$OUT/opt/handshake/lib/libatomic.so.1"
fi

echo "==> Stripping"
find "$OUT" -type f \( -name '*.so*' -o -perm -u+x \) -print0 |
  while IFS= read -r -d '' f; do
    file "$f" | grep -q 'ELF 32-bit.*ARM' && "$STRIP" --strip-unneeded "$f" || true
  done

echo "==> Verifying"
mapfile -t artefacts < <(find "$OUT" -type f \( -name '*.so*' -o -name openssl \) | sort)
EXTRA_LIBDIR="$OUT/opt/handshake/lib" "$HERE/check-artifact.sh" "${artefacts[@]}"

echo
echo "Staged tree ($(du -sh "$OUT" | cut -f1)):"
find "$OUT" -maxdepth 4 -type d | sed "s|$OUT|  |"
cat <<EOF

Next:
  1. Copy $OUT/opt/handshake to the device as /opt/handshake
     (put it on the 2 GB internal flash, not the 256 MB rootfs).
  2. On the device:
       export LD_LIBRARY_PATH=/opt/handshake/lib
       /opt/handshake/bin/openssl version -a
       /opt/handshake/bin/openssl s_client -connect example.org:443 -tls1_3
  3. If step 2 dies with "FATAL: kernel too old", the ABI note check was
     bypassed -- see tools/env.sh.
EOF
