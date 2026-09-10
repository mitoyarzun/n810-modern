#!/usr/bin/env bash
# Package the build as .deb files a stock Diablo device can install.
#
#   tools/build-in-docker.sh                  # produces out/opt/handshake
#   tools/mk-kernel-2621-backport.sh          # produces the kernel (optional)
#   tools/mk-debs.sh
#
# Result: dist/*.deb, installable with `dpkg -i` on the tablet. No compiler, no
# cross-toolchain, no 4 GB of kernel source.
#
# THE ONE THING THAT WILL BITE YOU: compression. Modern dpkg-deb defaults to
# xz or zstd. Diablo ships dpkg 1.13, which understands gzip and nothing else,
# and the failure is not obvious -- the package simply refuses to install on
# the device while working fine on your desktop. Hence -Zgzip everywhere.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-$PWD/out}"
DIST="${DIST:-$PWD/dist}"
STAGE="$OUT/opt/handshake"
KERNEL="${KERNEL:-}"
VERSION="${VERSION:-1.0}"
MAINTAINER="${MAINTAINER:-Jaime Oyarzun Knittel <mito.oyarzun@gmail.com>}"

[ -d "$STAGE" ] || { echo "no build at $STAGE -- run tools/build-in-docker.sh first"; exit 1; }
command -v dpkg-deb >/dev/null || { echo "dpkg-deb not found -- apt install dpkg"; exit 1; }

mkdir -p "$DIST"
BUILD="$DIST/.deb-build"
rm -rf "$BUILD"; mkdir -p "$BUILD"

# The install prefix is NOT arbitrary. Every binary here has
# -Wl,-rpath,/opt/handshake/lib baked in, so the libraries must land exactly
# there or nothing runs. See CAVEATS.md.
PREFIX=opt/handshake

# ---------------------------------------------------------------- helpers ---

# Copy a list of paths (relative to $STAGE) into a package root, preserving
# symlinks and modes.
stage_into() {
  local root="$1"; shift
  local p
  for p in "$@"; do
    [ -e "$STAGE/$p" ] || continue
    mkdir -p "$root/$PREFIX/$(dirname "$p")"
    cp -a "$STAGE/$p" "$root/$PREFIX/$(dirname "$p")/"
  done
}

build_deb() {
  local root="$1" name="$2"
  chmod -R go-w "$root"
  find "$root" -type d -exec chmod 755 {} +
  # -Zgzip: see the note at the top. Diablo's dpkg cannot read anything else.
  dpkg-deb -Zgzip --build "$root" "$DIST" > /dev/null
  local f
  f=$(ls -t "$DIST"/${name}_*.deb 2>/dev/null | head -1)
  printf "    %-34s %s\n" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
}

control() {
  local root="$1" name="$2" depends="$3" desc="$4" long="$5"
  mkdir -p "$root/DEBIAN"
  {
    echo "Package: $name"
    echo "Version: $VERSION"
    echo "Architecture: armel"
    echo "Maintainer: $MAINTAINER"
    echo "Section: net"
    echo "Priority: optional"
    [ -n "$depends" ] && echo "Depends: $depends"
    echo "Description: $desc"
    echo "$long" | sed 's/^/ /'
  } > "$root/DEBIAN/control"
}

echo "==> Packaging $STAGE"

# ------------------------------------------------------------ tls runtime ---
R="$BUILD/n810-modern-tls"
stage_into "$R" \
  lib/libcrypto.so.3 lib/libssl.so.3 lib/libz.so.1 lib/libz.so.1.3.2 \
  lib/libcurl.so.4 lib/libcurl.so.4.8.0 lib/ossl-modules lib/engines-3 \
  bin/openssl bin/curl bin/wcurl bin/c_rehash bin/stunnel bin/stunnel3 \
  lib/stunnel/libstunnel.so \
  etc ssl var
# Library sonames are symlinks; carry whatever variants exist.
for so in libcrypto libssl libz libcurl; do
  for f in "$STAGE"/lib/$so.so*; do
    [ -e "$f" ] || continue
    mkdir -p "$R/$PREFIX/lib"; cp -a "$f" "$R/$PREFIX/lib/"
  done
done
control "$R" n810-modern-tls "" \
  "modern TLS for Maemo Diablo (OpenSSL 3.5, curl, stunnel)" \
"Diablo ships OpenSSL 0.9.8e, which tops out at TLS 1.0 with no ECDHE, no
AES-GCM and no SNI. Modern servers require TLS 1.2/1.3 with ECDHE and an AEAD
cipher, so there is no overlap and the connection dies at ClientHello.
.
This installs OpenSSL 3.5, zlib, curl and stunnel under /opt/handshake,
alongside the stock libraries rather than over them. Nothing already on the
device changes.
.
  export LD_LIBRARY_PATH=/opt/handshake/lib
  /opt/handshake/bin/curl https://example.org/
.
stunnel lets applications that cannot be rebuilt reach modern TLS: they speak
plain HTTP to localhost and stunnel does the handshake."
build_deb "$R" n810-modern-tls

# -------------------------------------------------------------------- ssh ---
R="$BUILD/n810-modern-ssh"
stage_into "$R" \
  bin/ssh bin/scp bin/sftp bin/ssh-add bin/ssh-agent bin/ssh-keygen \
  bin/ssh-keyscan sbin/sshd libexec
control "$R" n810-modern-ssh "n810-modern-tls (>= $VERSION)" \
  "OpenSSH 10.5 for Maemo Diablo" \
"A stock Diablo install has no ssh at all. With no ssh, no curl and no wget
there is no way onto the device except the on-screen keyboard and USB mass
storage, so this is the package that changes how you work with the tablet.
.
Host keys are not shipped. Generate them once on the device:
.
  /opt/handshake/bin/ssh-keygen -A -f /opt/handshake
  /opt/handshake/sbin/sshd -f /opt/handshake/etc/ssh/sshd_config
.
Built with --with-sandbox=no: modern OpenSSH sandboxes its privilege-separated
child with seccomp-bpf, which arrived in Linux 3.5. This kernel is 2.6.21."
build_deb "$R" n810-modern-ssh

# -------------------------------------------------------------------- dev ---
R="$BUILD/n810-modern-tls-dev"
stage_into "$R" include lib/pkgconfig lib/cmake bin/curl-config share/aclocal
for f in "$STAGE"/lib/*.a "$STAGE"/lib/libcrypto.so "$STAGE"/lib/libssl.so \
         "$STAGE"/lib/libz.so "$STAGE"/lib/libcurl.so; do
  [ -e "$f" ] || continue
  mkdir -p "$R/$PREFIX/lib"; cp -a "$f" "$R/$PREFIX/lib/"
done
control "$R" n810-modern-tls-dev "n810-modern-tls (= $VERSION)" \
  "headers and link libraries for n810-modern-tls" \
"Headers, .pc files and development symlinks. Only needed to compile against
these libraries; the runtime package is enough to use them."
build_deb "$R" n810-modern-tls-dev

# ----------------------------------------------------------------- kernel ---
if [ -n "$KERNEL" ] && [ -f "$KERNEL" ]; then
  R="$BUILD/n810-modern-kernel"
  mkdir -p "$R/opt/n810-modern/boot" "$R/usr/sbin"
  cp -a "$KERNEL" "$R/opt/n810-modern/boot/zImage"
  cp -a "$HERE/deb/n810-modern-flash-kernel" "$R/usr/sbin/"
  chmod 755 "$R/usr/sbin/n810-modern-flash-kernel"
  control "$R" n810-modern-kernel "" \
    "Diablo 2.6.21 kernel with backported syscalls" \
"Nokia's own 2.6.21 kernel with the syscalls modern userspace needs:
FUTEX_WAIT_PRIVATE, epoll_create1, pipe2 and accept4. Every driver Nokia
shipped is still enabled -- DSP, MMC, DVFS and the cbus power drivers.
.
INSTALLING THIS PACKAGE DOES NOT FLASH ANYTHING. The kernel is placed in
/opt/n810-modern/boot/zImage. To install it, run:
.
  n810-modern-flash-kernel
.
which backs up the running kernel first. Flashing is reversible, but it is
still a flash: read what the script prints before answering."
  build_deb "$R" n810-modern-kernel
else
  echo "    (no kernel given; set KERNEL=/path/to/zImage to package one)"
fi

# ----------------------------------------------------------------- verify ---
# A packaging script that silently drops files is the exact failure this
# repository keeps documenting, so check rather than assume.
#
# Some things are left out ON PURPOSE. The device has 256 MB of flash and 547
# man pages is 3.5 MB of it. Declaring them here is what lets the check below
# tell a decision apart from an accident.
EXCLUDE='^share/man/|^share/doc/|\.la$'
echo "==> Checking that nothing was dropped by accident"
( cd "$STAGE" && find . -type f -o -type l ) | sed 's|^\./||' | sort > "$BUILD/.all"
( cd "$BUILD" && find . -path './*/opt/handshake/*' \( -type f -o -type l \) ) \
  | sed 's|^\./[^/]*/opt/handshake/||' | sort -u > "$BUILD/.packaged"
comm -23 "$BUILD/.all" "$BUILD/.packaged" > "$BUILD/.unpackaged" || true
grep -vE "$EXCLUDE" "$BUILD/.unpackaged" > "$BUILD/.unexplained" || true
skipped=$(grep -cE "$EXCLUDE" "$BUILD/.unpackaged" || true)
missing=$(wc -l < "$BUILD/.unexplained" | tr -d ' ')
echo "    $skipped file(s) left out on purpose (man pages, docs, libtool archives)"
if [ "$missing" != "0" ]; then
  echo "    $missing file(s) in NO package and NOT excluded:"
  sed 's/^/      /' "$BUILD/.unexplained"
  exit 1
else
  echo "    every other file is packaged"
fi

echo
echo "Install on the device with:"
echo "  dpkg -i n810-modern-tls_${VERSION}_armel.deb"
echo "  dpkg -i n810-modern-ssh_${VERSION}_armel.deb"
