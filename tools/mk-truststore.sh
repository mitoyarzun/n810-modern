#!/usr/bin/env bash
# Stage a current CA trust store into the built tree.
#
#   tools/mk-truststore.sh [out-dir]
#
# Without this, a modern OpenSSL still fails on the device -- later, and more
# confusingly, with "unable to get local issuer certificate" rather than a
# handshake failure. The stock 0.9.8e trust store is from 2008 and every root
# in it is either expired or no longer trusted.
#
# Mozilla's full store, as curl publishes it. OPEN.md #6 asks whether to trim
# it for a 128 MB device; the answer is not yet, because a trimmed store is a
# maintenance burden and the file is small next to what it enables.
#
# Fetched over HTTPS, from the build host, which has working TLS. That is the
# whole shape of this project: the modern host bootstraps the old device.
set -euo pipefail

OUT="${1:-$PWD/out}"
PREFIX="$OUT/opt/n810-modern"
URL="https://curl.se/ca/cacert.pem"
SHA_URL="https://curl.se/ca/cacert.pem.sha256"

[ -d "$PREFIX/ssl" ] || { echo "no staged tree at $PREFIX -- run tools/build-openssl.sh"; exit 1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

echo "==> Fetching $URL"
curl -fsSL --retry 3 -o "$tmp/cacert.pem" "$URL"

# curl.se publishes a checksum beside it. Verify rather than trust the transport.
if curl -fsSL --retry 3 -o "$tmp/cacert.pem.sha256" "$SHA_URL"; then
  want=$(cut -d' ' -f1 < "$tmp/cacert.pem.sha256")
  got=$(sha256sum < "$tmp/cacert.pem" | cut -d' ' -f1)
  if [ "$want" != "$got" ]; then
    echo "FAIL: checksum mismatch"; echo "  want $want"; echo "  got  $got"; exit 1
  fi
  echo "    sha256 ok"
else
  echo "    WARNING: no published checksum fetched; not verified"
fi

roots=$(grep -c 'BEGIN CERTIFICATE' "$tmp/cacert.pem")
install -m 0644 "$tmp/cacert.pem" "$PREFIX/ssl/cert.pem"

echo
echo "    installed  $PREFIX/ssl/cert.pem"
echo "    roots      $roots"
echo "    size       $(du -h "$PREFIX/ssl/cert.pem" | cut -f1)"
echo
echo "On the device this lands at /opt/n810-modern/ssl/cert.pem, which is the"
echo "OPENSSLDIR compiled into the library, so nothing needs configuring."
echo
echo "Verify with:  tools/qemu-smoke.sh   (section 4 must report no verify error)"
