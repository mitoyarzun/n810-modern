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
rm -rf linux-2.6.21 linux-2.6.28 vanilla-2.6.28
tar xf linux-2.6.21.tar.xz
tar xf linux-2.6.28.tar.xz
# A pristine copy to restore from. Everything below compares against it.
cp -a linux-2.6.28 vanilla-2.6.28

# 2.6.28 MOVED THE ARM HEADERS, and this is the trap of the whole exercise.
#   include/asm-arm/           -> arch/arm/include/asm/
#   include/asm-arm/arch-omap/ -> arch/arm/plat-omap/include/mach/
# 56 of the 638 files in Nokia's delta live under the old paths, and 50 of
# those are the OMAP headers -- blizzard.h, board-nokia.h, aic23.h, the ones
# the N810 cannot boot without. Patching them at the old path SUCCEEDS and
# then does nothing, because 2.6.28 never reads that directory. No error, no
# reject: the build just fails later with a missing ATAG_BOARD.
#
# So relocate both source trees to the 2.6.28 layout BEFORE diffing. Then the
# delta is expressed in paths 2.6.28 actually uses.
echo "==> Relocating ARM headers to the 2.6.28 layout"
for t in linux-2.6.21 kernel-source-diablo/kernel-source; do
  if [ -d "$t/include/asm-arm/arch-omap" ]; then
    mkdir -p "$t/arch/arm/plat-omap/include"
    mv "$t/include/asm-arm/arch-omap" "$t/arch/arm/plat-omap/include/mach"
  fi
  if [ -d "$t/include/asm-arm" ]; then
    mkdir -p "$t/arch/arm/include"
    mv "$t/include/asm-arm" "$t/arch/arm/include/asm"
  fi
done
echo "    moved in both trees"

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

# Some files came out with Nokia's version APPENDED to 2.6.28's rather than
# merged, so a function ends up defined twice. Where upstream restructured the
# code, Nokia's 2.6.21 version is simply obsolete and vanilla 2.6.28 already
# does the same job: memory.c is the clear case, where 2.6.28 replaced the
# cast-lvalue register macros with sdrc_write_reg()/sms_write_reg() inlines.
# Take vanilla for these.
echo "==> Restoring files that 2.6.28 superseded"
for f in arch/arm/mach-omap2/memory.c \
         arch/arm/mach-omap2/devices.c \
         arch/arm/mach-omap2/serial.c \
         arch/arm/mach-omap2/gpmc.c \
         arch/arm/mach-omap2/pm.c \
         arch/arm/plat-omap/include/mach/pm.h; do
  if tar xf ../linux-2.6.28.tar.xz --strip-components=1 -C . "linux-2.6.28/$f" 2>/dev/null; then
    echo "    vanilla: $f"
  else
    echo "    NOT IN VANILLA (skipped): $f"
  fi
done

# The header move has a second half. 2.6.28 also renamed the include style:
#   #include <asm/arch/foo.h>   ->   #include <mach/foo.h>
# Nokia's files still use the old spelling, so they fail to find headers that
# are now present. Vanilla 2.6.28 files were all converted upstream, so a
# sweep only touches Nokia's.
echo "==> Rewriting asm/arch includes to the 2.6.28 mach style"
n=$(grep -rl 'asm/arch/' --include='*.c' --include='*.h' --include='*.S' . 2>/dev/null | wc -l | tr -d ' ')
grep -rl 'asm/arch/' --include='*.c' --include='*.h' --include='*.S' . 2>/dev/null \
  | xargs -r sed -i 's|asm/arch/|mach/|g'
echo "    rewrote $n files"

# Whole subsystems where the size comparison above already showed that
# upstream took Nokia's work. jffs2 is the clear case: readinode.c is 1435
# lines in Nokia's tree and 1438 in vanilla 2.6.28. Keeping Nokia's copy only
# produces duplicate definitions.
# THE RULE. Nokia shipped two very different kinds of change in one patch:
#
#   1. New files for hardware nobody else had -- the DSP Gateway, the cbus
#      power drivers, the Blizzard framebuffer, the board files. These are
#      pure additions. They apply with zero rejects and they are the whole
#      point of the exercise.
#
#   2. Edits to shared core code -- jffs2, kernel/timer.c, the USB and
#      bluetooth stacks. Nokia was a large upstream contributor, so 2.6.28
#      usually ALREADY HAS these, and often a later version of them. Keeping
#      Nokia's copy just produces duplicate definitions.
#
# So: keep category 1, take vanilla for category 2. Whack-a-mole on individual
# files converges far more slowly than stating the rule once.
echo "==> Reverting Nokia's core-kernel edits, keeping their hardware support"
grep '^patching file' ../apply-2628.log 2>/dev/null \
  | sed "s/^patching file //; s/^'//; s/'$//" | sort -u > ../patched-files.txt
kept=0; reverted=0
while IFS= read -r f; do
  case "$f" in
    # Where the N810's hardware lives -- keep Nokia's version.
    arch/arm/plat-omap/*|arch/arm/mach-omap2/*|arch/arm/configs/*|\
    drivers/cbus/*|drivers/video/omap/*|sound/arm/omap/*|\
    arch/arm/tools/mach-types|arch/arm/include/asm/setup.h)
      kept=$((kept+1)); continue ;;
  esac
  if [ -f "../vanilla-2.6.28/$f" ]; then
    cp -a "../vanilla-2.6.28/$f" "$f"
    reverted=$((reverted+1))
  fi
done < ../patched-files.txt
echo "    kept Nokia's version:  $kept files (OMAP, cbus, video, sound, config)"
echo "    reverted to vanilla:   $reverted files (shared core code)"

# The mirror image of the restore above: files 2.6.28 DELETED that Nokia's
# out-of-tree drivers still include. prcm-regs.h went away when 2.6.28 split
# the PRCM registers into prm-*/cm-* headers, but the DSP Gateway still wants
# it, so carry Nokia's copy forward.
echo "==> Carrying forward headers 2.6.28 removed"
for f in arch/arm/mach-omap2/prcm-regs.h; do
  if [ ! -f "$f" ] && [ -f "../kernel-source-diablo/kernel-source/$f" ]; then
    cp "../kernel-source-diablo/kernel-source/$f" "$f"
    echo "    restored: $f"
  fi
done

# 2.6.28 has its own mach/dsp_common.h -- the OMAP1 DSP header. Nokia's DSP
# Gateway keeps a DIFFERENT file with the same basename, holding
# struct dsp_platform_data, so plat-omap/devices.c must include theirs too.
echo "==> Wiring plat-omap/devices.c to the DSP Gateway header"
python3 - <<'PYY'
p = 'arch/arm/plat-omap/devices.c'
s = open(p).read()
marker = '#if	defined(CONFIG_OMAP_DSP) || defined(CONFIG_OMAP_DSP_MODULE)'
if marker not in s:
    marker = '#if defined(CONFIG_OMAP_DSP) || defined(CONFIG_OMAP_DSP_MODULE)'
if marker in s and 'dsp/dsp_common.h' not in s:
    s = s.replace(marker, marker + '\n#include "dsp/dsp_common.h"', 1)
    open(p, 'w').write(s)
    print('    added #include "dsp/dsp_common.h"')
else:
    print('    SKIP (marker absent or already wired)')
PYY

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

# When a directory has no objects, 2.6.28 makes built-in.o an EMPTY ar
# archive -- literally the 8 bytes "!<arch>\n". binutils 2.29 cannot derive a
# machine from that, and the final link dies with
#
#   arm-linux-gnueabi-ld: no machine record defined
#
# which names neither the file nor the cause. Three directories hit it here:
# arch/arm/common, arch/arm/lib and firmware. Emit an empty ELF object
# instead, which is what later kernels settled on.
p = 'scripts/Makefile.build'; s = open(p).read()
old = 'rm -f $@; $(AR) rcs $@)'
new = 'rm -f $@; $(CC) $(KBUILD_CFLAGS) -c -x c /dev/null -o $@)'
if old in s:
    open(p, 'w').write(s.replace(old, new, 1))
    print("    Makefile.build: empty built-in.o is now an ELF object, not an empty archive")
else:
    print("    SKIP (empty built-in.o rule already changed)")
PY

# kernel/timeconst.pl uses `defined(@array)`, which Perl removed in 5.22.
# It fails with exit 255 and a message that does not name Perl as the cause.
echo "==> Fixing timeconst.pl for modern Perl"
python3 - <<'PYY'
import re
p = 'kernel/timeconst.pl'
try:
    s = open(p).read()
except IOError:
    print('    SKIP (no timeconst.pl)'); raise SystemExit
n = s
n = re.sub(r'defined\(@\$?(\w+)\)', r'@\1', n)
if n != s:
    open(p, 'w').write(n)
    print('    removed defined(@array), which Perl 5.22 dropped')
else:
    print('    SKIP (already fine)')
PYY

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
# The DSP Gateway is the one Nokia subsystem that does NOT port mechanically.
# It reaches straight into the 2.6.21 PRCM register layout (prcm-regs.h,
# __REG32, OMAP24XX_PRCM_BASE), and 2.6.28 replaced all of that with the
# prm/cm API. Porting it means rewriting the DSP's PRCM access, which is real
# work and should not block a first bootable kernel.
#
# So the default build leaves it out. Set WITH_DSP=1 to keep it in and take on
# that port.
if [ "${WITH_DSP:-0}" != "1" ]; then
  echo "==> Disabling CONFIG_OMAP_DSP for the first build (WITH_DSP=1 to keep it)"
  sed -i 's/^CONFIG_OMAP_DSP=y/# CONFIG_OMAP_DSP is not set/' .config
  sed -i '/^CONFIG_OMAP_DSP_/d' .config
  yes "" | make ARCH=arm oldconfig > ../oldconfig.log 2>&1 || true
fi

echo "    .config written: $(wc -l < .config | tr -d ' ') lines"
grep -E '^CONFIG_(ARCH_OMAP2420|OMAP_DSP|MACH_NOKIA_N800)=' .config | sed 's/^/      /' || true

echo "==> Fetching a period cross compiler"
# GCC 13 cannot build a 2008 kernel. It dies first on GNU89 inline semantics
# (multiple definition of tty_kref_get), then on a cast-as-lvalue that GCC 4.0
# removed, then on assembler syntax. Rather than fight each one, use a
# compiler from the era: kernel.org publishes prebuilt crosstools exactly for
# building old kernels, and 4.9.4 is the oldest they offer for an arm64 host.
case "$(uname -m)" in
  aarch64|arm64) CTHOST=arm64 ;;
  x86_64|amd64)  CTHOST=x86_64 ;;
  *) echo "no kernel.org crosstool for $(uname -m)"; exit 1 ;;
esac
CT="$WORK/gcc-4.9.4-nolibc"
if [ ! -d "$CT" ]; then
  ( cd "$WORK" && curl -fsSL --retry 3 -O \
      "https://mirrors.edge.kernel.org/pub/tools/crosstool/files/bin/$CTHOST/4.9.4/$CTHOST-gcc-4.9.4-nolibc-arm-linux-gnueabi.tar.xz" \
    && tar xf "$CTHOST-gcc-4.9.4-nolibc-arm-linux-gnueabi.tar.xz" )
fi
export PATH="$CT/arm-linux-gnueabi/bin:$PATH"

# That 2016 toolchain wants libmpfr.so.4, which no current distribution ships.
# Debian stretch is the last release that had it, and its archive is still up.
if [ ! -f "$CT/extra-lib/libmpfr.so.4" ]; then
  mkdir -p "$CT/extra-lib" && cd /tmp
  curl -fsSL --retry 2 -o m.deb \
    http://archive.debian.org/debian/pool/main/m/mpfr4/libmpfr4_3.1.5-1_${CTHOST/x86_64/amd64}.deb 2>/dev/null \
    || curl -fsSL --retry 2 -o m.deb \
       http://archive.debian.org/debian/pool/main/m/mpfr4/libmpfr4_3.1.5-1_arm64.deb
  ar x m.deb && tar xf data.tar.xz && cp -a usr/lib/*/libmpfr.so.4* "$CT/extra-lib/"
  cd "$WORK/linux-2.6.28"
fi
export LD_LIBRARY_PATH="$CT/extra-lib:${LD_LIBRARY_PATH:-}"
arm-linux-gnueabi-gcc --version | head -1 | sed 's/^/    /'

echo "==> Building zImage"
cd "$WORK/linux-2.6.28"
if make ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- -j"$JOBS" zImage > ../build.log 2>&1; then
  ls -la arch/arm/boot/zImage | sed 's/^/    /'
  echo "    BUILT: $WORK/linux-2.6.28/arch/arm/boot/zImage"
else
  echo "    BUILD FAILED -- see $WORK/build.log"
  grep -E 'error:|ld:|Error [0-9]' ../build.log | head -10 | sed 's/^/      /'
fi

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
