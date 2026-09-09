# Cross-compilation environment for Maemo 4.1.2 (Diablo) on the Nokia N800/N810.
# Source this:  . tools/env.sh [sysroot-dir]
#
# Targets the device's glibc 2.5 with a modern GCC. See BUILDLOG.md for why each
# flag is here -- several of them are load-bearing.

DIABLO_SYSROOT="${1:-${DIABLO_SYSROOT:-$PWD/sysroot-diablo}}"
export DIABLO_SYSROOT

if [ ! -d "$DIABLO_SYSROOT/usr/include" ]; then
  echo "env.sh: no sysroot at $DIABLO_SYSROOT -- run tools/mk-sysroot.sh first" >&2
  return 1 2>/dev/null || exit 1
fi

export TARGET=arm-linux-gnueabi

# -B is load-bearing, not decoration. Ubuntu's cross-GCC hardcodes its own
# startfile prefix, so --sysroot alone still links the HOST's crt1.o -- which
# carries a .note.ABI-tag of "Linux 3.2.0". The device runs 2.6.21, so its
# loader rejects such a binary outright ("FATAL: kernel too old"). -B points at
# the sysroot's crt files, whose note reads 2.6.8. Check with:
#     readelf -n <binary> | grep -A2 NT_GNU_ABI      -> must say 2.6.8
#
# -march=armv6 -mtune=arm1136jf-s: the OMAP2420's core. The toolchain defaults
# to armv5t, which works but leaves instructions on the table.
#
# -mfloat-abi=softfp -mfpu=vfp: the ARM1136JF-S has VFPv2 and Diablo uses it --
# the device's own libm contains ~6800 VFP instructions. softfp keeps the base
# AAPCS calling convention (floats in core registers), so it stays link-
# compatible with every stock Diablo library. Do NOT use -mfloat-abi=hard.
#
# -z noexecstack: Diablo's 2005-era crt objects predate .note.GNU-stack, so
# modern ld would otherwise mark the stack executable and warn about it.
#
# -nostdinc + explicit -isystem is also load-bearing, and this one is nastier.
# Ubuntu's cross-GCC searches its OWN /usr/arm-linux-gnueabi/include (glibc
# 2.39 headers) BEFORE the sysroot, and --sysroot does not remove it. Any
# header present in both is then taken from 2.39, which happily emits calls to
# symbols glibc 2.5 has never heard of -- __stat64_time64 and friends from the
# 64-bit time_t transition. Most of the build still succeeds; you find out at
# link time, on one unlucky object file, or not at all. Verify with:
#     $CC -v -E -x c /dev/null 2>&1 | sed -n '/search starts here/,/End of/p'
# The list must contain the GCC internal include dir and the sysroot, and
# nothing under /usr/arm-linux-gnueabi.
GCC_INTERNAL_INCLUDE="$($TARGET-gcc -print-file-name=include)"

ARCH_FLAGS="-march=armv6 -mtune=arm1136jf-s -mfloat-abi=softfp -mfpu=vfp"
SYSROOT_FLAGS="--sysroot=$DIABLO_SYSROOT -B$DIABLO_SYSROOT/usr/lib"
# Our own staged headers must come BEFORE the sysroot's, and this ordering is
# load-bearing for every package after the first.
#
# The sysroot is the device: it contains Diablo's zlib 1.2.3 headers from 2005.
# Once we ship a newer zlib of our own, anything compiled against the sysroot's
# copy fails -- curl 8.x dies on `z_const undeclared`, a macro zlib gained in
# 1.2.6 (2012).
#
# Passing our prefix as -I does NOT fix it. GCC ignores a -I directory that is
# also given as -isystem, and packages add their own -isystem for the prefix
# you point them at (curl's configure even rewrites -I to -isystem on purpose:
# "checking convert -I options to -isystem"). The -I is dropped, ours lands
# behind the sysroot in -isystem order, and the 2005 header wins. That is
# invisible: the error names a macro in the consuming package, with the correct
# header installed two directories away.
#
# So the staging prefix goes first in the -isystem chain, here, once.
HANDSHAKE_STAGE="${HANDSHAKE_STAGE:-$PWD/out/opt/handshake}"
STAGE_INCLUDE=""
[ -d "$HANDSHAKE_STAGE/include" ] && STAGE_INCLUDE="-isystem $HANDSHAKE_STAGE/include"
INCLUDE_FLAGS="-nostdinc -isystem $GCC_INTERNAL_INCLUDE $STAGE_INCLUDE -isystem $DIABLO_SYSROOT/usr/include"

# Ubuntu 24.04 ships its 32-bit cross-compilers with the 64-bit time_t / large
# file transition ON BY DEFAULT: GCC predefines _FILE_OFFSET_BITS=64 and
# _TIME_BITS=64. glibc 2.5 predates both. _FILE_OFFSET_BITS=64 turns on
# __USE_FILE_OFFSET64, and glibc 2.5's unistd.h then declares pread twice --
# once via __REDIRECT to "pread64" and once as pread64 itself -- which the
# assembler rejects with:
#     Error: symbol `pread64' is already defined
# (a glibc bug fixed upstream in 2.7, long after this device shipped).
# The device's own userland is 32-bit off_t and 32-bit time_t. Match it.
LEGACY_FLAGS="-U_FILE_OFFSET_BITS -U_TIME_BITS"

# glibc 2.5's bits/string2.h defines helpers like __strpbrk_c3, __strtok_r_1c
# and stpncpy as `extern __inline` under GNU89 inline semantics, where such a
# definition is inline-only and emits no external symbol. GCC 5+ defaults to
# gnu11, whose C99 inline rules emit an external definition in EVERY
# translation unit that includes the header -- so the final link dies with
# dozens of:
#     multiple definition of `__strpbrk_c3'
# -fgnu89-inline restores the semantics these headers were written against.
# C only; the C++ compiler must not be given this flag.
C_LEGACY_FLAGS="-fgnu89-inline"

export CC="$TARGET-gcc $SYSROOT_FLAGS $INCLUDE_FLAGS $LEGACY_FLAGS $C_LEGACY_FLAGS $ARCH_FLAGS"
export CXX="$TARGET-g++ $SYSROOT_FLAGS $INCLUDE_FLAGS $LEGACY_FLAGS $ARCH_FLAGS"
export AR="$TARGET-ar"
export RANLIB="$TARGET-ranlib"
export STRIP="$TARGET-strip"
export LD="$TARGET-ld"
export CFLAGS="-O2 -pipe"
# Match the include ordering: our staged libraries before the sysroot's.
STAGE_LIB=""
[ -d "$HANDSHAKE_STAGE/lib" ] && STAGE_LIB="-L$HANDSHAKE_STAGE/lib"
export LDFLAGS="-Wl,-z,noexecstack $STAGE_LIB"

# Where built artefacts land on the device. Deliberately NOT /usr: the whole
# point is to sit alongside the stock OpenSSL 0.9.8e, never on top of it. Also
# keeps several MB off the 256 MB rootfs -- mount or symlink this from the
# 2 GB internal flash.
export HANDSHAKE_PREFIX="${HANDSHAKE_PREFIX:-/opt/handshake}"

echo "diablo cross-env ready"
echo "  sysroot   $DIABLO_SYSROOT (glibc 2.5, headers 2.6.16)"
echo "  target    $TARGET (armv6, softfp, ld-linux.so.3)"
echo "  prefix    $HANDSHAKE_PREFIX (on-device)"
[ -n "$STAGE_INCLUDE" ] && echo "  staged    $HANDSHAKE_STAGE (our headers precede the sysroot's)"

# Always succeed. A sourced file returns the status of its last command, and
# the conditional echo above is false whenever nothing is staged yet -- which
# silently made `. env.sh && $CC ...` skip the compile in
# emulator-gui-build.sh, disabling the display fix with only a warning.
:
