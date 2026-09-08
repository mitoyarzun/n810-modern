#!/usr/bin/env bash
# Run the built artefacts under QEMU user-mode emulation, against the DEVICE'S
# OWN glibc 2.5 loader from the sysroot. No tablet needed.
#
#   tools/qemu-smoke.sh [out-dir] [sysroot-dir]
#
# What this catches, and check-artifact.sh cannot:
#   - anything the 2006 loader refuses to resolve (IFUNC symbols, above all)
#   - missing libraries at their real load paths
#   - startup crashes, bad relocations, provider loading
#   - real TLS handshakes, over the build host's network
#
# What it does NOT prove: that the real 2.6.21 kernel accepts every syscall
# OpenSSL makes. qemu-arm implements a modern kernel's syscall set and only
# pretends to be old when told to. The tablet is still the final word.
#
# Needs qemu-arm (Debian/Ubuntu: qemu-user). Nothing else.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$PWD/out}"
SYSROOT="${2:-${DIABLO_SYSROOT:-$PWD/sysroot-diablo}}"
PREFIX="$OUT/opt/handshake"
rc=0

command -v qemu-arm >/dev/null || { echo "qemu-arm not found -- apt install qemu-user"; exit 1; }
[ -d "$SYSROOT/lib" ] || { echo "no sysroot at $SYSROOT -- run tools/mk-sysroot.sh"; exit 1; }
[ -x "$PREFIX/bin/openssl" ] || { echo "no openssl at $PREFIX/bin -- run tools/build-openssl.sh"; exit 1; }

# The sysroot IS the device's userland, so -L makes qemu resolve ld-linux.so.3,
# libc.so.6 and friends from glibc 2.5 exactly as the tablet would.
#
# OPENSSL_MODULES and OPENSSL_CONF are redirected because the library was built
# with absolute device paths (/opt/handshake/...) baked in, which is correct for
# the tablet and wrong for a build host where the tree sits under ./out. Without
# them the legacy provider fails to load here and looks like a build fault:
#     legacy.so: cannot open shared object file: No such file or directory
# SSL_CERT_FILE is set only if a trust store has been staged; see section 4.
run() {
  qemu-arm -L "$SYSROOT" \
    -E LD_LIBRARY_PATH="$PREFIX/lib" \
    -E OPENSSL_MODULES="$PREFIX/lib/ossl-modules" \
    -E OPENSSL_ENGINES="$PREFIX/lib/engines-3" \
    ${CERT_FILE:+-E SSL_CERT_FILE="$CERT_FILE"} \
    "$@"
}

# A trust store is staged by step 3 of NEXT.md and may not exist yet.
CERT_FILE=""
for c in "$PREFIX/ssl/cert.pem" "$PREFIX/ssl/certs/ca-certificates.crt"; do
  [ -s "$c" ] && { CERT_FILE="$c"; break; }
done

check() { # description, then command
  local what="$1"; shift
  local o
  if o=$("$@" 2>&1); then
    printf '   ok    %s\n' "$what"
    [ -n "${VERBOSE:-}" ] && printf '%s\n' "$o" | sed 's/^/         /'
  else
    printf '   FAIL  %s\n' "$what"
    printf '%s\n' "$o" | sed 's/^/         /'
    rc=1
  fi
}

echo "== Under QEMU, on the device's own glibc 2.5 loader"
echo "   sysroot  $SYSROOT"
echo "   prefix   $PREFIX"
echo

echo "1. It starts at all"
check "openssl version"      run "$PREFIX/bin/openssl" version
VERBOSE=1 check "openssl version -a" run "$PREFIX/bin/openssl" version -a

echo
echo "2. Providers load"
check "default provider"     run "$PREFIX/bin/openssl" list -providers
check "legacy provider"      run "$PREFIX/bin/openssl" list -providers -provider legacy

echo
echo "3. Crypto works"
check "sha256"               sh -c "echo handshake | qemu-arm -L '$SYSROOT' -E LD_LIBRARY_PATH='$PREFIX/lib' '$PREFIX/bin/openssl' dgst -sha256"
check "random"               run "$PREFIX/bin/openssl" rand -hex 16
check "rsa keygen"           run "$PREFIX/bin/openssl" genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048
check "ec keygen"            run "$PREFIX/bin/openssl" genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256

echo
echo "4. A real TLS 1.3 handshake, over this host's network"
HOST="${SMOKE_HOST:-example.org}"
if [ -n "$CERT_FILE" ]; then
  echo "   trust store: $CERT_FILE"
else
  echo "   trust store: none staged yet (NEXT.md step 3) -- expect a verify error"
fi
if out=$(printf 'GET / HTTP/1.0\r\nHost: %s\r\n\r\n' "$HOST" |
         run "$PREFIX/bin/openssl" s_client -connect "$HOST:443" -servername "$HOST" \
             -tls1_3 -brief 2>&1); then
  printf '   ok    TLS 1.3 to %s\n' "$HOST"
  printf '%s\n' "$out" | grep -E 'Protocol|Ciphersuite|Peer certificate|Verification' | sed 's/^/         /'
  # A verify failure with no trust store is expected; with one, it is a failure.
  if printf '%s\n' "$out" | grep -q 'Verification error'; then
    if [ -n "$CERT_FILE" ]; then
      printf '   FAIL  certificate did not verify against %s\n' "$CERT_FILE"; rc=1
    else
      printf '   note  no trust store yet, so the verify error is expected\n'
    fi
  fi
else
  printf '   FAIL  TLS 1.3 to %s\n' "$HOST"
  printf '%s\n' "$out" | tail -15 | sed 's/^/         /'
  rc=1
fi

echo "5. Speed, for the record (DESIGN.md predicts ChaCha20 beats AES-GCM here)"
echo "   NOTE: these are QEMU numbers on the build host. They say nothing about"
echo "   the real 400 MHz ARM1136. Measure on the device before believing them."

echo
[ $rc -eq 0 ] && echo "QEMU smoke test passed." || echo "FAILURES ABOVE."
exit $rc
