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

## Summary: the five flags

| Flag | Failure it prevents | When you'd find out |
| --- | --- | --- |
| `-B$SYSROOT/usr/lib` | ABI note says Linux 3.2 | On the device: `FATAL: kernel too old` |
| `-nostdinc -isystem …` | Compiles against host glibc 2.39 | Sometimes at link; otherwise never |
| `-U_FILE_OFFSET_BITS -U_TIME_BITS` | glibc 2.5 LFS header bug | At assembly |
| `-fgnu89-inline` | GNU89 vs C99 inline semantics | At final link |
| `no-async` | `ucontext` missing on glibc 2.5/arm | At runtime, on the device |

Four of the five are consequences of the **host** being modern, not of the
target being old. That is the part worth remembering.

## Still to record (needs hardware)

Sections for the first device session are stubbed in [OPEN.md](OPEN.md).
`tools/device-smoke-test.sh` collects everything needed: stock package versions,
whether our binaries start at all, protocol support, a real handshake, and
`openssl speed` numbers to confirm or correct the ChaCha20-over-AES preference
in [DESIGN.md](DESIGN.md).
