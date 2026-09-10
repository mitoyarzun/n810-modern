#!/usr/bin/env bash
# Build a flash image that boots Diablo all the way to its desktop.
#
#   tools/mk-diablo-emulator.sh      # once, fetches and unpacks the firmware
#   tools/emulator-gui-build.sh      # this
#   tools/emulator-gui.sh            # boot it, viewable over VNC
#
# tools/emulator-smoke.sh boots straight into a test script and never needs
# userspace to work. Reaching the DESKTOP needs the real boot sequence, which
# fights back in six ways -- five of them consequences of disabling DSME,
# because DSME is both the process supervisor and part of the state machine.
# Each is patched through Diablo's own switches where one exists.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${1:-$PWD/emulator}"
OUT="${2:-$PWD/out}"
PREFIX="$OUT/opt/handshake"

# Your own files, copied over the rootfs at the end of the build. See
# gui-overlay.example/README.md. The step is skipped when the directory does
# not exist, which is the default.
OVERLAY="${GUI_OVERLAY:-$HERE/../gui-overlay}"
[ -d "$OVERLAY" ] && OVERLAY="$(cd "$OVERLAY" && pwd)"

[ -d "$WORK/rootfs" ] || [ -d "$WORK/rootfs.stock" ] ||
  { echo "no rootfs -- run tools/mk-diablo-emulator.sh"; exit 1; }
command -v mkfs.jffs2 >/dev/null || { echo "mkfs.jffs2 not found -- apt install mtd-utils"; exit 1; }

cd "$WORK"
KERNEL=$(ls unpacked/kernel_* | head -1)

echo "==> 0. Refreshing the working rootfs from rootfs.stock"
# Every step below patches the extracted rootfs in place, so a second run
# builds on the first. That is fine for the fixed patches, and wrong for a
# customised image: a file you delete from your overlay would stay in the
# tree. Start each build from the untouched extraction instead.
#
# KEEP_ROOTFS=1 skips this, for a rootfs you patched by hand.
if [ "${KEEP_ROOTFS:-0}" = "1" ]; then
  echo "    kept (KEEP_ROOTFS=1)"
elif [ -d rootfs.stock ]; then
  if command -v rsync >/dev/null; then
    rsync -a --delete rootfs.stock/ rootfs/
  else
    rm -rf rootfs && cp -a rootfs.stock rootfs
  fi
  echo "    rootfs is stock again"
else
  echo "    WARNING: no rootfs.stock -- this build starts from the current"
  echo "    rootfs, which earlier runs have already patched. Run"
  echo "    tools/mk-diablo-emulator.sh to extract a stock tree."
fi

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
#
# The log path must DEGRADE, never fail. Matchbox and hildon-desktop are
# launched as uid 29999, and when the redirect below could not create a
# root-owned log the whole command failed -- so the two processes this shim
# exists to start were the two it silently killed, while root-launched X
# survived and made it look like a desktop problem.
log=/var/log/dsmetool.log
{ : >>"$log"; } 2>/dev/null || log=/tmp/dsmetool.log
{ : >>"$log"; } 2>/dev/null || log=/dev/null
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
: > rootfs/var/log/dsmetool.log
chmod 0666 rootfs/var/log/dsmetool.log

echo "==> 4. Restoring ownership under /home/user"
# jefferson does not preserve uid/gid, so the extracted tree is entirely
# root:root. Maemo's UI runs as uid 29999 and cannot write its own config:
#     cannot create /home/user/.osso/current-gtk-theme...: Permission denied
chown -R 29999:29999 rootfs/home/user 2>/dev/null ||
  echo "    (need root to chown; the desktop may fail to save settings)"

echo "==> 5. Disabling dsp-init"
# The OMAP2420 has a TI C55x DSP. QEMU emulates enough of it for the kernel to
# print "omap_dsp_init() done", but not enough to load and configure a DSP
# binary, so /etc/init.d/dsp-init (S24, early in runlevel 2) loops:
#     detected binary version 3.3.0.0
#     setting DSP reset vector to 0x1036b8
#     DSP configuration ...
#       failed
#     status = 2
#     exitting.
# It takes the X server down with it -- the daemon log shows X starting four
# times over, and no hildon-desktop output at all. Nothing we want needs the
# DSP: it is for audio and video decode.
rm -f rootfs/etc/rc2.d/S24dsp-init rootfs/etc/rc5.d/S24dsp-init

echo "==> 6. Restoring hardlinks jefferson dropped"
# jefferson writes only ONE name per inode, so the second and later names of a
# hardlink set vanish. dpkg's file lists say they should be there:
#     /usr/bin/sudo      missing, while /usr/bin/sudoedit is present and is
#                        the same setuid-root binary (-rwsr-xr-x, 88520 bytes)
#     /usr/bin/perl      missing, while /usr/bin/perl5.8.3 is present
# The absence is not cosmetic. Three Diablo scripts call sudo, and each one
# fails with "sudo: not found":
#     /usr/bin/hildon-input-method-configurator: line 11: sudo: not found
#     /etc/osso-af-init/real-af-services: ... sudo: not found
# Re-linking is exact rather than a workaround: it is the same inode the
# device itself has, setuid bit and all.
for pair in "sudoedit:sudo" "perl5.8.3:perl"; do
  have=${pair%:*}; want=${pair#*:}
  if [ -e "rootfs/usr/bin/$have" ] && [ ! -e "rootfs/usr/bin/$want" ]; then
    ln "rootfs/usr/bin/$have" "rootfs/usr/bin/$want" 2>/dev/null ||
      cp -a "rootfs/usr/bin/$have" "rootfs/usr/bin/$want"
    echo "    linked /usr/bin/$want -> $have"
  fi
done

echo "==> 7. Creating the gconf directory ke-recv expects"
# /etc/osso-af-init/gconf-dir is a symlink to /var/lib/gconf, and ke-recv wants
# to put a symlink inside it:
#     ln -s /tmp/gconf-dir/system/osso/af /etc/osso-af-init/gconf-dir/system/osso/af
# /var/lib/gconf exists but system/osso beneath it does not, so this fails:
#     ln: /etc/osso-af-init/gconf-dir/system/osso/af: No such file or directory
# The desktop then paints its wallpaper and waits on a spinner. (The plugin
# list is not in gconf: it comes from the .desktop files under X-Plugin-Dir.
# See step 8.)
mkdir -p rootfs/var/lib/gconf/system/osso
chmod 0755 rootfs/var/lib/gconf/system rootfs/var/lib/gconf/system/osso

echo "==> 8. The contacts button in the task navigator"
# The contacts plugin needs telephony and address-book backends the emulator
# does not have, so the button does nothing but occupy the bar and load a
# library. Delete its descriptor; the browser, applications menu and task
# switcher stay.
#
# DELETE THE DESCRIPTOR, NOT THE LINE IN tasknavigator.conf. That config lists
# the plugins, and editing it changes nothing on screen: hildon-desktop also
# loads every .desktop file it finds in X-Plugin-Dir. Two boots proved it --
# a bar with the line removed is pixel-identical to the stock bar, and the
# button disappears only when the descriptor goes. See CAVEATS.md.
#
# KEEP_CONTACTS=1 keeps the button, to see the stock bar or to test the
# plugin itself.
NAV=rootfs/usr/share/applications/hildon-navigator/osso-contact-plugin.desktop
if [ "${KEEP_CONTACTS:-0}" = "1" ]; then
  echo "    kept (KEEP_CONTACTS=1)"
elif [ -f "$NAV" ]; then
  rm -f "$NAV"
  echo "    contacts plugin removed"
fi

echo "==> 9. Building fb-autoupdate for the guest"
# The panel is manual-update: QEMU's blizzard model only redraws when the
# guest pushes pixels through the controller's data port, and has no
# continuous redraw. fb-progress pushes; Xomap does not, so the desktop draws
# into memory nobody flushes. OMAPFB_SET_UPDATE_MODE(auto) makes the driver
# push on its own timer. See tools/fb-autoupdate.c.
if [ -f "$HERE/fb-autoupdate.c" ] && command -v arm-linux-gnueabi-gcc >/dev/null; then
  ( . "$HERE/env.sh" "${DIABLO_SYSROOT:-$(dirname "$WORK")/sysroot-diablo}" >/dev/null 2>&1 &&
    $CC -O2 -o rootfs/usr/sbin/fb-autoupdate "$HERE/fb-autoupdate.c" ) &&
    chmod 0755 rootfs/usr/sbin/fb-autoupdate &&
    echo "    built $(basename rootfs/usr/sbin/fb-autoupdate)" ||
    echo "    WARNING: could not build fb-autoupdate"
  cat > rootfs/etc/rc2.d/S98fb-autoupdate <<'FBA'
#!/bin/sh
[ -x /usr/sbin/fb-autoupdate ] || exit 0
/usr/sbin/fb-autoupdate /dev/fb0 >/dev/console 2>&1
/usr/sbin/fb-autoupdate -l /dev/fb0 >/dev/null 2>&1 &
exit 0
FBA
  chmod 0755 rootfs/etc/rc2.d/S98fb-autoupdate
else
  echo "    skipped (no cross compiler or source)"
fi

if [ "${DEBUG_SHELL:-0}" = "1" ]; then
  echo "==> 10. Adding a display diagnostic dump (DEBUG_SHELL=1)"
  # QEMU's n810 machine wires only the FIRST UART, so a second -serial is
  # silently never created and a shell on ttyS1 is unreachable. Everything
  # here therefore goes to the console, which is the path already proven by
  # the boot log.
  #
  # The decisive test is the last one: write noise straight to /dev/fb0. If
  # the emulated screen changes, the framebuffer path is alive and X simply
  # is not drawing through it. If it does not, the path is dead after the
  # handover from fb-progress.
  cat > rootfs/etc/rc2.d/S99fb-diag <<'DBG'
#!/bin/sh
exec >/dev/console 2>&1
echo "================ FB DIAGNOSTICS ================"
echo "--- /proc/fb ---";            cat /proc/fb 2>&1
echo "--- /dev/fb* ---";            ls -l /dev/fb* 2>&1
echo "--- /sys/class/graphics ---"; ls /sys/class/graphics/ 2>&1
for d in /sys/class/graphics/fb0 /sys/devices/platform/omapfb; do
  [ -d "$d" ] && { echo "--- $d ---"; ls "$d" 2>&1; }
done
echo "--- processes ---";           ps 2>&1 | grep -iE "xomap|hildon|matchbox|PID" | head -10
echo "--- who holds fb0 ---"
for p in /proc/[0-9]*; do
  for f in $p/fd/*; do
    case "$(readlink "$f" 2>/dev/null)" in
      */fb0) echo "  $(cat $p/cmdline 2>/dev/null | tr '\0' ' ')" ;;
    esac
  done
done 2>/dev/null | sort -u | head
echo "--- DECISIVE: writing noise to /dev/fb0 ---"
if [ -c /dev/fb0 ]; then
  dd if=/dev/urandom of=/dev/fb0 bs=4096 count=64 2>&1 | tail -1
  echo "wrote to /dev/fb0; if the emulated screen did NOT change, the"
  echo "framebuffer path is dead and this is a QEMU display limitation."
else
  echo "/dev/fb0 DOES NOT EXIST"
fi
echo "================ END DIAGNOSTICS ================"
exit 0
DBG
  chmod 0755 rootfs/etc/rc2.d/S99fb-diag
fi

if [ -x "$PREFIX/bin/openssl" ]; then
  echo "==> Including $PREFIX"
  rm -rf rootfs/opt/handshake && mkdir -p rootfs/opt
  cp -a "$PREFIX" rootfs/opt/handshake
fi

echo "==> 11. Applying the overlay"
# Last, so your files win over every patch above. The tree under the overlay
# directory is the tree of the device: gui-overlay/etc/hildon-desktop/
# tasknavigator.conf lands at /etc/hildon-desktop/tasknavigator.conf.
#
# overlay.sh and README.md are the directory's own, not the device's, so they
# are not copied. overlay.sh runs after the copy, with rootfs as its working
# directory, for the edits a file cannot express -- a line removed from a
# stock config, a symlink, a permission.
#
# The files keep the owner they have here, so run this build as root (the
# container does) or the device gets files owned by a user it does not know.
if [ ! -d "$OVERLAY" ]; then
  echo "    none ($OVERLAY does not exist)"
else
  tar -C "$OVERLAY" --exclude=./overlay.sh --exclude=./README.md -cf - . |
    tar -C rootfs -xf -
  n=$(find "$OVERLAY" -type f ! -name overlay.sh ! -name README.md | wc -l | tr -d ' ')
  [ "$n" = "1" ] && unit=file || unit=files
  echo "    copied $n $unit from $OVERLAY"
  if [ -f "$OVERLAY/overlay.sh" ]; then
    ( cd rootfs && WORK="$WORK" PREFIX="$PREFIX" sh "$OVERLAY/overlay.sh" )
    echo "    ran overlay.sh"
  fi
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
