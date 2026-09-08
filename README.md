# Handshake

Modern TLS for Maemo 4.1.2 (Diablo) — the Nokia N800 and N810.

The device can still open a socket and send bytes. What it cannot do is complete
a TLS handshake with anything built after roughly 2013: it ships **OpenSSL
0.9.8e**, which tops out at TLS 1.0 with no ECDHE, no AES-GCM, and no SNI. Every
modern server offers TLS 1.2/1.3 with ECDHE and an AEAD cipher, so there is no
overlap at all and the connection dies at ClientHello. This is not a certificate
problem, and no amount of certificate work will fix it.

This project builds a current OpenSSL for the device, alongside the stock one,
and then rebuilds the handful of programs worth pointing at it.

**Status: Tier 1 prep complete, and now tested. The cross-compilation
environment works, OpenSSL 3.5.8 builds clean for the device, and it runs under
QEMU on the device's own glibc 2.5 loader — it starts, loads both providers,
generates keys, and completes a TLS 1.3 handshake to example.org with
`Verification: OK`. stunnel 5.80 builds on top of it and turns a plain-HTTP
client into a verified TLS 1.3 connection, which is modern TLS for stock
applications that will never be rebuilt.
Both run on the **real Diablo firmware** — Nokia's final N810 release, its
actual 2.6.21 kernel and 220 MB userland — under full-system QEMU, which also
boots all the way to the **Hildon desktop** over VNC. Nothing has yet run on
physical hardware; the tablet's battery is swollen and is being replaced.**

## What works today

```sh
tools/setup-host.sh          # cross-compiler + prerequisites (Debian/Ubuntu)
tools/mk-sysroot.sh          # 27 MB Diablo sysroot, checksummed, from mirrors
. tools/env.sh               # cross-env: modern GCC -> glibc 2.5
tools/build-openssl.sh       # OpenSSL 3.5 LTS for armv6
tools/mk-truststore.sh       # current CA store, checksum-verified
tools/build-stunnel.sh       # stunnel 5.80, linked against the above
tools/check-artifact.sh FILE # static checks: will this binary run on the device
tools/qemu-smoke.sh          # actually run it, on the device's own glibc 2.5
tools/qemu-stunnel-test.sh   # plain HTTP in, verified TLS 1.3 out
tools/mk-diablo-emulator.sh  # fetch and unpack Nokia's real N810 firmware
tools/emulator-smoke.sh      # boot it: real 2.6.21 kernel, real userland
tools/emulator-gui-build.sh  # build an image that reaches the desktop
tools/emulator-gui.sh        # boot that, over VNC -- a usable N810
tools/device-smoke-test.sh   # run this ON the tablet
tools/build-in-docker.sh     # all of the above, on any host with Docker
```

End to end that produces 5.3 MB of verified armv6 runtime: `libcrypto.so.3`,
`libssl.so.3`, the `openssl` CLI and the legacy provider.

Measured, from a clean tree, including both QEMU test suites:

| Host | Time |
| --- | --- |
| Apple M4, native arm64 container | **2m 03s** |
| x86-64, 4 cores, Debian 13 | ~15m |

The gap is real: `gcc-arm-linux-gnueabi` is packaged for arm64 as well as
amd64, so Apple Silicon cross-compiles natively rather than through x86
emulation. `tools/build-in-docker.sh` runs native by default; set
`PLATFORM=linux/amd64` only if you need to match a specific build host.

There are three test levels below the tablet, and each catches what the one
above it cannot:

| | Runs on | Catches |
| --- | --- | --- |
| `check-artifact.sh` | nothing — static | symbol versions, ABI note, IFUNC, NEEDED |
| `qemu-smoke.sh` | the device's glibc 2.5, host kernel and network | loading, crypto, real TLS handshakes |
| `emulator-smoke.sh` | **the real 2.6.21 kernel and 220 MB userland** | whether the kernel serves the syscalls |

The static checker only tests for failures someone already met — two builds
passed it and could not have started on the device. See [BUILDLOG §7](BUILDLOG.md)
and [§10](BUILDLOG.md).

The environment is the real deliverable. Once it exists, every later package —
`stunnel`, `wget`, `curl`, `git`, NetSurf — is an afternoon rather than a
project.

## The documents

| | |
| --- | --- |
| [RESEARCH.md](RESEARCH.md) | What is installed, why nothing connects, where the bits still live. All verified, none recalled. |
| [DESIGN.md](DESIGN.md) | The cross-compilation environment, the OpenSSL package, the consumers, and what this deliberately does not do. |
| [DECISIONS.md](DECISIONS.md) | Every decision with its reason and what it beat. |
| [BUILDLOG.md](BUILDLOG.md) | What actually happened when we built it, including seven failures worth knowing about. |
| [OPEN.md](OPEN.md) | Unresolved questions, and which parts need the device in hand. |
| [NEXT.md](NEXT.md) | **Start here to continue.** Ordered actions, each with a definition of done. |
| [NAME.md](NAME.md) | Why "Handshake". |

## The flags that matter

If you take nothing else from this repository: cross-compiling for a 2008 device
from a 2026 host fails in several ways that are **silent on the host and fatal
on the device**. These are handled in `tools/env.sh` and `tools/build-openssl.sh`,
and checked by `tools/check-artifact.sh`.

| Flag | Without it |
| --- | --- |
| `-B$SYSROOT/usr/lib` | Links the host's `crt1.o`, whose ABI note demands Linux 3.2. Device loader refuses: `FATAL: kernel too old`. |
| `-nostdinc -isystem …` | Compiles against the host's glibc 2.39 headers, which sit ahead of the sysroot in the search path even with `--sysroot`. |
| `-U_FILE_OFFSET_BITS -U_TIME_BITS` | Ubuntu 24.04 enables 64-bit time_t/LFS by default on 32-bit targets. glibc 2.5 predates both. |
| `-fgnu89-inline` | glibc 2.5's `string2.h` uses GNU89 `extern __inline`; GCC's C99 rules emit it everywhere. |
| `-DBROKEN_CLANG_ATOMICS` | GCC calls into `libatomic` for 64-bit atomics on ARMv6. Every entry point there is an `IFUNC`, and glibc 2.5 predates IFUNC — so the loader resolves none of them, whether you ship the library or not. |

And the sixth lesson, which is not a flag: **run the binaries**. A static
checker encodes the failures you already know.

## Expectations

Fixing TLS does not make the modern web work. Nothing on this device renders a
2026 site, and the browser is explicitly out of scope. What this buys is package
repositories, `git`, mail, IRC, RSS, and any networked program you write
yourself — which is the point, if you intend to develop for the thing.
