#!/usr/bin/env bash
# Build Nokia's own 2.6.21 Diablo kernel with the missing syscalls added.
#
#   tools/mk-kernel-2621-backport.sh [work-dir]
#
# WHY. tools/probe-kernel.sh measured what Diablo's kernel lacks, and it is
# five syscalls. tools/mk-kernel-2628.sh moves Nokia's board support forward to
# get them, which works -- it boots to the Hildon desktop -- but costs the DSP,
# MMC, DVFS and USB power management, and still does not reach Go's floor of
# 3.2. This script does the opposite: it keeps Nokia's kernel, drivers and all,
# and brings the syscalls back. See APPS.md and tools/backport-syscalls.py.
#
# The precedent is Diablo-Turbo, which shipped a custom 2.6.21 in 2011 that
# people ran daily. Flashing is kernel-only and reversible:
#
#   fiasco-flasher -f -k zImage
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${1:-$PWD/build/kernel-2621}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

DIABLO_BASE="http://maemo.wunderwungiel.pl/repository.maemo.org/pool/diablo/free/k/kernel-source-diablo"
ORIG_MD5="732c6a30f41e6e31569d09c7b6d76d9c"
DIFF_MD5="624d20e53fe8da9669f64792750ee1ca"

md5of() { md5 -q "$1" 2>/dev/null || md5sum "$1" | cut -d' ' -f1; }

mkdir -p "$WORK" && cd "$WORK"

echo "==> Fetching Nokia's GPL kernel source"
for f in kernel-source-diablo_2.6.21.orig.tar.gz \
         kernel-source-diablo_2.6.21-200842maemo1.diff.gz; do
  [ -f "$f" ] || curl -fsSL --retry 3 -O "$DIABLO_BASE/$f"
done
[ "$(md5of kernel-source-diablo_2.6.21.orig.tar.gz)" = "$ORIG_MD5" ] || {
  echo "orig.tar.gz md5 mismatch"; exit 1; }
[ "$(md5of kernel-source-diablo_2.6.21-200842maemo1.diff.gz)" = "$DIFF_MD5" ] || {
  echo "diff.gz md5 mismatch"; exit 1; }
echo "    md5 ok"

echo "==> Unpacking"
# Unlike the 2.6.28 rebase, nothing here is relocated: this is Nokia's tree in
# its original layout, headers and all.
rm -rf kernel-source-diablo
tar xzf kernel-source-diablo_2.6.21.orig.tar.gz
( cd kernel-source-diablo && \
  gzip -dc ../kernel-source-diablo_2.6.21-200842maemo1.diff.gz \
    | patch -p1 --forward --silent )

cd kernel-source-diablo/kernel-source

echo "==> Backporting syscalls"
python3 "$HERE/backport-syscalls.py"

# The same RFBI race the 2.6.28 rebase hit, and it is Nokia's own code: the
# completion callback is stored after the registers are touched, so an
# interrupt arriving in between calls NULL.
#
# The stock kernel survives it only because Nokia built with GCC 3.4.4. Built
# with GCC 4.9.4 the store lands differently, QEMU raises FRAMEDONE
# synchronously inside the register write, and the machine panics in
# rfbi_dma_callback before it reaches the desktop. The bug was always there.
echo "==> Fixing the RFBI completion race"
python3 "$HERE/fix-rfbi.py"

echo "==> Fixing what a 2026 host breaks"
python3 - <<'PY'
# GNU Make 4.3 refuses a rule that mixes a normal target with a pattern target.
p = 'Makefile'
s = open(p, encoding='latin-1').read()
changed = []

old = """config %config: scripts_basic outputmakefile FORCE
	$(Q)mkdir -p include/linux include/config
	$(Q)$(MAKE) $(build)=scripts/kconfig $@"""
new = """config: scripts_basic outputmakefile FORCE
	$(Q)mkdir -p include/linux include/config
	$(Q)$(MAKE) $(build)=scripts/kconfig $@

%config: scripts_basic outputmakefile FORCE
	$(Q)mkdir -p include/linux include/config
	$(Q)$(MAKE) $(build)=scripts/kconfig $@"""
if old in s:
    s = s.replace(old, new, 1); changed.append('split config/%config')

old2 = "/ %/: prepare scripts FORCE"
new2 = """/: prepare scripts FORCE
	$(cmd_crmodverdir)
	$(Q)$(MAKE) KBUILD_MODULES=$(if $(CONFIG_MODULES),1) \\
	$(build)=$(build-dir)

%/: prepare scripts FORCE"""
if old2 in s:
    s = s.replace(old2, new2, 1); changed.append('split //%/')

if changed:
    open(p, 'w', encoding='latin-1').write(s)
    print('    Makefile: ' + ', '.join(changed))
else:
    print('    Makefile: already fixed')

# An empty built-in.o is an empty ar archive, and binutils 2.29+ cannot derive
# a machine from it. The final link then fails with "no machine record
# defined", naming no file. Emit an empty ELF object instead.
p = 'scripts/Makefile.build'
s = open(p, encoding='latin-1').read()
old = 'rm -f $@; $(AR) rcs $@)'
new = 'rm -f $@; $(CC) $(KBUILD_CFLAGS) -c -x c /dev/null -o $@)'
if old in s:
    open(p, 'w', encoding='latin-1').write(s.replace(old, new, 1))
    print('    Makefile.build: empty built-in.o is an ELF object, not an archive')
else:
    print('    Makefile.build: already fixed')
PY

# Modern glibc no longer pulls limits.h in transitively, so the host tool
# scripts/mod/sumversion.c fails on PATH_MAX.
python3 - <<'PY'
p = 'scripts/mod/sumversion.c'
s = open(p, encoding='latin-1').read()
if '#include <limits.h>' in s:
    print('    sumversion.c: already fixed')
else:
    s = s.replace('#include <string.h>', '#include <string.h>\n#include <limits.h>', 1)
    open(p, 'w', encoding='latin-1').write(s)
    print('    sumversion.c: include limits.h for PATH_MAX')
PY

# kernel/timeconst.pl uses defined(@array), which Perl removed in 5.22.
if [ -f kernel/timeconst.pl ]; then
  python3 - <<'PY'
import re
p = 'kernel/timeconst.pl'
s = open(p, encoding='latin-1').read()
n = re.sub(r'defined\(@\$?(\w+)\)', r'@\1', s)
if n != s:
    open(p, 'w', encoding='latin-1').write(n)
    print('    timeconst.pl: dropped defined(@array)')
PY
fi

echo "==> Fetching a period cross compiler"
case "$(uname -m)" in
  aarch64|arm64) CTHOST=arm64 ;;
  x86_64|amd64)  CTHOST=x86_64 ;;
  *) echo "no kernel.org crosstool for $(uname -m)"; exit 1 ;;
esac
CT="${CROSSTOOL_DIR:-$WORK/gcc-4.9.4-nolibc}"
if [ ! -d "$CT" ]; then
  ( cd "$(dirname "$CT")" && curl -fsSL --retry 3 -O \
      "https://mirrors.edge.kernel.org/pub/tools/crosstool/files/bin/$CTHOST/4.9.4/$CTHOST-gcc-4.9.4-nolibc-arm-linux-gnueabi.tar.xz" \
    && tar xf "$CTHOST-gcc-4.9.4-nolibc-arm-linux-gnueabi.tar.xz" )
fi
export PATH="$CT/arm-linux-gnueabi/bin:$PATH"
[ -f "$CT/extra-lib/libmpfr.so.4" ] && export LD_LIBRARY_PATH="$CT/extra-lib:${LD_LIBRARY_PATH:-}"
arm-linux-gnueabi-gcc --version | head -1 | sed 's/^/    /'

echo "==> Configuring (Nokia's own board config, unmodified)"
make ARCH=arm nokia_2420_defconfig > "$WORK/defconfig.log" 2>&1 || {
  echo "    FAILED -- see $WORK/defconfig.log"; tail -12 "$WORK/defconfig.log"; exit 1; }
echo "    .config: $(wc -l < .config | tr -d ' ') lines"

echo "==> Building zImage"
if make ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- -j"$JOBS" zImage > "$WORK/build.log" 2>&1; then
  ls -la arch/arm/boot/zImage | sed 's/^/    /'
  echo "    BUILT: $PWD/arch/arm/boot/zImage"
else
  echo "    BUILD FAILED -- see $WORK/build.log"
  grep -E 'error:|Error [0-9]|undefined reference' "$WORK/build.log" | head -12 | sed 's/^/      /'
  exit 1
fi
