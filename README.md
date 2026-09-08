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

**Status: Tier 1 prep complete. The cross-compilation environment works and
OpenSSL 3.5.8 builds clean for the device — 5.3 MB of verified, device-safe
armv6 binaries. Nothing has yet run on hardware.**

## What works today

```sh
tools/setup-host.sh          # cross-compiler + prerequisites (Debian/Ubuntu)
tools/mk-sysroot.sh          # 27 MB Diablo sysroot, checksummed, from mirrors
. tools/env.sh               # cross-env: modern GCC -> glibc 2.5
tools/build-openssl.sh       # OpenSSL 3.5 LTS for armv6
tools/check-artifact.sh FILE # prove a binary will actually run on the device
tools/device-smoke-test.sh   # run this ON the tablet
```

End to end that is about fifteen minutes on four cores, and it produces 5.3 MB
of verified armv6 runtime: `libcrypto.so.3`, `libssl.so.3`, the `openssl` CLI,
the legacy provider, and a bundled `libatomic.so.1`.

The environment is the real deliverable. Once it exists, every later package —
`stunnel`, `wget`, `curl`, `git`, NetSurf — is an afternoon rather than a
project.

## The documents

| | |
| --- | --- |
| [RESEARCH.md](RESEARCH.md) | What is installed, why nothing connects, where the bits still live. All verified, none recalled. |
| [DESIGN.md](DESIGN.md) | The cross-compilation environment, the OpenSSL package, the consumers, and what this deliberately does not do. |
| [DECISIONS.md](DECISIONS.md) | Every decision with its reason and what it beat. |
| [BUILDLOG.md](BUILDLOG.md) | What actually happened when we built it, including three failures worth knowing about. |
| [OPEN.md](OPEN.md) | Unresolved, and which parts need the device in hand. |
| [NAME.md](NAME.md) | Why "Handshake". |

## The flags that matter

If you take nothing else from this repository: cross-compiling for a 2008 device
from a 2024 host fails in three ways that are **silent on the host and fatal on
the device**. All three are handled in `tools/env.sh`, and all three are checked
by `tools/check-artifact.sh`.

| Flag | Without it |
| --- | --- |
| `-B$SYSROOT/usr/lib` | Links the host's `crt1.o`, whose ABI note demands Linux 3.2. Device loader refuses: `FATAL: kernel too old`. |
| `-nostdinc -isystem …` | Compiles against the host's glibc 2.39 headers, which sit ahead of the sysroot in the search path even with `--sysroot`. |
| `-U_FILE_OFFSET_BITS -U_TIME_BITS` | Ubuntu 24.04 enables 64-bit time_t/LFS by default on 32-bit targets. glibc 2.5 predates both. |
| `-fgnu89-inline` | glibc 2.5's `string2.h` uses GNU89 `extern __inline`; GCC's C99 rules emit it everywhere. |

## Expectations

Fixing TLS does not make the modern web work. Nothing on this device renders a
2026 site, and the browser is explicitly out of scope. What this buys is package
repositories, `git`, mail, IRC, RSS, and any networked program you write
yourself — which is the point, if you intend to develop for the thing.
