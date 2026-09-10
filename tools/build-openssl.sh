#!/usr/bin/env bash
# Cross-build OpenSSL for Maemo 4.1.2 (Diablo) on the Nokia N800/N810.
#
#   tools/mk-sysroot.sh                 # once
#   tools/build-openssl.sh              # then this
#   tools/check-artifact.sh out/opt/n810-modern/lib/lib*.so.3 ...
#
# Installs into ./out, laid out as it will sit on the device under
# /opt/n810-modern. Nothing here touches the device's own OpenSSL 0.9.8e.
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
#
# -DBROKEN_CLANG_ATOMICS is the load-bearing one, and its name is misleading:
# there is no clang here. It is OpenSSL's supported switch to turn off the
# __atomic_* builtins in crypto/threads_pthread.c -- the only file that uses
# them -- and fall back to mutexes. Without it, GCC emits calls to 64-bit
# atomics that ARMv6 cannot do inline, which pulls in libatomic.so.1. Every
# 64-bit entry point in GCC's libatomic is an IFUNC, and glibc 2.5 predates
# IFUNC, so the device's loader cannot resolve a single one of them:
#     relocation error: libcrypto.so.3: symbol __atomic_fetch_add_8,
#     version LIBATOMIC_1.0 not defined in file libatomic.so.1
# Bundling libatomic does not help and neither does libatomic.a, which is
# IFUNC-based too. Mutex fallbacks cost nothing measurable on one 400 MHz
# core. See BUILDLOG.md and tools/qemu-smoke.sh, which is how this was found.
./Configure linux-armv4 \
  --prefix=/opt/n810-modern \
  --openssldir=/opt/n810-modern/ssl \
  --with-rand-seed=devrandom \
  --libdir=lib \
  -DBROKEN_CLANG_ATOMICS \
  shared threads no-tests no-docs no-afalgeng no-async

echo "==> Building (-j$JOBS)"
make -j"$JOBS"

echo "==> Staging into $OUT"
rm -rf "$OUT" && make DESTDIR="$OUT" install_sw install_ssldirs

# libatomic must not appear. It used to be bundled here; that was wrong. Its
# 64-bit atomics are all IFUNCs and glibc 2.5 cannot resolve IFUNC symbols, so
# a build that still needs libatomic is a build that cannot start on the
# device. -DBROKEN_CLANG_ATOMICS above is what keeps it away. If this fires,
# something re-enabled the __atomic_* builtins -- fix that, do not ship a copy.
# Captured, not piped: `set -o pipefail` with `grep -q` reports SIGPIPE (141)
# on a match, so a piped test here would never fire. See check-artifact.sh.
libcrypto_needed=$($TARGET-readelf -d "$OUT/opt/n810-modern/lib/libcrypto.so.3" 2>/dev/null || true)
if grep -q 'libatomic\.so\.1' <<<"$libcrypto_needed"; then
  echo "FAIL: libcrypto still needs libatomic.so.1."
  echo "      glibc 2.5 cannot resolve its IFUNC symbols. See the Configure"
  echo "      comment above and BUILDLOG.md."
  exit 1
fi

# OpenSSL still records -latomic in its installed metadata even though
# -DBROKEN_CLANG_ATOMICS means the library does not reference it. Left alone,
# the next package to link against us picks it up from pkg-config:
#     libcrypto.pc:  Libs.private: -ldl -pthread -latomic
# and re-acquires the exact DT_NEEDED that could not load on the device (§7).
# Autotools of Diablo's era do not pass --as-needed, so it would stick. Scrub
# it from the metadata, then prove it is gone.
echo "==> Scrubbing -latomic from installed metadata"
mapfile -t metadata < <(find "$OUT" \( -name '*.pc' -o -name '*.cmake' \) -type f)
for m in "${metadata[@]}"; do
  sed -i 's/ -latomic//g' "$m"
done
# Scoped to the metadata files on purpose: a blanket grep over $OUT would also
# read the stripped binaries and could fail the build on an incidental match.
left=$(grep -l 'latomic' "${metadata[@]}" 2>/dev/null || true)
if [ -n "$left" ]; then
  echo "FAIL: -latomic still referenced in:"
  printf '      %s\n' $left
  exit 1
fi
echo "    ${#metadata[@]} metadata files clean"

echo "==> Stripping"
find "$OUT" -type f \( -name '*.so*' -o -perm -u+x \) -print0 |
  while IFS= read -r -d '' f; do
    file "$f" | grep -q 'ELF 32-bit.*ARM' && "$STRIP" --strip-unneeded "$f" || true
  done

echo "==> Verifying"
mapfile -t artefacts < <(find "$OUT" -type f \( -name '*.so*' -o -name openssl \) | sort)
EXTRA_LIBDIR="$OUT/opt/n810-modern/lib" "$HERE/check-artifact.sh" "${artefacts[@]}"

echo
echo "Staged tree ($(du -sh "$OUT" | cut -f1)):"
find "$OUT" -maxdepth 4 -type d | sed "s|$OUT|  |"
cat <<EOF

Next:
  1. Copy $OUT/opt/n810-modern to the device as /opt/n810-modern
     (put it on the 2 GB internal flash, not the 256 MB rootfs).
  2. On the device:
       export LD_LIBRARY_PATH=/opt/n810-modern/lib
       /opt/n810-modern/bin/openssl version -a
       /opt/n810-modern/bin/openssl s_client -connect example.org:443 -tls1_3
  3. If step 2 dies with "FATAL: kernel too old", the ABI note check was
     bypassed -- see tools/env.sh.
EOF
