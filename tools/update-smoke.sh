#!/usr/bin/env bash
# Exercise the update path with the device's own binaries.
#
#   tools/mk-debs.sh && tools/mk-pages-repo.sh
#   tools/update-smoke.sh
#
# This runs in USER-MODE qemu, not the full-system emulator, for one reason:
# the n810 machine has no working network. `tusb: Unable to detect TUSB6010`
# -- QEMU instantiates the USB bridge but does not emulate it, so nothing in
# the full-system emulator can reach a server. User-mode qemu translates
# syscalls to the host, so the device's curl gets the host's network.
#
# What this proves: the index parses, the download runs through the device's
# own curl, and the checksum is computed by the device's own openssl and
# compared correctly -- including that corruption and a 404 are both caught.
#
# What it does not prove: dpkg installation (tools/deb-smoke.sh covers that on
# the real userland) or the TLS handshake itself (tools/qemu-curl-test.sh
# covers that against a real host, including refusing a bad certificate).
set -euo pipefail

OUT="${1:-$PWD/out}"
DIST="${DIST:-$PWD/dist}"
DEBS="${DEBS:-$DIST/debs}"
DOCS="${DOCS:-$PWD/docs}"
SYSROOT="${DIABLO_SYSROOT:-$PWD/sysroot-diablo}"
PORT="${PORT:-8731}"
PREFIX="$OUT/opt/n810-modern"

[ -f "$DOCS/index.txt" ] || { echo "no index -- run tools/mk-pages-repo.sh"; exit 1; }
[ -x "$PREFIX/bin/curl" ] || { echo "no curl at $PREFIX"; exit 1; }
command -v qemu-arm >/dev/null || { echo "qemu-arm not found -- apt install qemu-user"; exit 1; }

# The real index points at a GitHub release. Serve the same packages locally
# and rewrite the URLs to match, so the test needs no published release and no
# network.
SERVE=$(mktemp -d)
trap 'rm -rf "$SERVE"; kill $SRV 2>/dev/null || true' EXIT
cp "$DEBS"/*.deb "$SERVE/"
sed -E "s#https://[^ ]*/#http://127.0.0.1:$PORT/#" "$DOCS/index.txt" > "$SERVE/index.txt"

echo "==> Serving the packages on 127.0.0.1:$PORT"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SERVE" >/dev/null 2>&1 &
SRV=$!
sleep 1

RUN="qemu-arm -L $SYSROOT -E LD_LIBRARY_PATH=$PREFIX/lib"
CURL="$PREFIX/bin/curl"
OPENSSL="$PREFIX/bin/openssl"

echo "==> The device's curl fetches the index"
$RUN "$CURL" -fsSL "http://127.0.0.1:$PORT/index.txt" -o "$SERVE/got-index"
echo "    $(grep -vc '^#' "$SERVE/got-index") packages listed"

echo "==> It fetches a package and the checksum matches"
row=$(grep -v '^#' "$SERVE/got-index" | grep '^n810-modern-tls ' | head -1)
want=$(echo "$row" | awk '{print $4}')
url=$(echo "$row" | awk '{print $5}')
$RUN "$CURL" -fsSL "$url" -o "$SERVE/pkg.deb"
got=$($RUN "$OPENSSL" dgst -sha256 "$SERVE/pkg.deb" | sed 's/.*= *//')
echo "    want $want"
echo "    got  $got"
[ "$want" = "$got" ] || { echo "    CHECKSUM MISMATCH"; exit 1; }
echo "    match"

echo "==> A corrupted download is rejected"
# The check must fail in both directions, or it is not a check.
printf 'x' >> "$SERVE/pkg.deb"
bad=$($RUN "$OPENSSL" dgst -sha256 "$SERVE/pkg.deb" | sed 's/.*= *//')
[ "$want" != "$bad" ] || { echo "    corruption went undetected"; exit 1; }
echo "    detected"

echo "==> A missing package is an error, not a silent success"
if $RUN "$CURL" -fsSL "http://127.0.0.1:$PORT/nope.deb" -o "$SERVE/nope.deb" 2>/dev/null; then
  echo "    FAIL: curl reported success for a 404"; exit 1
fi
echo "    curl --fail rejects the 404"

echo
echo "Update path smoke test passed."
