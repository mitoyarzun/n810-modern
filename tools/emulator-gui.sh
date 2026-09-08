#!/usr/bin/env bash
# Boot the real Diablo firmware with its GUI, viewable over VNC.
#
#   tools/mk-diablo-emulator.sh     # once, fetches and unpacks the firmware
#   tools/emulator-gui-build.sh     # once, builds the GUI flash image
#   tools/emulator-gui.sh [work-dir]
#
# The VNC server binds to LOOPBACK ONLY and is deliberately not reachable from
# the network: QEMU's VNC has no authentication here, and the guest is an
# unpatched 2008 system. Reach it through an SSH tunnel from your machine:
#
#   ssh -N -L 5901:127.0.0.1:5901 <this-host>
#   open vnc://127.0.0.1:5901          # macOS has a VNC client built in
#
# The mouse acts as the touchscreen and the keyboard as the hardware keyboard.
#
# Needs qemu-system-arm with the n810 machine -- REMOVED IN QEMU 9.2, so use
# 9.1 or earlier. Ubuntu 24.04 ships 8.2, which works.
set -euo pipefail

WORK="${1:-$PWD/emulator}"
PORT="${VNC_PORT:-5901}"
DISPLAY_N=$((PORT - 5900))

# Loopback by default. In a container, set VNC_BIND=0.0.0.0 and publish the
# port to the HOST's loopback instead -- `docker run -p 127.0.0.1:5901:5901`.
# The container's network is already isolated, so the security boundary is the
# publish rule, and the result is the same: reachable only through the tunnel.
BIND="${VNC_BIND:-127.0.0.1}"

cd "$WORK"
K=$(ls unpacked/kernel_* | head -1)
[ -f flash-gui.img ] || { echo "no flash-gui.img -- run tools/emulator-gui-build.sh"; exit 1; }
command -v qemu-system-arm >/dev/null || { echo "qemu-system-arm not found"; exit 1; }
qemu-system-arm -M help | grep -q '^n810' || {
  echo "this qemu has no n810 machine -- removed in 9.2; use 9.1 or earlier"; exit 1; }

cat <<INFO
==> Diablo on the N810, over VNC

    listening    $BIND:$PORT   (no password -- keep it off the network)
    tunnel       ssh -N -L $PORT:127.0.0.1:$PORT $(hostname)
    then open    vnc://127.0.0.1:$PORT

    screen       800x480, the N810's native resolution
    mouse        acts as the touchscreen
    keyboard     acts as the hardware keyboard
    serial log   $WORK/gui-serial.log
    monitor      $WORK/monitor.sock  -- for a screenshot without a client:
                 echo "screendump /tmp/shot.ppm" | socat - UNIX-CONNECT:$WORK/monitor.sock

    Booting to the desktop takes several minutes under emulation.
    Ctrl-C stops it.

INFO

exec qemu-system-arm -M n810 -m 128 \
  -kernel "$K" \
  -drive file=flash-gui.img,format=raw,if=mtd \
  -append "console=ttyS0,115200n8 root=/dev/mtdblock3 rootfstype=jffs2 rw init=/linuxrc" \
  -serial file:"$WORK/gui-serial.log" \
  -vnc "$BIND:$DISPLAY_N" \
  -monitor "unix:$WORK/monitor.sock,server,nowait" \
  -no-reboot
