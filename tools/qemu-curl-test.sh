#!/usr/bin/env bash
# Prove curl fetches a real page over TLS 1.3, on the device's own glibc 2.5.
#
#   tools/qemu-curl-test.sh [out-dir] [sysroot-dir]
#
# The device ships libcurl3 7.15.5 against OpenSSL 0.9.8e and cannot complete a
# modern handshake. This is the replacement doing what that cannot.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$PWD/out}"
SYSROOT="${2:-${DIABLO_SYSROOT:-$PWD/sysroot-diablo}}"
PREFIX="$OUT/opt/n810-modern"
HOST="${SMOKE_HOST:-example.org}"
rc=0

command -v qemu-arm >/dev/null || { echo "qemu-arm not found -- apt install qemu-user"; exit 1; }
[ -x "$PREFIX/bin/curl" ]     || { echo "no curl at $PREFIX/bin -- run tools/build-curl.sh"; exit 1; }
[ -s "$PREFIX/ssl/cert.pem" ] || { echo "no trust store -- run tools/mk-truststore.sh"; exit 1; }

run() {
  qemu-arm -L "$SYSROOT" -E LD_LIBRARY_PATH="$PREFIX/lib" \
    -E CURL_CA_BUNDLE="$PREFIX/ssl/cert.pem" "$@"
}

echo "== curl under QEMU, on the device's own glibc 2.5"
echo

echo "1. It starts, and what it was built against"
if out=$(run "$PREFIX/bin/curl" --version 2>&1); then
  echo "   ok    curl --version"
  printf '%s\n' "$out" | head -2 | sed 's/^/         /'
else
  echo "   FAIL  curl --version"; printf '%s\n' "$out" | sed 's/^/         /'; exit 1
fi

echo
echo "2. Fetch over TLS 1.3, verifying the chain"
# curl has no --write-out variable for the negotiated protocol or cipher, so
# take them from the verbose handshake trace rather than inventing one.
if out=$(run "$PREFIX/bin/curl" -sS -v --tlsv1.3 -o /dev/null \
           -w 'http=%{http_code} size=%{size_download} verify=%{ssl_verify_result}\n' \
           "https://$HOST/" 2>&1); then
  echo "   ok    $(printf '%s\n' "$out" | grep -E '^http=')"
  printf '%s\n' "$out" | grep -E 'SSL connection using|subject:|issuer:' |
    sed 's/^\* */         /' | head -3
else
  echo "   FAIL  fetch"; printf '%s\n' "$out" | tail -5 | sed 's/^/         /'; rc=1
fi

echo
echo "3. Certificate verification is actually on"
# Point at a host whose chain must fail, and confirm curl refuses it. A test
# that only ever sees success cannot tell you verification works.
if out=$(run "$PREFIX/bin/curl" -sS --max-time 30 -o /dev/null \
           "https://expired.badssl.com/" 2>&1); then
  echo "   FAIL  expired certificate was ACCEPTED"; rc=1
else
  echo "   ok    expired certificate rejected"
  printf '%s\n' "$out" | head -1 | sed 's/^/         /'
fi

echo
echo "4. gzip content-encoding, which is why we ship our own zlib"
if out=$(run "$PREFIX/bin/curl" -sS --compressed -o /dev/null \
           -w 'http=%{http_code} downloaded=%{size_download}\n' \
           "https://$HOST/" 2>&1); then
  echo "   ok    $out"
else
  echo "   FAIL  --compressed"; printf '%s\n' "$out" | sed 's/^/         /'; rc=1
fi

echo
[ $rc -eq 0 ] && echo "curl QEMU test passed." || echo "FAILURES ABOVE."
exit $rc
