#!/usr/bin/env bash
# Build a flash image that boots Diablo all the way to its desktop.
#
#   tools/mk-diablo-emulator.sh      # once, fetches and unpacks the firmware
#   tools/emulator-gui-build.sh      # this
#   tools/emulator-gui.sh            # boot it, viewable over VNC
#
# tools/emulator-smoke.sh boots straight into a test script and never needs
# userspace to work. Reaching the DESKTOP needs the real boot sequence, and
# that fights back in four ways. Every one of them is patched here through
# Diablo's own switches rather than by rewriting its scripts.
set -euo pipefail

WORK="${1:-$PWD/emulator}"
OUT="${2:-$PWD/out}"
PREFIX="$OUT/opt/handshake"

[ -d "$WORK/rootfs" ] || { echo "no rootfs -- run tools/mk-diablo-emulator.sh"; exit 1; }
command -v mkfs.jffs2 >/dev/null || { echo "mkfs.jffs2 not found -- apt install mtd-utils"; exit 1; }

cd "$WORK"
KERNEL=$(ls unpacked/kernel_* | head -1)

# jefferson does not extract the initfs for us; do it here if needed.
if [ ! -d initfs-x ]; then
  echo "==> Extracting the initfs"
  JEFF=$([ -x .venv/bin/jefferson ] && echo .venv/bin/jefferson || echo jefferson)
  $JEFF -d initfs-tmp "$(ls unpacked/initfs_*)" >/dev/null 2>&1
  if [ -d initfs-tmp/fs_1 ]; then mv initfs-tmp/fs_1 initfs-x; rm -rf initfs-tmp
  else mv initfs-tmp initfs-x; fi
fi

echo "==> 1. Disabling DSME"
# The emulated tablet has no battery, so DSME shuts it down during boot:
#     BME info: bme_primary_init: Connected battery type: 65535
#     dsme: Bad battery type: 65535, shutting down..
# linuxrc has a switch. Note Nokia's own bug: it TESTS /etc/initfs.config but
# SOURCES /initfs.config, so write both.
#
# dsme_state is normally filled by start_dsm from /usr/sbin/bootstate. Left
# empty, enter_state falls through to its default branch:
#     Entering state ''.
#     Houston, we have a problem, powering off...
cat > initfs-x/initfs.config <<'CFG'
dsm_enable=0
dsme_state=USER
CFG
mkdir -p initfs-x/etc && cp initfs-x/initfs.config initfs-x/etc/initfs.config

echo "==> 2. Shimming bootstate"
# boot() re-queries the state after mounting the rootfs, and bootstate talks to
# DSME, so it fails and the state becomes MALF -- the same power-off, later:
#     Entering state 'MALF'.
[ -f initfs-x/usr/sbin/bootstate.real ] ||
  mv initfs-x/usr/sbin/bootstate initfs-x/usr/sbin/bootstate.real 2>/dev/null || true
printf '#!/bin/sh\necho USER\n' > initfs-x/usr/sbin/bootstate
chmod 0755 initfs-x/usr/sbin/bootstate

echo "==> 3. Standing in for dsmetool"
# This is the one that actually gates the GUI. Twenty init scripts start their
# daemon with `dsmetool -r "cmd"`, asking DSME to supervise it. With DSME off
# those scripts silently start NOTHING -- including the system dbus and the X
# server:
#     Starting system message bus: ...        (and then no bus)
#     real-af-services: Error, X server did not start
# Deleting dsmetool is not the answer: /etc/init.d/x-server would fall through
# to its direct-exec branch, but nineteen other daemons would lose their
# launcher. Stand in for it instead.
[ -f rootfs/usr/sbin/dsmetool.real ] ||
  mv rootfs/usr/sbin/dsmetool rootfs/usr/sbin/dsmetool.real 2>/dev/null || true
cat > rootfs/usr/sbin/dsmetool <<'DT'
#!/bin/sh
# Stand-in for dsmetool while DSME is disabled: run what we are asked to run,
# log its output, ignore the supervision. See tools/emulator-gui-build.sh.
log=/var/log/dsmetool.log
while [ $# -gt 0 ]; do
  case "$1" in
    -r|-t) shift; [ -n "${1:-}" ] && sh -c "$1" >>"$log" 2>&1 & ;;
    -k|-n) shift ;;
  esac
  shift
done
exit 0
DT
chmod 0755 rootfs/usr/sbin/dsmetool
mkdir -p rootfs/var/log

echo "==> 4. Restoring ownership under /home/user"
# jefferson does not preserve uid/gid, so the extracted tree is entirely
# root:root. Maemo's UI runs as uid 29999 and cannot write its own config:
#     cannot create /home/user/.osso/current-gtk-theme...: Permission denied
chown -R 29999:29999 rootfs/home/user 2>/dev/null ||
  echo "    (need root to chown; the desktop may fail to save settings)"

if [ -x "$PREFIX/bin/openssl" ]; then
  echo "==> Including $PREFIX"
  rm -rf rootfs/opt/handshake && mkdir -p rootfs/opt
  cp -a "$PREFIX" rootfs/opt/handshake
fi

echo "==> Rebuilding the filesystems"
mkfs.jffs2 -r initfs-x -o gui-initfs.jffs2 -e 0x20000 -l -n -p
mkfs.jffs2 -r rootfs   -o gui-rootfs.jffs2 -e 0x20000 -l -n -p
[ "$(stat -c%s gui-initfs.jffs2)" -le $((0x400000)) ] || { echo "initfs exceeds its 4 MB partition"; exit 1; }
[ "$(stat -c%s gui-rootfs.jffs2)" -le $((0x10000000 - 0x6a0000)) ] || { echo "rootfs exceeds its partition"; exit 1; }

echo "==> Building the OneNAND image"
MAIN=$((256 * 1024 * 1024))
TOTAL=$((MAIN + MAIN / 32))
# 264 MB, 0xFF-filled: QEMU keeps the out-of-band area in the same backing
# file, and erased NAND is all ones. See BUILDLOG section 10. The producer
# goes first in this pipeline so nothing dies of SIGPIPE under pipefail.
rm -f flash-gui.img
head -c "$TOTAL" /dev/zero | tr '\000' '\377' > flash-gui.img
[ "$(stat -c%s flash-gui.img)" = "$TOTAL" ] || { echo "flash-gui.img is the wrong size"; exit 1; }
for spec in "$KERNEL:$((0x80000))" "gui-initfs.jffs2:$((0x2a0000))" "gui-rootfs.jffs2:$((0x6a0000))"; do
  f=${spec%:*}; off=${spec##*:}
  dd if="$f" of=flash-gui.img bs=1M oflag=seek_bytes seek=$off conv=notrunc status=none
done

echo
echo "    flash-gui.img  $(du -h flash-gui.img | cut -f1)"
echo "==> Ready. Next: tools/emulator-gui.sh"
