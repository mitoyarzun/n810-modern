# Build log

What actually happened, in order, with the failures kept in. The failures are
the useful part: every one of them is a way this build succeeds on the host and
dies on the device, and none of them is documented anywhere obvious.

Host: Ubuntu 24.04.4, `gcc-arm-linux-gnueabi` 13.3.0.
Target: Maemo 4.1.2 Diablo, armel, glibc 2.5, Linux 2.6.21.

---

## 1. The sysroot — worked first time

Six `.deb` files from the repository.maemo.org mirrors, unpacked into a
directory and checksummed:

```
libc6                  2.5.0-1osso10
libc6-dev              2.5.0-1osso10
libgcc1                1:3.4.4cs2005q3.2-5.osso8
linux-kernel-headers   2.6.16.osso11-1
zlib1g                 1:1.2.3-9.osso8
zlib1g-dev             1:1.2.3-9.osso8

glibc 2.5, kernel headers 2.6.16, 18 absolute symlinks relativised, 27 MB
```

Absolute symlinks inside a sysroot resolve against the **host** filesystem, so
`/usr/lib/libz.so -> /lib/libz.so.1` would silently link the host's zlib.
`mk-sysroot.sh` rewrites them relative. (Linker *scripts* are fine — GNU ld
applies `--sysroot` to absolute paths inside them.)

### Mirror notes

`repository.maemo.org` has been 503 since ~2021. Of the two community mirrors:

- **`maemo.viniciuspaes.com`** requires a `Referer` header pointing back into
  the mirror, or it answers **403**. It also rate-limits: after about two dozen
  requests it 403s everything for a while regardless of headers. Its front page
  asks people not to bulk-mirror it.
- **`maemo.wunderwungiel.pl/repository.maemo.org`** carries the full original
  `pool/` with no hotlink protection.

So: indexes from the first (once, cached), payloads from the second, and
everything pinned by MD5 in `tools/diablo-sysroot.manifest` so neither has to
stay up.

## 2. ABI note — caught before it reached the device

A trivial `hello.c` built with `--sysroot` alone:

```
$ file hello
... interpreter /lib/ld-linux.so.3, for GNU/Linux 3.2.0
```

**`GNU/Linux 3.2.0`.** The device runs 2.6.21, and its loader reads that
`.note.ABI-tag` and refuses the binary outright — `FATAL: kernel too old`.

The cause: Ubuntu's cross-GCC hardcodes its own startfile prefix, and
`--sysroot` does not override it.

```
$ arm-linux-gnueabi-gcc --sysroot=$S -print-file-name=crt1.o
/usr/.../arm-linux-gnueabi/lib/crt1.o        <- host's, ABI 3.2.0
$S/usr/lib/crt1.o                            <- device's, ABI 2.6.8
```

Fix: `-B$SYSROOT/usr/lib`. Result: `for GNU/Linux 2.6.8`, `EABI4`, and only
`GLIBC_2.4` symbols required. That binary will run.

## 3. Header leak — the dangerous one

First OpenSSL build got most of the way through and then died linking one
optional engine:

```
e_loader_attic.c:(.text+0xd78): undefined reference to `__stat64_time64'
```

`__stat64_time64` is a glibc **2.34+** symbol. Against glibc 2.5 headers it
cannot exist. So the headers were not glibc 2.5's:

```
#include <...> search starts here:
 /usr/lib/gcc-cross/arm-linux-gnueabi/13/include
 /usr/lib/gcc-cross/arm-linux-gnueabi/13/../../../../arm-linux-gnueabi/include   <-- glibc 2.39
 .../sysroot-diablo/usr/include                                                  <-- glibc 2.5
```

The host toolchain's own glibc 2.39 headers sit **ahead** of the sysroot, and
`--sysroot` does not remove them. Any header present in both was taken from
2.39.

This is worse than a build failure. Most of the tree compiled "successfully"
against the wrong libc; one unlucky object happened to reference a symbol that
did not exist and exposed it. Everything else would have shipped.

Fix: `-nostdinc -isystem <gcc-internal> -isystem <sysroot>/usr/include`, and
verify the search list rather than assuming.

## 4. `pread64` already defined

Rebuild with clean headers, new failure, much earlier:

```
{standard input}:1048: Error: symbol `pread64' is already defined
```

glibc 2.5's `unistd.h` under `__USE_FILE_OFFSET64` declares `pread` via
`__REDIRECT(..., pread64)` *and* declares `pread64` itself — a glibc bug fixed
in 2.7, two years after this device's libc.

But nothing passed `-D_FILE_OFFSET_BITS=64`. The cause is the host:
**Ubuntu 24.04 ships its 32-bit cross-compilers with the 64-bit time_t and
large-file transition enabled by default**, predefining `_FILE_OFFSET_BITS=64`
and `_TIME_BITS=64`. This is also the real root of failure 3.

The device's userland is 32-bit `off_t` and 32-bit `time_t`. Fix:
`-U_FILE_OFFSET_BITS -U_TIME_BITS`.

## 5. `multiple definition of __strpbrk_c3` — and no `getcontext`

Third build reached the final link of `libcrypto.so.3` and produced dozens of:

```
multiple definition of `__strpbrk_c3'
multiple definition of `__strtok_r_1c'
multiple definition of `stpncpy'
```

glibc 2.5's `bits/string2.h` defines these as `extern __inline` under **GNU89**
inline semantics, where that emits no external symbol. GCC 5+ defaults to
`gnu11`, whose C99 inline rules emit an external definition in every
translation unit including the header.

Fix: `-fgnu89-inline` (C only — never pass it to `g++`).

The same link surfaced three warnings worth acting on:

```
warning: getcontext is not implemented and will always fail
warning: setcontext is not implemented and will always fail
warning: makecontext is not implemented and will always fail
```

glibc 2.5 on ARM has no `ucontext` implementation, so OpenSSL's fibre-based
ASYNC could never work. Added `no-async` rather than shipping a feature that
fails at runtime.

## 6. `libatomic.so.1` — the build was clean and would still not have loaded

The fourth build completed: libraries linked, `install_sw` staged a tree, and
every artefact passed `check-artifact.sh`. Then the dependency list:

```
libcrypto.so.3  NEEDED: libdl.so.2 libatomic.so.1 libpthread.so.0 libc.so.6
```

**`libatomic.so.1`.** ARMv6 has no 64-bit atomic instructions, so GCC emits
calls into libatomic for them. libatomic arrived with GCC 4.7 in 2012. Diablo's
newest compiler is GCC 4.2, and `libatomic` appears **zero** times across both
the SDK index (796 packages) and the extras index. On the device this is:

```
libatomic.so.1: cannot open shared object file
```

A perfectly clean build, verified by a checker that passed it, that could never
have started.

The fix looked easy — the toolchain's `libatomic.so.1` needs nothing newer than
`GLIBC_2.4`, so it can travel with us; 40 KB. So we shipped it. The lesson we
took was not the fix. It was that the checker only tested the properties we had
already been burned by. So `check-artifact.sh` now resolves **every** `NEEDED`
soname against a stock Diablo baseline and fails on anything that is neither in
it nor shipped alongside.

**That fix was wrong, and section 7 is how we found out.** Shipping the library
was not enough. Read on before you trust this section.

## 7. IFUNC — the shipped library that still could not be used

Sections 1 to 6 all end the same way: "not yet proven, that needs the device."
That was not true. The device's userland is in the sysroot, and QEMU can run
armel binaries against it. `tools/qemu-smoke.sh` does exactly that: it runs our
`openssl` under `qemu-arm -L sysroot-diablo`, so the loader doing the work is
the device's own glibc 2.5 `ld-linux.so.3`, not the host's.

The first run, on the artefacts section 6 declared device-safe:

```
relocation error: /opt/handshake/lib/libcrypto.so.3: symbol __atomic_fetch_add_8,
version LIBATOMIC_1.0 not defined in file libatomic.so.1 with link time reference
```

`libatomic.so.1` was present, it was ours, and it **does** define that symbol:

```
25: 000047d4  112  IFUNC  GLOBAL DEFAULT  13  __atomic_compare_exchange_8@@LIBATOMIC_1.0
30: 00004624  112  IFUNC  GLOBAL DEFAULT  13  __atomic_load_8@@LIBATOMIC_1.0
45: 000046ec  112  IFUNC  GLOBAL DEFAULT  13  __atomic_store_8@@LIBATOMIC_1.0
63: 00004a0c  112  IFUNC  GLOBAL DEFAULT  13  __atomic_fetch_add_8@@LIBATOMIC_1.0
```

**`IFUNC`**, not `FUNC`. A GNU indirect function: the symbol points at a
resolver that the loader calls at load time to pick an implementation. IFUNC
arrived in glibc 2.11 in 2009, and on ARM later still. Diablo has glibc 2.5,
from 2006. Its loader does not know symbol type 10 exists, so it treats the
entry as no definition at all — and says so, misleadingly, as "not defined".

Isolated with one 12-line library, built once and run twice under the same
QEMU, changing only the loader:

| Loader | `plain_fn()` | `ifunc_fn()` |
| --- | --- | --- |
| glibc 2.39 armel | 42 | 99 |
| glibc 2.5 Diablo | 42 | `undefined symbol` |

The plain function resolves in both. Only the IFUNC fails, and only on the old
loader. So this is not a QEMU artefact — it is what the tablet would have done.

`libatomic.a` is IFUNC-based too, so static linking does not escape it. There
is no version of "ship libatomic" that works.

### The fix

Only `crypto/threads_pthread.c` uses the 64-bit atomics, and OpenSSL has a
supported switch to turn them off:

```
-DBROKEN_CLANG_ATOMICS
```

The name is misleading — there is no clang here — but it is the documented
guard OpenSSL uses to select mutex-based fallbacks instead of `__atomic_*`
builtins. With it, `libcrypto.so.3` has no `libatomic` dependency to satisfy.
The cost is a mutex where an atomic would do, on one 400 MHz core with no
contention. That is not measurable.

`build-openssl.sh` no longer bundles libatomic. It now **fails the build** if
libatomic reappears, because a copy cannot help.

One loose end, found by reading the packaged tree rather than the binaries.
OpenSSL records the flag in its installed metadata whether or not the library
uses it:

```
libcrypto.pc:  Libs.private: -ldl -pthread -latomic
OpenSSLConfig.cmake:  set(OPENSSL_LIBCRYPTO_DEPENDENCIES -ldl -pthread -latomic)
```

`libcrypto.so.3` itself has no `libatomic` in `NEEDED` — the linker dropped it,
because nothing referenced it. But the next package to link against us reads
`libcrypto.pc`, and `stunnel` is next. Autotools of Diablo's era do not pass
`--as-needed`, so `-latomic` would stick and stunnel would arrive on the device
with exactly the `DT_NEEDED` that could not load. `build-openssl.sh` now scrubs
the flag from the metadata and fails if any survives.

### What the checker learned

Check 6 asked "does this library ship with us?" and libatomic did, so it
passed. Nothing asked whether glibc 2.5 can *resolve* what is inside it.
`check-artifact.sh` now rejects any artefact that defines or references an
IFUNC symbol.

But the real lesson is bigger than one check. Section 6 already said the
checker was "only testing the properties we had already been burned by", added
a check, and moved on — and the very next thing to go wrong was another
property we had not been burned by yet. A static checker can only encode
failures someone has already met. Running the thing is different in kind.

**`tools/qemu-smoke.sh` should run on every build, before packaging.**
`tools/build-in-docker.sh` does that, so a host with Docker and nothing else
gets a build and a test.

### What QEMU still does not prove

`qemu-arm` emulates the CPU and translates syscalls to the host kernel. It does
not refuse syscalls that 2.6.21 lacked. So it proves the loader accepts our
binaries and the crypto and TLS work; it does not prove the real kernel serves
every call OpenSSL makes. The tablet is still the final word — but it is now
the final word on a much shorter list.

## 8. `set -o pipefail` and `grep -q` — the check that could never fail

Section 7 added an IFUNC check to `check-artifact.sh`. The obvious next question
is whether it works, so it was pointed at the exact library that caused the bug:

```
== .../arm-linux-gnueabi/lib/libatomic.so.1
   ok    no IFUNC symbols
All artefacts look device-safe.
```

It passed. The library with 68 IFUNC symbols in it passed an IFUNC check. Run
by hand, the same command finds them:

```
$ arm-linux-gnueabi-readelf --dyn-syms -W libatomic.so.1 | grep -c ' IFUNC '
68
```

The script is `set -uo pipefail`, and the check was written as a pipeline:

```sh
if $T-readelf --dyn-syms -W "$f" 2>/dev/null | grep -q ' IFUNC '; then
```

`grep -q` exits at the **first** match. `readelf` is still writing, so it dies
of `SIGPIPE`, and under `pipefail` the pipeline reports the producer's status:

```
pipefail + grep -q, match present -> exit 141
pipefail + grep -q, no match      -> exit 1
```

Both are non-zero. The `if` takes the else branch either way, so the check
reports "ok" whatever it is given. It cannot fail. It never could.

It only bites when the producer's output outruns the pipe buffer. That is why
`grep -q 'Machine:.*ARM'` on a 13-line `readelf -h` has always worked, and why
the symbol-table checks do not.

### What else this hit

**Check 4, the 64-bit `time_t` check, was vacuous from the day it was written.**
Same shape, same `--dyn-syms` producer:

```sh
if $T-readelf --dyn-syms -W "$f" 2>/dev/null | grep -qE '_time64|_TIME_BITS'; then
```

That check is the verification for one of the six flags in the summary table
below — the header leak in section 3, the failure described there as the
dangerous one because it is silent. Its detector was silent too. The builds
were in fact clean, but the checker was not what proved it.

### The fix

Capture the output once, then match against the variable. A here-string is not
a pipeline, so there is no `SIGPIPE` and `pipefail` does not apply:

```sh
dynsyms=$($T-readelf --dyn-syms -W "$f" 2>/dev/null || true)
...
if grep -q ' IFUNC ' <<<"$dynsyms"; then
```

`build-openssl.sh` had the same shape in the guard added in section 7, and is
fixed the same way.

## 9. stunnel — the one that just worked

README (status) #9 asked whether stunnel needs anything Diablo lacks. It was the last
unknown before the consumer work, and the honest answer was that nobody had
looked. A cross-build answers it in ten minutes and needs no device.

It built first time. `tools/build-stunnel.sh` is `build-openssl.sh` with a
different tarball and four `configure` flags:

```
--disable-systemd    Diablo predates systemd by five years
--disable-libwrap    tcp_wrappers is not in the Diablo index
--disable-fips       needs a validated provider we do not ship
--with-ssl=$OUT/opt/handshake
```

Plus two `ac_cv_*` cache variables, because autoconf answers those questions by
running a test program and cross-compiling cannot run one.

The dependency list is the answer to #9:

```
stunnel  NEEDED: libssl.so.3 libcrypto.so.3 libutil.so.1 libpthread.so.0
                 libc.so.6 ld-linux.so.3
```

Two are ours. The rest are stock Diablo, `libutil.so.1` included. **stunnel
needs nothing the device does not have.**

### Proving it, again without the device

`tools/qemu-stunnel-test.sh` runs the armel stunnel under `qemu-arm` on glibc
2.5, in client mode, and then speaks **plain HTTP** to it:

```
1. It starts at all
   ok    stunnel 5.80 on arm-unknown-linux-gnueabi platform
         Compiled/running with OpenSSL 3.5.8
         Threading:PTHREAD Sockets:POLL,IPv6 TLS:ENGINE,OCSP,PSK,SNI,DTLS
2. It runs as a client tunnel
   ok    listening on 127.0.0.1:18443
3. Plain HTTP in, TLS 1.3 out
   ok    HTTP/1.1 200 OK
4. What stunnel negotiated
         Certificate accepted at depth=0: CN=example.org
         Negotiated TLSv1.3 group: X25519MLKEM768
         TLSv1.3 ciphersuite: TLS_AES_256_GCM_SHA384 (256-bit encryption)
   ok    TLS 1.3 negotiated, chain verified to the leaf
```

That third step is the entire point of the package. The client speaking to
stunnel used no TLS at all — exactly what a stock Diablo application can do.

`X25519MLKEM768` is worth a second look. A device from 2008 negotiating a
post-quantum hybrid key exchange, because none of that lives in the kernel or
the libc — it is all in the library we replaced.

## 10. The real device, in an emulator

Sections 7 to 9 all carry the same caveat: `qemu-arm` runs our binaries on the
device's glibc, but it translates syscalls to the **host** kernel. So none of
it could answer the question README said only the tablet could — does Linux
2.6.21 serve every syscall OpenSSL 3.5 makes?

It can be answered, and without the tablet.

### Getting the actual device

Nokia's `tablets-dev.nokia.com` has been dead for years, but `skeiron.org`
mirrors it, and the final Diablo release for the N810 is still there with
Nokia's own published MD5 beside it:

```
RX-44_DIABLO_5.2008.43-7_PR_COMBINED_MR0_ARM.bin
md5 a0738fcc7b556d1c6d49d796b48a7a37   <- matches MD5SUMS
```

`0xFFFF` unpacks the FIASCO container into the parts:

```
kernel_2.6.21-200842maemo1        ARM zImage, the real kernel
initfs_0.95.22-200842maemo1w38b3  jffs2
rootfs_..._DIABLO_5.2008.43-7     jffs2, 125 MB
xloader / secondary / 2nd         bootloaders, per HW revision
```

`jefferson` extracts the rootfs to a directory: 220 MB, 622 packages. That is
the device's userland, on disk, before anything has been switched on.

### What it settles immediately

Every version in [DECISIONS.md](DECISIONS.md) came from the Diablo package index,
which is not the same thing as the device. Now they can be read from the
firmware itself, and README (status) #1 closes:

| | Package index said | Firmware says |
| --- | --- | --- |
| glibc | 2.5 | `libc-2.5.so`, `ld-linux.so.3` |
| libc6 | 2.5.0-1osso10 | 2.5.0-1osso10 |
| zlib1g | 1:1.2.3-9.osso8 | 1:1.2.3-9.osso8 |
| OpenSSL | 0.9.8e | 0.9.8e-9maemo3 |
| libcurl3 | 7.15.5 | 7.15.5-1osso4 |
| kernel | 2.6.21 | `Linux version 2.6.21-omap1 ... #2 Tue Oct 14 2008` |

Both sysroot pins are exactly right. One thing the index could not have told
us: **a stock Diablo device has no `openssl` CLI, no `wget`, no `curl` and no
Python at all** — only the `libssl0.9.8` library. That changes what a first
session with the tablet can even do, and it is an argument for shipping the
CLI.

### Booting it

`qemu-system-arm -M n810` still exists in QEMU 8.2 (Ubuntu 24.04). It was
**removed in QEMU 9.2**, so this needs 9.1 or earlier.

Three faults stood in the way, and every one of them reported success:

**Partition offsets.** Guessed at first. The kernel prints its own table, so
read it rather than guessing:

```
0x00000000-0x00020000 : "bootloader"
0x00020000-0x00080000 : "config"
0x00080000-0x002a0000 : "kernel"
0x002a0000-0x006a0000 : "initfs"
0x006a0000-0x10000000 : "rootfs"
```

**Zero-filled image.** Erased NAND reads as all ones, and a block is marked bad
by a zero in its out-of-band marker. A zero-filled image says every block is
bad:

```
Bad eraseblock 1 at 0x00020000
Bad eraseblock 2 at 0x00040000     ... 2048 of them, the entire chip
```

**The missing 8 MB.** The real cause, and `0xFF` filling alone did not fix it.
From `hw/block/onenand.c`:

```c
s->image = memset(g_malloc(size + (size >> 5)), 0xff, size + (size >> 5));
```

QEMU keeps the out-of-band area **in the same backing file**, appended after
the main data. A 256 MB OneNAND needs a **264 MB** file. Ours was 256 MB, so
the OOB region was short, every block still read bad, and the kernel skipped
the whole chip.

What makes this expensive is the failure mode. JFFS2 mounts a blank partition
quite happily — an erased chip is a valid empty filesystem — so the mount
**succeeds**:

```
VFS: Mounted root (jffs2 filesystem).
Freeing init memory: 124K
Kernel panic - not syncing: No init found.
```

`No init found` sends you looking at the rootfs contents, `init=`, the symlink
from `/bin/sh` to busybox. The cause is eight megabytes of absent metadata at
the far end of the file.

With the file at 264 MB and `0xFF`-filled:

```
Bad eraseblocks: 0
VFS: Mounted root (jffs2 filesystem).

BusyBox v1.6.1 (2008-09-18 09:43:17 EEST) Built-in shell (ash)
/ #
```

### The answer

`mkfs.jffs2` rebuilds the rootfs with `/opt/handshake` inside it, and the test
script runs as `init`:

```
Linux version 2.6.21-omap1 (gcc version 3.4.4 (CodeSourcery ARM 2005q3-2))

1. Our openssl starts     OpenSSL 3.5.8
2. Providers              default: active   legacy: active
3. Crypto                 SHA-256, rand, RSA-2048 keygen, EC P-256 keygen
4. stunnel                stunnel 5.80, PTHREAD Sockets:POLL,IPv6
```

**Linux 2.6.21 serves every syscall OpenSSL 3.5 and stunnel 5.80 make.** That
was the largest remaining unknown and it did not need the hardware.

The emulator also reproduced the trap in README (status) #10 on its own:

```
clock: Thu Jan  1 00:00:09 UTC 1970
```

A 1970 clock makes every certificate "not yet valid" and fails TLS in a way
that reads exactly like a TLS bug. Here it is the emulator having no RTC; on
an eighteen-year-old tablet it will be the backup battery. Same symptom.

### What the emulator still cannot tell us

`openssl speed` runs, and the numbers came out the way DECISIONS.md predicted —
ChaCha20-Poly1305 about 4x AES-128-GCM. **Do not record that as a measurement.**
QEMU's TCG retranslates ARM into the host's instruction set and models neither
the ARM1136 pipeline nor its cache and memory latency, so it distorts the cost
of an instruction mix, and the ratio between two ciphers is exactly the kind of
thing it distorts. DECISIONS.md #19 stays a prediction.

Also still hardware-only: the WiFi stack, real flash space and wear, the RTC
and its battery, and the display. The emulated machine has no network device
working either — its USB controller does not come up (`Could not start
tusb6010`), so the TLS handshakes in sections 7 to 9 stay with `qemu-arm`
user-mode, which has the host's network.

The two tools are `tools/mk-diablo-emulator.sh` and `tools/emulator-smoke.sh`.

## 11. The desktop — eight fixes, and what each one taught

Section 10 got the real firmware booting to a shell, which is all the TLS work
needs. Reaching the **desktop** is a different problem, and it took eight
fixes. They are worth recording not for their own sake but because seven of
the eight failed *silently* or reported something misleading.

### The chain

| # | What it said | What it was |
| --- | --- | --- |
| 1 | `Bad battery type: 65535, shutting down` | the emulator has no battery, and DSME powers the machine off |
| 2 | `Entering state ''` → panic | `dsme_state` comes from DSME, which is now off |
| 3 | `Entering state 'MALF'` → panic | `boot()` re-queries `bootstate` after mounting |
| 4 | `Error, X server did not start` | 20 init scripts launch daemons via `dsmetool -r`, which needs DSME |
| 5 | `Permission denied` writing its own config | `jefferson` does not preserve uid/gid |
| 6 | X restarting four times, no desktop | `dsp-init` fails; QEMU cannot load a DSP binary |
| 7 | frozen splash, healthy X | nobody flushes a manual-update panel |
| 8 | `sudo: not found`, three scripts | `jefferson` drops hardlinks |

Five of those are consequences of fix 1. Disabling DSME is invasive: on Maemo,
DSME is both the process supervisor **and** part of the boot state machine.
Every later failure came from removing it, and each was only visible after the
previous one cleared.

### The display, which is the interesting one

The N800/N810 panel is **manual-update**. QEMU is faithful to this. From
`hw/display/blizzard.c`, the emulated controller redraws only when the guest
pushes pixels through its data port at register `0x90`:

```c
if (!s->data.len && !blizzard_transfer_setup(s)) break;
*s->data.ptr ++ = value;
if (-- s->data.len == 0) blizzard_window(s);
```

There is no continuous redraw loop. `fb-progress` and `show_image` push
explicitly, which is why the boot splash and the Nokia logo always rendered.
`Xomap` does not, so the desktop drew into memory nobody flushed and the screen
stayed frozen on the splash while everything above it was healthy.

`tools/fb-autoupdate.c` asks the driver to refresh on its own timer with
`OMAPFB_SET_UPDATE_MODE`, `_IOW('O', 40, int)`. It is cross-compiled for the
guest with **this project's own toolchain** — the first thing built here that
is neither OpenSSL nor stunnel, and a better proof that the build environment
generalises than anything in the README.

The proof it worked was accidental and complete: the noise from the failed
`dd` test appeared on screen the moment auto-update came on — 163 rows of it,
which is exactly 256 KB at 800x480x16bpp.

### What `jefferson` costs

It exits 0 and loses two things, neither documented:

- **uid/gid** — the whole tree extracts as `root:root`
- **hardlinks** — only the first name per inode survives

The second is subtle. `/usr/bin/sudo` was "missing" while `/usr/bin/sudoedit`
sat there as the identical setuid-root binary; they are one inode on the
device. Restoring the link is exact, not a workaround. Checking the tree
against dpkg's own file lists found both classes at once, and is worth doing
after any JFFS2 extraction:

```sh
for l in rootfs/var/lib/dpkg/info/*.list; do
  while read -r f; do [ -e "rootfs$f" ] || echo "$f"; done < "$l"
done
```

Most of what that reports is `/usr/share/doc` and man pages, which Maemo
genuinely strips from the device. Filter to `bin/`, `sbin/` and `.so` and the
real losses stand out — there were eight.

## 12. The build only worked on one machine

Everything above was developed on a single x86-64 Debian host. The first time
anyone ran it elsewhere — an Apple M4, native arm64, Docker via colima — it
died twenty-five seconds in, on the very first package:

```
tar: ./usr/share/zoneinfo/localtime: Cannot open: Permission denied
tar: Exiting with failure status due to previous errors
dpkg-deb: error: tar subprocess returned error exit status 2
```

The message names a symlink, so that is where the investigation starts and
where it wastes its time. Creating that exact symlink at that exact path on
the same mount works. So does every other kind:

```
relative symlink                OK
absolute symlink inside share   OK
absolute symlink outside share  OK
```

The archive is the answer, not the path it named:

```
hrw-r--r-- ./usr/share/zoneinfo/Etc/GMT-0     link to ./usr/share/zoneinfo/Etc/Greenwich
hrw-r--r-- ./usr/share/zoneinfo/Etc/Universal link to ./usr/share/zoneinfo/Etc/UTC
```

Diablo's `libc6` ships **hardlinked** zone files. Unpacking them onto a macOS
bind mount fails, and `--no-same-owner --no-same-permissions` changes nothing —
the host filesystem is refusing, not the extraction. Extracting the same
package to a container-local path succeeds every time.

### The fix is not a workaround

`tools/build-in-docker.sh` now keeps the build tree in a **Docker volume**
instead of a bind mount. Only the finished artefacts cross back, into `dist/`.

That is better engineering independent of the bug. The sysroot, the OpenSSL
tree and the flash images are all build intermediates that no host tool needs
to see; putting them on a shared filesystem bought nothing and cost both
correctness and speed. Any host filesystem's semantics — virtiofs, 9p, sshfs,
whatever Windows does — are now irrelevant.

### And the timing claim was wrong

The README said "about fifteen minutes on four cores", measured on the Debian
host. From a clean tree, including both QEMU suites:

| Host | Time |
| --- | --- |
| Apple M4, native arm64 container | **2m 03s** |
| x86-64, 4 cores, Debian 13 | ~15m |

`gcc-arm-linux-gnueabi` is packaged for arm64 as well as amd64, so Apple
Silicon cross-compiles natively instead of through x86 emulation. The build
script had `--platform linux/amd64` hardcoded, which would have forced every
arm64 user into emulation for no reason. It now runs native by default.

## Result

```
== out/opt/handshake/bin/openssl
   ok    ABI note 2.6.8
   ok    glibc symbols <= GLIBC_2.4
   ok    no 64-bit time_t symbols
   ok    interpreter /lib/ld-linux.so.3
   ok    libssl.so.3 ships with us
   ok    libcrypto.so.3 ships with us
...
All artefacts look device-safe.
```

OpenSSL 3.5.8, `linux-armv4`, ARM assembly enabled (AES, bit-sliced AES,
P-256, SHA-1/256/512, Keccak, Poly1305). On-device footprint:

| | |
| --- | --- |
| `libcrypto.so.3` | 3.6 MB |
| `libssl.so.3` | 832 KB |
| `openssl` CLI | 772 KB |
| `legacy.so` provider | 88 KB |
| **runtime total** | **5.3 MB** |

Static libraries (8.3 MB) and headers (2.3 MB) stay on the build host.

Proven under QEMU on the device's own glibc 2.5 loader:

```
openssl   1. It starts at all        ok   OpenSSL 3.5.8, linux-armv4
          2. Providers load          ok   default, legacy
          3. Crypto works            ok   sha256, random, RSA + EC keygen
          4. TLS 1.3 to example.org  ok   TLS_AES_256_GCM_SHA384, Verify OK

stunnel   1. It starts at all        ok   stunnel 5.80, arm-unknown-linux-gnueabi
          2. Client tunnel runs      ok   listening on 127.0.0.1
          3. Plain HTTP in, TLS out  ok   HTTP/1.1 200 OK
          4. What it negotiated      ok   TLS 1.3, X25519MLKEM768, chain verified
```

Proven on the **real 2.6.21 kernel and the real Diablo userland**, under
full-system emulation (section 10): openssl and stunnel both start, both
providers load, and keygen works. The kernel serves every syscall they make.

Still hardware-only: real timings, WiFi, the RTC and its battery, flash space
and wear, and the display.

## Summary: the six flags

| Flag | Failure it prevents | When you'd find out |
| --- | --- | --- |
| `-B$SYSROOT/usr/lib` | ABI note says Linux 3.2 | On the device: `FATAL: kernel too old` |
| `-nostdinc -isystem …` | Compiles against host glibc 2.39 | Sometimes at link; otherwise never |
| `-U_FILE_OFFSET_BITS -U_TIME_BITS` | glibc 2.5 LFS header bug | At assembly |
| `-fgnu89-inline` | GNU89 vs C99 inline semantics | At final link |
| `no-async` | `ucontext` missing on glibc 2.5/arm | At runtime, on the device |
| `-DBROKEN_CLANG_ATOMICS` | IFUNC symbols glibc 2.5 cannot resolve | At startup, on the device |

Four of the six are consequences of the **host** being modern, not of the
target being old. That is the part worth remembering.

## Still to record (needs hardware)

Sections for the first device session are stubbed in [README.md](README.md).
`tools/device-smoke-test.sh` collects everything needed: stock package versions,
whether our binaries start at all, protocol support, a real handshake, and
`openssl speed` numbers to confirm or correct the ChaCha20-over-AES preference
in [DECISIONS.md](DECISIONS.md).
