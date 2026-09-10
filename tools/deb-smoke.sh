#!/usr/bin/env bash
# Install the .deb packages on the real Diablo userland, under emulation.
#
#   tools/mk-debs.sh
#   tools/deb-smoke.sh
#
# Building a package that dpkg accepts on your desktop proves nothing: Diablo
# ships dpkg 1.13, and the ways a modern .deb can be unreadable to it are all
# quiet. This installs them with the device's own dpkg and then runs the
# binaries.
set -euo pipefail

OUT="${1:-$PWD/out}"
WORK="${2:-$PWD/emulator}"
DIST="${DIST:-$PWD/dist}"

[ -d "$WORK/rootfs" ] || { echo "no rootfs -- run tools/mk-diablo-emulator.sh"; exit 1; }
ls "$DIST"/n810-modern-*.deb >/dev/null 2>&1 || { echo "no packages -- run tools/mk-debs.sh"; exit 1; }
command -v qemu-system-arm >/dev/null || { echo "qemu-system-arm not found"; exit 1; }
command -v mkfs.jffs2 >/dev/null      || { echo "mkfs.jffs2 not found"; exit 1; }

cd "$WORK"
KERNEL="${KERNEL_OVERRIDE:-$(ls unpacked/kernel_* | head -1)}"
INITFS=$(ls unpacked/initfs_* | head -1)

echo "==> Staging packages into the rootfs"
# The device must not already have the files: install from a clean tree, or
# the test proves only that cp works.
rm -rf rootfs/opt/n810-modern rootfs/root/debs
mkdir -p rootfs/root/debs
cp "$DIST"/n810-modern-*.deb rootfs/root/debs/
ls rootfs/root/debs | sed 's/^/    /'

cat > rootfs/root/deb-test.sh <<'TEST'
#!/bin/sh
exec >/dev/console 2>&1
mount -t proc proc /proc 2>/dev/null
# Running as init, there is no environment at all, and dpkg refuses to work
# without PATH ("dpkg - error: PATH is not set").
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
echo "================ DEB SMOKE ================"
echo "dpkg on this device: $(dpkg --version 2>&1 | head -1)"
echo

cd /root/debs
for p in n810-modern-tls n810-modern-ssh; do
	echo "--- installing $p ---"
	dpkg -i ${p}_*.deb 2>&1 | sed 's/^/    /'
done

echo
echo "--- dpkg believes they are installed ---"
dpkg -l | grep n810-modern | sed 's/^/    /'

echo
echo "--- the files landed where the rpath expects ---"
ls -la /opt/n810-modern/lib/libssl.so.3 /opt/n810-modern/bin/curl 2>&1 | sed 's/^/    /'

echo
echo "--- and they run ---"
export LD_LIBRARY_PATH=/opt/n810-modern/lib
/opt/n810-modern/bin/openssl version 2>&1 | sed 's/^/    /'
/opt/n810-modern/bin/curl --version 2>&1 | head -2 | sed 's/^/    /'
/opt/n810-modern/bin/ssh -V 2>&1 | sed 's/^/    /'
/opt/n810-modern/bin/stunnel -version 2>&1 | sed -n '2,3p' | sed 's/^/    /'

echo
echo "--- removal is clean ---"
dpkg -r n810-modern-ssh 2>&1 | sed 's/^/    /'
ls /opt/n810-modern/bin/ssh 2>&1 | sed 's/^/    /'

echo "================ DONE ================"
sync; poweroff -f 2>/dev/null || halt -f 2>/dev/null || exec /bin/sh
TEST
chmod +x rootfs/root/deb-test.sh

echo "==> Building the image"
mkfs.jffs2 -r rootfs -o rootfs.jffs2 -e 0x20000 -l -n -p
MAIN=$((256 * 1024 * 1024)); TOTAL=$((MAIN + MAIN / 32))
rm -f debtest.img
head -c "$TOTAL" /dev/zero | tr '\000' '\377' > debtest.img
for spec in "$KERNEL:$((0x80000))" "$INITFS:$((0x2a0000))" "rootfs.jffs2:$((0x6a0000))"; do
  f=${spec%:*}; off=${spec##*:}
  dd if="$f" of=debtest.img bs=1M oflag=seek_bytes seek="$off" conv=notrunc status=none
done

echo "==> Booting"
timeout "${BOOT_TIMEOUT:-420}" qemu-system-arm -M n810 -m 128 \
  -kernel "$KERNEL" \
  -drive file=debtest.img,format=raw,if=mtd \
  -append "console=ttyS0,115200n8 root=/dev/mtdblock4 rootfstype=jffs2 rw init=/root/deb-test.sh" \
  -serial mon:stdio -display none -no-reboot < /dev/null > debtest.log 2>&1 || true

sed -n '/DEB SMOKE/,/================ DONE/p' debtest.log

grep -q "OpenSSL 3" debtest.log && grep -q "curl 8" debtest.log &&
  echo "Package smoke test passed." || { echo "FAILURES ABOVE."; exit 1; }
