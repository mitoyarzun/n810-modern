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

### Verified both directions this time

A check that has never failed has not been tested. So:

```
NEGATIVE  check-artifact.sh <toolchain libatomic.so.1>
          FAIL  exports or imports IFUNC symbols          exit 1

POSITIVE  check-artifact.sh <all seven built artefacts>
          All artefacts look device-safe.                 exit 0
```

Sections 6, 7 and 8 are the same mistake at three depths: shipping a library
without running it, checking a property without testing the checker, and
trusting a green result that no red result had ever been seen from. **A test
that has only ever passed is not evidence.**

## 9. stunnel — the one that just worked

OPEN.md #9 asked whether stunnel needs anything Diablo lacks. It was the last
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

### One test bug

The first run passed traffic and then failed:

```
3. Plain HTTP in, TLS 1.3 out      ok    HTTP/1.1 200 OK
4. What stunnel negotiated         FAIL  no TLS 1.3 in the stunnel log
```

The config said `debug = 4`. stunnel logs the negotiated protocol and the
verified chain at level 6. The tunnel worked; the evidence was switched off.
Section 8's rule applied in reverse — a test that fails for the wrong reason is
as misleading as one that cannot fail — so the fix was to raise the level and
filter the 121 CA-loading lines that then bury the four that matter.

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

Not yet proven: that the real 2.6.21 kernel serves every syscall it makes, and
what any of it costs on a 400 MHz ARM1136. Those need the device.

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

Sections for the first device session are stubbed in [OPEN.md](OPEN.md).
`tools/device-smoke-test.sh` collects everything needed: stock package versions,
whether our binaries start at all, protocol support, a real handshake, and
`openssl speed` numbers to confirm or correct the ChaCha20-over-AES preference
in [DESIGN.md](DESIGN.md).
