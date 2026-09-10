#!/usr/bin/env bash
# Cross-build OpenSSH for Maemo Diablo, against our OpenSSL and zlib.
#
#   tools/build-openssl.sh              # first
#   tools/build-zlib.sh
#   tools/build-openssh.sh
#
# The device ships openssh 3.8p1 from 2004, if it ships it at all -- a stock
# Diablo install has no ssh. That matters beyond security: with no ssh, no
# curl and no wget, there is no way onto the device except the on-screen
# keyboard and USB mass storage.
#
# This is the package that changes how you work with the tablet.
set -euo pipefail

VERSION="${OPENSSH_VERSION:-10.5p1}"
SHA256="d44d28a839ea9daf969cc69150fde59910b2b39361dad81a3bd6cbd19218db11"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$PWD/build}"
OUT="${OUT:-$PWD/out}"
JOBS="${JOBS:-$(nproc)}"
SSLDIR="$OUT/opt/n810-modern"

# shellcheck source=env.sh
. "$HERE/env.sh" "${DIABLO_SYSROOT:-$PWD/sysroot-diablo}"

[ -f "$SSLDIR/lib/libssl.so.3" ] || {
  echo "no OpenSSL at $SSLDIR -- run tools/build-openssl.sh first"; exit 1; }
[ -f "$SSLDIR/lib/libz.so" ] || {
  echo "no zlib at $SSLDIR -- run tools/build-zlib.sh first"; exit 1; }

mkdir -p "$WORK" && cd "$WORK"
tarball="openssh-$VERSION.tar.gz"
if [ ! -f "$tarball" ]; then
  echo "==> Fetching OpenSSH $VERSION"
  curl -fsSL --retry 3 -O "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/$tarball"
fi
got=$(sha256sum < "$tarball" | cut -d' ' -f1)
[ "$got" = "$SHA256" ] || { echo "SHA256 MISMATCH: want $SHA256, got $got"; exit 1; }
echo "    sha256 ok"

rm -rf "openssh-$VERSION" && tar xzf "$tarball" && cd "openssh-$VERSION"

echo "==> Configuring"
# --with-sandbox=no is the load-bearing one. Modern OpenSSH sandboxes its
# privilege-separated child with seccomp-bpf, which arrived in Linux 3.5.
# This kernel is 2.6.21, so configure's probe would pick something wrong or
# the daemon would die at runtime when the sandbox failed to arm.
#
# --without-pam: Diablo has no PAM stack.
# --disable-strip: tools/env.sh strips deliberately, later, with the cross
#   strip; letting configure do it invokes the host's.
#
# ac_cv_* cache variables answer questions configure would otherwise settle by
# RUNNING a test program, which cross-compiling cannot do. Each is a property
# of glibc 2.5 on ARM, not a preference.
CC="$CC -I$SSLDIR/include" \
LDFLAGS="$LDFLAGS -L$SSLDIR/lib" \
./configure \
  --host=arm-linux-gnueabi \
  --prefix=/opt/n810-modern \
  --sysconfdir=/opt/n810-modern/etc/ssh \
  --with-ssl-dir="$SSLDIR" \
  --with-zlib="$SSLDIR" \
  --with-privsep-path=/opt/n810-modern/var/empty \
  --with-sandbox=no \
  --without-pam \
  --disable-strip \
  ac_cv_func_setresuid=yes \
  ac_cv_func_setresgid=yes

echo "==> Building (-j$JOBS)"
make -j"$JOBS"

echo "==> Staging into $OUT"
make DESTDIR="$OUT" install-nokeys

echo "==> Stripping"
for f in ssh sshd sshd-session sshd-auth scp sftp ssh-add ssh-agent ssh-keygen \
         ssh-keyscan sftp-server ssh-keysign; do
  for p in "$OUT/opt/n810-modern/bin/$f" "$OUT/opt/n810-modern/sbin/$f" \
           "$OUT/opt/n810-modern/libexec/$f"; do
    [ -f "$p" ] || continue
    file "$p" | grep -q 'ELF 32-bit.*ARM' && "$STRIP" --strip-unneeded "$p" || true
  done
done

echo "==> Verifying"
mapfile -t artefacts < <(find "$OUT/opt/n810-modern" -type f \
  \( -name 'ssh' -o -name 'sshd' -o -name 'sshd-session' -o -name 'scp' \
     -o -name 'sftp' -o -name 'ssh-keygen' \) | sort)
[ ${#artefacts[@]} -gt 0 ] || { echo "no ARM binaries were built"; exit 1; }
EXTRA_LIBDIR="$OUT/opt/n810-modern/lib" "$HERE/check-artifact.sh" "${artefacts[@]}"

cat <<INFO

Built: ${artefacts[*]}

Host keys are NOT generated here -- they must be made on the device, once:
  /opt/n810-modern/bin/ssh-keygen -A -f /opt/n810-modern

Then run the daemon:
  /opt/n810-modern/sbin/sshd -f /opt/n810-modern/etc/ssh/sshd_config
INFO
