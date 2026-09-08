#!/usr/bin/env bash
# Prove stunnel does the thing it exists for, without the device.
#
#   tools/qemu-stunnel-test.sh [out-dir] [sysroot-dir]
#
# Runs our armel stunnel under qemu-arm on the device's own glibc 2.5 loader,
# in client mode, and then speaks PLAIN HTTP to it. If a plain-HTTP request
# comes back with a page fetched over TLS 1.3, that is the whole value of the
# package: a stock Diablo application, which cannot do modern TLS and will
# never be rebuilt, reaches a modern site by pointing at localhost.
#
# What this does not prove: the real 2.6.21 kernel. See tools/qemu-smoke.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$PWD/out}"
SYSROOT="${2:-${DIABLO_SYSROOT:-$PWD/sysroot-diablo}}"
PREFIX="$OUT/opt/handshake"
HOSTNAME_="${SMOKE_HOST:-example.org}"
PORT="${SMOKE_PORT:-18443}"
rc=0

command -v qemu-arm >/dev/null || { echo "qemu-arm not found -- apt install qemu-user"; exit 1; }
command -v curl >/dev/null    || { echo "curl not found"; exit 1; }
[ -x "$PREFIX/bin/stunnel" ]  || { echo "no stunnel at $PREFIX/bin -- run tools/build-stunnel.sh"; exit 1; }
[ -s "$PREFIX/ssl/cert.pem" ] || { echo "no trust store -- run tools/mk-truststore.sh"; exit 1; }

tmp=$(mktemp -d)
pid=""
cleanup() { [ -n "$pid" ] && kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

# Paths in the config are opened by the guest process, and qemu user-mode passes
# them through to the real filesystem -- so these are host paths, not sysroot
# ones. Only the loader and the shared libraries come from -L.
cat > "$tmp/stunnel.conf" <<CONF
foreground = yes
pid =
# debug = 6, not 4. stunnel logs the negotiated protocol and the verified
# chain at level 6 (info); at 4 the connection succeeds and says nothing, so
# the test passes the traffic and then fails for lack of evidence.
debug = 6
output = $tmp/stunnel.log

[https]
client = yes
accept = 127.0.0.1:$PORT
connect = $HOSTNAME_:443
sni = $HOSTNAME_
CAfile = $PREFIX/ssl/cert.pem
verifyChain = yes
checkHost = $HOSTNAME_
sslVersionMin = TLSv1.3
CONF

echo "== stunnel under QEMU, on the device's own glibc 2.5 loader"
echo "   binary   $PREFIX/bin/stunnel"
echo "   route    plain HTTP 127.0.0.1:$PORT  ->  TLS 1.3 $HOSTNAME_:443"
echo

echo "1. It starts at all"
ver=$(qemu-arm -L "$SYSROOT" -E LD_LIBRARY_PATH="$PREFIX/lib" \
        "$PREFIX/bin/stunnel" -version 2>&1)
if grep -q 'stunnel' <<<"$ver"; then
  echo "   ok    stunnel -version"
  grep -E 'stunnel [0-9]|Compiled|Running with|Threading|Sockets|TLS:' <<<"$ver" | sed 's/^/         /'
else
  echo "   FAIL  stunnel -version"
  sed 's/^/         /' <<<"$ver"
  exit 1
fi

echo
echo "2. It runs as a client tunnel"
qemu-arm -L "$SYSROOT" -E LD_LIBRARY_PATH="$PREFIX/lib" \
  "$PREFIX/bin/stunnel" "$tmp/stunnel.conf" >"$tmp/stdout.log" 2>&1 &
pid=$!

# Poll for the listener rather than sleeping a guessed interval.
for _ in $(seq 1 60); do
  if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/" 2>/dev/null; then break; fi
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.5
done

if ! kill -0 "$pid" 2>/dev/null; then
  echo "   FAIL  stunnel exited during startup"
  tail -20 "$tmp/stunnel.log" "$tmp/stdout.log" 2>/dev/null | sed 's/^/         /'
  exit 1
fi
echo "   ok    listening on 127.0.0.1:$PORT"

echo
echo "3. Plain HTTP in, TLS 1.3 out"
body=$(curl -s -i --max-time 30 "http://127.0.0.1:$PORT/" -H "Host: $HOSTNAME_" 2>&1)
status=$(head -1 <<<"$body")
if grep -qE '^HTTP/1\.[01] [23][0-9][0-9]' <<<"$status"; then
  echo "   ok    $status"
  echo "         $(grep -ciE '^' <<<"$body") lines returned through the tunnel"
else
  echo "   FAIL  no usable HTTP response"
  sed 's/^/         /' <<<"$status"
  rc=1
fi

# The point is not that a page came back. It is that stunnel negotiated TLS 1.3
# and verified the chain on the way. Its own log is the evidence.
echo
echo "4. What stunnel negotiated"
# Filter out the CA-loading lines first: the trust store is 121 roots and each
# one logs a line at this level, which buries the four lines that matter.
evidence=$(grep -v 'Configured trusted server CA' "$tmp/stunnel.log" 2>/dev/null |
           grep -E 'Certificate accepted at depth=0|TLSv1\.3 ciphersuite|Negotiated TLSv1\.3 group|TLS connected')
if grep -q 'TLSv1\.3 ciphersuite' <<<"$evidence"; then
  sed 's/.*LOG[0-9]\[[^]]*\]: //; s/^/         /' <<<"$evidence" | sort -u
  echo "   ok    TLS 1.3 negotiated, chain verified to the leaf"
else
  echo "   FAIL  no TLS 1.3 evidence in the stunnel log"
  tail -20 "$tmp/stunnel.log" 2>/dev/null | sed 's/^/         /'
  rc=1
fi

echo
[ $rc -eq 0 ] && echo "stunnel QEMU test passed." || echo "FAILURES ABOVE."
exit $rc
