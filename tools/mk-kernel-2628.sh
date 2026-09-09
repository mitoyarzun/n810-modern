#!/usr/bin/env bash
# Rebase Nokia's Diablo kernel patches from 2.6.21 onto vanilla 2.6.28.
#
#   tools/mk-kernel-2628.sh [work-dir]
#
# WHY 2.6.28. Diablo runs 2.6.21, and that single fact blocks most modern
# software. tools/probe-kernel.sh measures it: FUTEX_WAIT_PRIVATE (2.6.22),
# epoll_create1, eventfd2, pipe2 (2.6.27) and accept4 (2.6.28) are all ENOSYS
# on this kernel. 2.6.28 is the first release that has every one of them, and
# it is only 18 months of churn, so Maemo's userspace has a chance of
# surviving. See APPS.md.
#
# WHAT THIS DOES NOT DO YET. It stops at a generated .config. Compiling needs
# a GCC from the 4.x era; GCC 13 will not build a 2.6.28 tree. See the end.
set -euo pipefail

WORK="${1:-$PWD/build/kernel}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

DIABLO_BASE="http://maemo.wunderwungiel.pl/repository.maemo.org/pool/diablo/free/k/kernel-source-diablo"
ORIG_MD5="732c6a30f41e6e31569d09c7b6d76d9c"
DIFF_MD5="624d20e53fe8da9669f64792750ee1ca"
V21_SHA="bbbd43f096c0e83710865f8561d8a0b277d38ce1861ae470a8b52a6237265503"
V28_SHA="df1b513560a9ad0c2a03bbd43a566de293b5996e9bc0ede14ac8a6e869df75c5"

md5of()  { md5 -q "$1" 2>/dev/null || md5sum "$1" | cut -d' ' -f1; }
sha256of() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 || sha256sum "$1" | cut -d' ' -f1; }

mkdir -p "$WORK" && cd "$WORK"

echo "==> Fetching Nokia's GPL kernel source"
# Nokia published this under the GPL. maemo.org itself is gone; this is a
# community mirror of repository.maemo.org. The .dsc names both checksums, so
# a bad mirror is caught here rather than 5000 lines into a patch.
for f in kernel-source-diablo_2.6.21.orig.tar.gz \
         kernel-source-diablo_2.6.21-200842maemo1.diff.gz; do
  [ -f "$f" ] || curl -fsSL --retry 3 -O "$DIABLO_BASE/$f"
done
[ "$(md5of kernel-source-diablo_2.6.21.orig.tar.gz)" = "$ORIG_MD5" ] || {
  echo "orig.tar.gz md5 mismatch"; exit 1; }
[ "$(md5of kernel-source-diablo_2.6.21-200842maemo1.diff.gz)" = "$DIFF_MD5" ] || {
  echo "diff.gz md5 mismatch"; exit 1; }
echo "    md5 ok (both match the .dsc)"

echo "==> Fetching vanilla 2.6.21 and 2.6.28"
for v in 2.6.21 2.6.28; do
  [ -f "linux-$v.tar.xz" ] || \
    curl -fsSL --retry 3 -O "https://cdn.kernel.org/pub/linux/kernel/v2.6/linux-$v.tar.xz"
done
[ "$(sha256of linux-2.6.21.tar.xz)" = "$V21_SHA" ] || { echo "2.6.21 sha mismatch"; exit 1; }
[ "$(sha256of linux-2.6.28.tar.xz)" = "$V28_SHA" ] || { echo "2.6.28 sha mismatch"; exit 1; }
echo "    sha256 ok"

echo "==> Reconstructing Nokia's tree"
# The .orig.tar.gz is NOT vanilla -- Nokia's drivers are already in it. The
# .diff.gz on top is the Debian packaging plus late fixes. Apply it from
# inside the unpacked directory: the diff paths start
# "kernel-source-diablo-2.6.21/", which -p1 strips.
rm -rf kernel-source-diablo
tar xzf kernel-source-diablo_2.6.21.orig.tar.gz
( cd kernel-source-diablo && \
  gzip -dc ../kernel-source-diablo_2.6.21-200842maemo1.diff.gz | patch -p1 --forward --silent )

echo "==> Extracting vanilla trees"
rm -rf linux-2.6.21 linux-2.6.28
tar xf linux-2.6.21.tar.xz
tar xf linux-2.6.28.tar.xz

echo "==> Computing the Nokia delta (their 2.6.21 vs vanilla 2.6.21)"
# debian/ is packaging, not kernel code, so it is excluded.
diff -urN --exclude=debian linux-2.6.21 kernel-source-diablo/kernel-source \
  > nokia-diablo.patch 2>/dev/null || true
echo "    $(grep -c '^+++ ' nokia-diablo.patch) files, $(du -h nokia-diablo.patch | cut -f1)"

echo "==> Applying it to 2.6.28"
( cd linux-2.6.28 && patch -p1 --forward --no-backup-if-mismatch < ../nokia-diablo.patch \
    > ../apply-2628.log 2>&1 || true )
rejects=$(find linux-2.6.28 -name '*.rej' | wc -l | tr -d ' ')
echo "    patched: $(grep -c '^patching file' apply-2628.log || true) files"
echo "    rejects: $rejects files"
echo
echo "    The Nokia-only subsystems take no rejects at all -- they are new"
echo "    files, so they are pure additions:"
for d in arch/arm/plat-omap/dsp drivers/cbus drivers/video/omap sound/arm/omap; do
  n=$(find "linux-2.6.28/$d" -name '*.c' 2>/dev/null | wc -l | tr -d ' ')
  r=$(find "linux-2.6.28/$d" -name '*.rej' 2>/dev/null | wc -l | tr -d ' ')
  printf "      %-28s %2s .c files, %s rejects\n" "$d" "$n" "$r"
done
echo
echo "    The rejects are in shared core files, and most are ALREADY UPSTREAM."
echo "    Nokia was a large OMAP contributor, so 2.6.28 often has their work:"
echo "      file                       van-2.6.21  NOKIA  van-2.6.28"
for f in fs/jffs2/readinode.c arch/arm/plat-omap/fb.c arch/arm/plat-omap/gpio.c; do
  a=$(wc -l < "linux-2.6.21/$f" 2>/dev/null | tr -d ' ')
  b=$(wc -l < "kernel-source-diablo/kernel-source/$f" 2>/dev/null | tr -d ' ')
  c=$(tar xf linux-2.6.28.tar.xz "linux-2.6.28/$f" -O 2>/dev/null | wc -l | tr -d ' ')
  printf "      %-26s %-11s %-6s %s\n" "$f" "$a" "$b" "$c"
done
echo "    readinode.c and fb.c are within a few lines of Nokia's: upstream"
echo "    took the change. Those rejects are dropped, not ported."

cd linux-2.6.28

echo "==> Fixing what a 2026 host breaks"
python3 - <<'PY'
# GNU Make 4.3 refuses a rule that mixes a normal target with a pattern
# target. Both offenders get split into two rules with the same recipe.
p='Makefile'; s=open(p).read()
s = s.replace("""config %config: scripts_basic outputmakefile FORCE
	$(Q)mkdir -p include/linux include/config
	$(Q)$(MAKE) $(build)=scripts/kconfig $@""",
"""config: scripts_basic outputmakefile FORCE
	$(Q)mkdir -p include/linux include/config
	$(Q)$(MAKE) $(build)=scripts/kconfig $@

%config: scripts_basic outputmakefile FORCE
	$(Q)mkdir -p include/linux include/config
	$(Q)$(MAKE) $(build)=scripts/kconfig $@""", 1)
s = s.replace("""/ %/: prepare scripts FORCE""",
"""/: prepare scripts FORCE
	$(cmd_crmodverdir)
	$(Q)$(MAKE) KBUILD_MODULES=$(if $(CONFIG_MODULES),1) \\
	$(build)=$(build-dir)

%/: prepare scripts FORCE""", 1)
open(p,'w').write(s)
print("    Makefile: split 2 mixed rules for make >= 4.3")
PY

echo "==> Reconciling Nokia's Kconfig against 2.6.28"
python3 - <<'PY'
import sys

def edit(path, old, new, why):
    s = open(path).read()
    if old not in s:
        print("    SKIP  %s (already reconciled?)" % path); return
    open(path, 'w').write(s.replace(old, new, 1))
    print("    %-34s %s" % (path, why))

# Nokia added a second `source` for the omap fbdev Kconfig; 2.6.28 has one.
# kconfig refuses to scan the same file twice.
s = open('drivers/video/Kconfig').read().split('\n')
hits = [i for i, l in enumerate(s) if 'drivers/video/omap/Kconfig' in l]
if len(hits) > 1:
    del s[hits[0]]
    open('drivers/video/Kconfig', 'w').write('\n'.join(s))
    print("    drivers/video/Kconfig              dropped duplicate source line")

# With BSD diff the musb Kconfig can come out DOUBLED -- Nokia's whole file,
# then 2.6.28's. GNU diff merges it correctly, so this is usually a no-op.
# Match the config name EXACTLY: a startswith() test also hits
# USB_MUSB_HDRC_HCD and reports a duplicate that is not there.
lines = open('drivers/usb/musb/Kconfig').read().split('\n')
starts = [i for i, l in enumerate(lines) if l.strip() == 'config USB_MUSB_HDRC']
if len(starts) > 1:
    hdr = None
    for i in range(starts[0] + 1, starts[1]):
        if lines[i].startswith('# USB Dual Role'):
            hdr = i
    if hdr is not None:
        # Keep 2.6.28's copy: it is the newer one (HAVE_CLK, !SUPERH).
        open('drivers/usb/musb/Kconfig', 'w').write('\n'.join(lines[hdr - 1:]))
        print("    drivers/usb/musb/Kconfig           dropped duplicate half")

# Three `select` lines that were fine in 2.6.21 close dependency cycles in
# 2.6.28, which grew gpiolib and the MFD chain. `depends on` states the same
# requirement without the cycle.
edit('drivers/media/radio/Kconfig',
     '\tselect I2C\n\tselect VIDEO_V4L2',
     '\tdepends on I2C && VIDEO_V4L2',
     'TEA5761: select -> depends (V4L2 cycle)')
edit('sound/arm/Kconfig',
     '\tdepends on ARCH_OMAP && SND\n\tselect SND_PCM\n\tselect I2C\n',
     '\tdepends on ARCH_OMAP && SND && I2C\n\tselect SND_PCM\n',
     'SND_OMAP_AIC23: select -> depends (I2C cycle)')
edit('sound/arm/Kconfig',
     'config SND_AIC33\n\ttristate "Texas Instruments TLV320AIC33 Audio Codec"\n\tselect I2C',
     'config SND_AIC33\n\ttristate "Texas Instruments TLV320AIC33 Audio Codec"\n\tdepends on I2C',
     'SND_AIC33: select -> depends (I2C cycle)')
PY

echo "==> Generating Nokia's board config on the 2.6.28 tree"
make ARCH=arm nokia_2420_defconfig > ../defconfig.log 2>&1 || {
  echo "    FAILED -- see $WORK/defconfig.log"; tail -12 ../defconfig.log; exit 1; }
echo "    .config written: $(wc -l < .config | tr -d ' ') lines"
grep -E '^CONFIG_(ARCH_OMAP2420|OMAP_DSP|MACH_NOKIA_N800)=' .config | sed 's/^/      /' || true

cat <<'NEXT'

Reached: Nokia's Diablo kernel configuration resolves against a 2.6.28 tree,
with the DSP Gateway, the cbus power drivers, the omap framebuffer (including
blizzard.c, which current mainline no longer has) and the omap sound drivers
all present.

NOT reached: a compiled zImage. Two things are still needed.

  1. An old cross compiler. A 2.6.28 tree does not build with GCC 13; it
     wants the 4.x era. Nokia built Diablo with CodeSourcery 2005q3 (GCC
     3.4.4), which the kernel banner still records.

  2. Working through the remaining rejects in linux-2.6.28. Check each one
     against vanilla 2.6.28 BEFORE porting it: most are changes Nokia already
     got upstream, and the right action is to drop them.

To flash the result, the mechanism is known to work and to preserve Maemo --
Diablo-Turbo did exactly this in 2011, on the device:

  fiasco-flasher -f -k zImage
NEXT
