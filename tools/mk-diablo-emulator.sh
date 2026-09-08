#!/usr/bin/env bash
# Fetch the real Diablo firmware and unpack it into a bootable emulator setup.
#
#   tools/mk-diablo-emulator.sh [work-dir]     # default ./emulator
#
# This gets us the actual device: the real 2.6.21 kernel and the real 220 MB
# Diablo userland, from Nokia's own final release for the N810. With it,
# tools/emulator-smoke.sh answers the one question neither check-artifact.sh
# nor qemu-arm user-mode can -- whether the real kernel serves every syscall
# our binaries make.
#
# Needs: curl, 0xFFFF, python3 (for jefferson). On Debian/Ubuntu:
#   apt-get install 0xffff python3-venv curl
set -euo pipefail

WORK="${1:-$PWD/emulator}"

# RX-44 is the N810. 5.2008.43-7 is the last Diablo release Nokia shipped for
# it. tablets-dev.nokia.com has been dead for years; skeiron.org mirrors it,
# and the MD5 below is the one Nokia published in MD5SUMS beside the file.
IMAGE="RX-44_DIABLO_5.2008.43-7_PR_COMBINED_MR0_ARM.bin"
BASE="http://maemo.wunderwungiel.pl/skeiron.org/nokia_N810"
MD5="a0738fcc7b556d1c6d49d796b48a7a37"

mkdir -p "$WORK" && cd "$WORK"

if [ ! -f "$IMAGE" ] || [ "$(md5sum < "$IMAGE" | cut -d' ' -f1)" != "$MD5" ]; then
  echo "==> Fetching $IMAGE (124 MB)"
  curl -fsSL --retry 3 -A "Mozilla/5.0 (X11; Linux x86_64)" -e "$BASE/" \
       -o "$IMAGE.part" "$BASE/$IMAGE"
  got=$(md5sum < "$IMAGE.part" | cut -d' ' -f1)
  [ "$got" = "$MD5" ] || { echo "MD5 MISMATCH: want $MD5, got $got"; rm -f "$IMAGE.part"; exit 1; }
  mv "$IMAGE.part" "$IMAGE"
fi
echo "    md5 ok"

command -v 0xFFFF >/dev/null || { echo "0xFFFF not found -- apt install 0xffff"; exit 1; }

if [ ! -d unpacked ]; then
  echo "==> Unpacking the FIASCO image"
  mkdir -p unpacked && 0xFFFF -M "$IMAGE" -u unpacked >/dev/null 2>&1
fi
KERNEL=$(ls unpacked/kernel_* | head -1)
INITFS=$(ls unpacked/initfs_* | head -1)
ROOTFS=$(ls unpacked/rootfs_* | head -1)
echo "    kernel  $(basename "$KERNEL")"
echo "    initfs  $(basename "$INITFS")"
echo "    rootfs  $(basename "$ROOTFS")"

if [ ! -d rootfs ]; then
  echo "==> Extracting the JFFS2 rootfs"
  if ! command -v jefferson >/dev/null; then
    python3 -m venv .venv >/dev/null 2>&1
    .venv/bin/pip install -q jefferson >/dev/null 2>&1
    JEFF=.venv/bin/jefferson
  else
    JEFF=jefferson
  fi
  $JEFF -d rootfs.tmp "$ROOTFS" >/dev/null 2>&1
  # jefferson writes into a numbered subdirectory when the image has one
  # filesystem; normalise so callers always get ./rootfs.
  if [ -d rootfs.tmp/fs_1 ]; then mv rootfs.tmp/fs_1 rootfs; rm -rf rootfs.tmp
  else mv rootfs.tmp rootfs; fi
fi

echo
echo "    rootfs   $(du -sh rootfs | cut -f1), $(grep -c '^Package: ' rootfs/var/lib/dpkg/status) packages"
echo "    glibc    $(ls rootfs/lib/libc-*.so | sed 's/.*libc-\(.*\)\.so/\1/')"
echo "    openssl  $(awk '/^Package: libssl/{p=1} p&&/^Version: /{print $2; exit}' rootfs/var/lib/dpkg/status)"
# grep -a rather than strings(1): binutils is not always installed, and the
# fallback would otherwise leak "strings: command not found" to stderr.
echo "    kernel   $(grep -a -m1 -oE 'Linux version [0-9.]+[^ ]*' "$KERNEL" 2>/dev/null || basename "$KERNEL" | sed 's/kernel_//')"
echo
echo "==> Ready. Next: tools/emulator-smoke.sh"
