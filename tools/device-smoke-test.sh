#!/bin/sh
# Run this ON THE N810 (or N800), not on the build host.
#
#   scp -r out/opt/n810-modern tools/device-smoke-test.sh root@tablet:/opt/
#   ssh root@tablet 'sh /opt/device-smoke-test.sh'
#
# Deliberately /bin/sh and POSIX-only: Diablo has BusyBox ash, not bash.
# Deliberately read-only: it changes nothing on the device.
PREFIX=${PREFIX:-/opt/n810-modern}
SSL=$PREFIX/bin/openssl
export LD_LIBRARY_PATH=$PREFIX/lib

say() { echo; echo "=== $1"; }
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fails=$((fails+1)); }
fails=0

say "0. Record the device as it actually is"
uname -a
echo "--- stock TLS stack:"
dpkg -l 2>/dev/null | grep -iE 'ssl|gnutls|nss|libc6|zlib' | awk '{print "   ", $2, $3}'
echo "--- stock openssl:"
openssl version 2>/dev/null || echo "    (no openssl in PATH)"
echo "--- free space:"
df -h / /media/mmc1 /media/mmc2 2>/dev/null | grep -v '^Filesystem'
echo "--- clock (certificates fail if this is wrong):"
date

say "1. Does anything we built run at all?"
# This is the real gate. If the ABI note is wrong the loader refuses outright.
if [ -x "$SSL" ]; then
  if out=$("$SSL" version 2>&1); then ok "$out"
  else
    bad "openssl will not start: $out"
    case "$out" in
      *"kernel too old"*) echo "       -> ABI note wrong; see tools/env.sh (-B flag)" ;;
      *"not found"*)      echo "       -> LD_LIBRARY_PATH=$PREFIX/lib not picked up" ;;
    esac
  fi
else
  bad "$SSL missing or not executable"
fi

say "2. Which protocols does it actually offer?"
"$SSL" ciphers -v 'ALL' 2>/dev/null | awk '{print $2}' | sort -u | tr '\n' ' '; echo
for p in tls1_2 tls1_3; do
  "$SSL" ciphers -"$p" >/dev/null 2>&1 && ok "$p supported" || bad "$p NOT supported"
done

say "3. Entropy — we configured devrandom-only seeding"
[ -r /dev/urandom ] && ok "/dev/urandom readable" || bad "/dev/urandom not readable"
"$SSL" rand -hex 16 >/dev/null 2>&1 && ok "RNG produces output" || bad "RNG failed"

say "4. A real handshake (needs network)"
# badssl and howsmyssl are stable test endpoints; example.org is the control.
for host in example.org www.howsmyssl.com; do
  if echo | "$SSL" s_client -connect "$host":443 -servername "$host" \
       -CApath "$PREFIX/ssl/certs" -brief 2>&1 | grep -q 'Protocol version\|Verification'; then
    ok "handshake with $host"
    echo | "$SSL" s_client -connect "$host":443 -servername "$host" \
      -CApath "$PREFIX/ssl/certs" -brief 2>&1 | sed -n 's/^/       /p' | head -8
  else
    bad "handshake with $host failed"
  fi
done

say "5. Compare against the stock stack (this is expected to FAIL)"
# If the old openssl also succeeds, something is wrong with the premise.
if echo | openssl s_client -connect example.org:443 2>&1 | grep -q 'Cipher.*:.*[A-Z]'; then
  echo "  note  stock 0.9.8e ALSO connected -- unexpected, investigate"
else
  ok "stock 0.9.8e cannot connect, as expected"
fi

say "6. Speed — is ChaCha20 really the right default here?"
# DESIGN.md predicts ChaCha20-Poly1305 beats AES-GCM on this core (no NEON,
# no crypto extensions). Confirm or correct that with numbers.
"$SSL" speed -seconds 3 chacha20-poly1305 aes-128-gcm sha256 2>&1 | tail -12
echo
echo "  handshake latency:"
"$SSL" s_time -connect example.org:443 -new -time 10 2>&1 | tail -3

say "Result"
if [ "$fails" -eq 0 ]; then
  echo "  All checks passed. Record the numbers above in BUILDLOG.md."
else
  echo "  $fails check(s) failed. See OPEN.md."
fi
exit $fails
