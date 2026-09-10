#!/usr/bin/env bash
# Run our build on the REAL Diablo kernel and userland, under full-system QEMU.
#
#   tools/mk-diablo-emulator.sh    # once -- fetches and unpacks the firmware
#   tools/emulator-smoke.sh [out-dir] [work-dir]
#
# This is the strongest test available without the tablet, and the only one
# that exercises the real 2.6.21 kernel. tools/qemu-smoke.sh runs our binaries
# on the device's glibc but translates syscalls to the HOST kernel, so it
# cannot tell you whether 2.6.21 serves them. This can.
#
# Needs qemu-system-arm with the n810 machine. It was REMOVED IN QEMU 9.2, so
# use a 9.1-or-earlier build; Ubuntu 24.04 ships 8.2, which works.
set -euo pipefail

OUT="${1:-$PWD/out}"
WORK="${2:-$PWD/emulator}"
PREFIX="$OUT/opt/n810-modern"

[ -d "$WORK/rootfs" ]        || { echo "no rootfs -- run tools/mk-diablo-emulator.sh"; exit 1; }
[ -x "$PREFIX/bin/openssl" ] || { echo "no build at $PREFIX -- run tools/build-openssl.sh"; exit 1; }
command -v qemu-system-arm >/dev/null || { echo "qemu-system-arm not found"; exit 1; }
command -v mkfs.jffs2 >/dev/null      || { echo "mkfs.jffs2 not found -- apt install mtd-utils"; exit 1; }
qemu-system-arm -M help | grep -q '^n810' || {
  echo "this qemu has no n810 machine -- it was removed in 9.2; use 9.1 or earlier"; exit 1; }

cd "$WORK"
KERNEL=$(ls unpacked/kernel_* | head -1)
INITFS=$(ls unpacked/initfs_* | head -1)

echo "==> Injecting $PREFIX into the Diablo rootfs"
rm -rf rootfs/opt/n810-modern && mkdir -p rootfs/opt
cp -a "$PREFIX" rootfs/opt/n810-modern

cat > rootfs/root/hs-test.sh <<'TEST'
#!/bin/sh
exec >/dev/console 2>&1
mount -t proc proc /proc 2>/dev/null
H=/opt/n810-modern
export LD_LIBRARY_PATH=$H/lib
export OPENSSL_MODULES=$H/lib/ossl-modules

echo "================ ON THE REAL KERNEL ================"
cat /proc/version
echo "clock: $(date)   # 1970 here means every certificate is 'not yet valid'"
[ -c /dev/urandom ] && echo "/dev/urandom: present" || echo "/dev/urandom: MISSING"

echo; echo "=== 1. Our openssl starts ==="
$H/bin/openssl version
echo; echo "=== 2. Providers ==="
$H/bin/openssl list -providers | grep -E 'name:|status:'
$H/bin/openssl list -providers -provider legacy | grep -E 'name:|status:'
echo; echo "=== 3. Crypto ==="
echo handshake | $H/bin/openssl dgst -sha256
echo "rand:   $($H/bin/openssl rand -hex 16)"
$H/bin/openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null | head -1
$H/bin/openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 2>/dev/null | head -1
echo; echo "=== 4. stunnel ==="
$H/bin/stunnel -version 2>&1 | sed -n '2,4p'
echo; echo "=== 5. Speed (EMULATED -- see the warning below) ==="
for a in "-evp chacha20-poly1305" "-evp aes-128-gcm"; do
  $H/bin/openssl speed -seconds 1 $a 2>/dev/null | tail -1
done
echo "================ DONE ================"
sync; poweroff -f 2>/dev/null || halt -f 2>/dev/null || exec /bin/sh
TEST
chmod +x rootfs/root/hs-test.sh

echo "==> Rebuilding the JFFS2 rootfs"
# -n: no cleanmarkers. On NAND they live in the out-of-band area, not in the
# node stream, so writing them inline corrupts the image.
mkfs.jffs2 -r rootfs -o rootfs.jffs2 -e 0x20000 -l -n -p

echo "==> Building the OneNAND image"
MAIN=$((256 * 1024 * 1024))
TOTAL=$((MAIN + MAIN / 32))
# Two things here fail SILENTLY if you get them wrong, and both took a while
# to find. See BUILDLOG section 10.
#
# 1. Size must be MAIN + MAIN/32. QEMU's hw/block/onenand.c allocates
#    size + (size >> 5) and keeps the 8 MB out-of-band area in the SAME
#    backing file, appended after the main data.
# 2. Fill with 0xFF, not zeros. Erased NAND reads as all ones; a zero in a
#    block's OOB marker means BAD.
#
# Get either wrong and every eraseblock reads bad, the kernel skips the whole
# chip, and JFFS2 mounts an EMPTY filesystem -- successfully. You then get
# "No init found" a second later, pointing nowhere near the cause.
#
# 3. The producer goes FIRST in this pipeline. Written the other way round --
#    `tr '\000' '\377' < /dev/zero | head -c $TOTAL` -- head exits after N
#    bytes, tr dies of SIGPIPE, and `set -o pipefail` turns that into 141,
#    which `set -e` treats as a failure and aborts on. Silently. This is the
#    same trap as BUILDLOG section 8, and it was reintroduced here on the same
#    day it was documented. With head first, the producer is finite and tr
#    reads to a clean EOF.
rm -f flash.img
head -c "$TOTAL" /dev/zero | tr '\000' '\377' > flash.img
[ "$(stat -c%s flash.img)" = "$TOTAL" ] || { echo "flash.img is the wrong size"; exit 1; }

# Offsets are the partition table the Diablo kernel itself prints on boot:
#   0x00000000 bootloader | 0x00020000 config  | 0x00080000 kernel
#   0x002a0000 initfs     | 0x006a0000 rootfs
for spec in "$KERNEL:$((0x80000))" "$INITFS:$((0x2a0000))" "rootfs.jffs2:$((0x6a0000))"; do
  f=${spec%:*}; off=${spec##*:}
  dd if="$f" of=flash.img bs=1M oflag=seek_bytes seek=$off conv=notrunc status=none
done

echo "==> Booting"
timeout "${BOOT_TIMEOUT:-420}" qemu-system-arm -M n810 -m 128 \
  -kernel "$KERNEL" \
  -drive file=flash.img,format=raw,if=mtd \
  -append "console=ttyS0,115200n8 root=/dev/mtdblock4 rootfstype=jffs2 rw init=/root/hs-test.sh" \
  -serial mon:stdio -display none -no-reboot < /dev/null > boot.log 2>&1 || true

bad=$(grep -c 'Bad eraseblock' boot.log || true)
if [ "$bad" -gt 0 ]; then
  echo "   FAIL  $bad bad eraseblocks -- the flash image is malformed, see the comments above"
  exit 1
fi

if ! grep -q 'ON THE REAL KERNEL' boot.log; then
  echo "   FAIL  never reached the test script"
  tail -25 boot.log | sed 's/^/         /'
  exit 1
fi

sed -n '/ON THE REAL KERNEL/,/DONE/p' boot.log
cat <<'WARN'

NOTE on section 5. These are QEMU numbers. QEMU's TCG retranslates ARM to the
host's instruction set and does not model the ARM1136 pipeline, cache or
memory latency, so they say nothing reliable about a real 400 MHz core -- not
even the ratio between two ciphers. DECISIONS.md #19 stays a prediction until
the tablet runs it.
WARN

grep -q 'stunnel 5' boot.log && grep -q 'OpenSSL 3' boot.log &&
  echo "Emulator smoke test passed." || { echo "FAILURES ABOVE."; exit 1; }
