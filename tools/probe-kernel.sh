#!/usr/bin/env bash
# Ask the real 2.6.21 kernel what it supports, instead of guessing.
#
#   tools/mk-diablo-emulator.sh   # once
#   tools/probe-kernel.sh
#
# APPS.md decides what to port. Several of those decisions turn on kernel
# features that the firmware's file listing cannot answer. A driver named in
# the kernel image is not the same as a working device node, so this boots the
# kernel and tries the syscalls.
#
# It answers four questions:
#   1. Does /dev/net/tun open?   Decides every VPN option.
#   2. What audio devices exist? Decides push-to-talk. QEMU models no audio
#      codec, so expect none. That is an emulator limit, not a device limit.
#   3. Does iptables run?        Decides routing.
#   4. What crypto does the kernel offer?
set -euo pipefail

OUT="${1:-$PWD/out}"
WORK="${2:-$PWD/emulator}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve the sysroot BEFORE cd, or the default lands somewhere else.
SYSROOT="${DIABLO_SYSROOT:-$PWD/sysroot-diablo}"

[ -d "$WORK/rootfs" ] || { echo "no rootfs -- run tools/mk-diablo-emulator.sh"; exit 1; }
command -v qemu-system-arm >/dev/null || { echo "qemu-system-arm not found"; exit 1; }
command -v mkfs.jffs2 >/dev/null      || { echo "mkfs.jffs2 not found -- apt install mtd-utils"; exit 1; }
qemu-system-arm -M help | grep -q '^n810' || {
  echo "this qemu has no n810 machine -- it was removed in 9.2; use 9.1 or earlier"; exit 1; }

cd "$WORK"
KERNEL=$(ls unpacked/kernel_* | head -1)
INITFS=$(ls unpacked/initfs_* | head -1)

# A device node that exists but returns ENODEV proves nothing, so open it and
# call TUNSETIFF. 10,200 is the fixed major,minor of the tun misc device.
#
# sys/socket.h MUST come before linux/if.h. The 2006 header declares
# `struct sockaddr` members without defining the type, so the other order
# fails with "field 'ifru_addr' has incomplete type".
cat > /tmp/tun-probe.c <<'C'
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <linux/if.h>
#include <linux/if_tun.h>
int main(void) {
    int fd = open("/dev/net/tun", O_RDWR);
    if (fd < 0) { printf("  open /dev/net/tun: FAILED (%s)\n", strerror(errno)); return 1; }
    printf("  open /dev/net/tun: ok (fd %d)\n", fd);
    struct ifreq ifr;
    memset(&ifr, 0, sizeof ifr);
    ifr.ifr_flags = IFF_TUN | IFF_NO_PI;
    strncpy(ifr.ifr_name, "wg0", IFNAMSIZ - 1);
    if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
        printf("  TUNSETIFF: FAILED (%s)\n", strerror(errno)); return 1;
    }
    printf("  TUNSETIFF: ok -- interface '%s' created\n", ifr.ifr_name);
    return 0;
}
C

# shellcheck source=env.sh
. "$HERE/env.sh" "$SYSROOT"

echo "==> Cross-compiling tun-probe"
$CC /tmp/tun-probe.c -o rootfs/root/tun-probe

cat > rootfs/root/probe.sh <<'TEST'
#!/bin/sh
exec >/dev/console 2>&1
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
echo "================ PROBE ================"
cat /proc/version

echo; echo "=== 1. TUN/TAP ==="
grep -i tun /proc/misc || echo "  not in /proc/misc"
mkdir -p /dev/net
mknod /dev/net/tun c 10 200 2>/dev/null
ls -l /dev/net/tun 2>/dev/null || echo "  could not create node"
/root/tun-probe
echo "--- interfaces after ---"; awk 'NR>2{print "  "$1}' /proc/net/dev

echo; echo "=== 2. Audio (QEMU models no codec -- expect nothing) ==="
cat /proc/asound/cards 2>/dev/null || echo "  --- no soundcards ---"
ls /dev/snd/ 2>/dev/null || echo "  no /dev/snd"
ls /dev/dsp* /dev/audio* 2>/dev/null || echo "  no OSS nodes"

echo; echo "=== 3. iptables ==="
/sbin/iptables -L -n 2>&1 | head -8

echo; echo "=== 4. kernel crypto ==="
grep '^name' /proc/crypto 2>/dev/null | sort -u | head -20 || echo "  no /proc/crypto"

echo "================ DONE ================"
sync; poweroff -f 2>/dev/null || halt -f 2>/dev/null || exec /bin/sh
TEST
chmod +x rootfs/root/probe.sh

# Image layout: see the long comment in tools/emulator-smoke.sh. The size and
# the 0xFF fill both fail silently if you get them wrong.
echo "==> Rebuilding the image"
mkfs.jffs2 -r rootfs -o rootfs.jffs2 -e 0x20000 -l -n -p
MAIN=$((256 * 1024 * 1024)); TOTAL=$((MAIN + MAIN / 32))
rm -f probe.img
head -c "$TOTAL" /dev/zero | tr '\000' '\377' > probe.img
for spec in "$KERNEL:$((0x80000))" "$INITFS:$((0x2a0000))" "rootfs.jffs2:$((0x6a0000))"; do
  f=${spec%:*}; off=${spec##*:}
  dd if="$f" of=probe.img bs=1M oflag=seek_bytes seek="$off" conv=notrunc status=none
done

echo "==> Booting"
timeout "${BOOT_TIMEOUT:-300}" qemu-system-arm -M n810 -m 128 \
  -kernel "$KERNEL" \
  -drive file=probe.img,format=raw,if=mtd \
  -append "console=ttyS0,115200n8 root=/dev/mtdblock4 rootfstype=jffs2 rw init=/root/probe.sh" \
  -serial mon:stdio -display none -no-reboot < /dev/null > probe.log 2>&1 || true

grep -q '================ PROBE' probe.log || {
  echo "   FAIL  never reached the probe script"; tail -25 probe.log | sed 's/^/         /'; exit 1; }
sed -n '/================ PROBE/,/================ DONE/p' probe.log
