# n810-modern

Modern software on the Nokia N800 and N810, running Maemo 4.1.2 (Diablo).

Two things: a cross-compilation environment that targets the device's glibc
2.5 from a current host, and a full-system emulator that runs the real
firmware so you can work without hardware.

## Status

Working and tested:

- **OpenSSL 3.5.8** and **stunnel 5.80** for armv6, 5.3 MB, installed alongside
  the stock 0.9.8e rather than over it
- **A build that reproduces in one command** on Linux or macOS
- **The real firmware under QEMU** — Nokia's final N810 release, its 2.6.21
  kernel and 220 MB userland, booting to a shell or to the Hildon desktop

Verified under emulation on the device's own glibc and kernel: both providers
load, RSA and EC keygen work, and a TLS 1.3 handshake to `example.org`
completes with the chain verified. stunnel turns a plain-HTTP client into a
verified TLS 1.3 connection, which is how stock applications get modern TLS
without being rebuilt.

Not yet run on physical hardware.

## Why

The device can still reach the network — DNS, sockets, bytes. What it cannot do
is complete a TLS handshake with anything built after roughly 2013. OpenSSL
0.9.8e tops out at TLS 1.0 with no ECDHE, no AES-GCM and no SNI; modern servers
require TLS 1.2/1.3 with ECDHE and an AEAD cipher. There is no overlap, so the
connection dies at ClientHello. No amount of certificate work fixes it.

Fixing that does not make the modern web work — nothing here renders a 2026
site, and the browser is out of scope. What it buys is package repositories,
`git`, mail, IRC, RSS, and anything networked you write yourself.

## Start here

[QUICKSTART.md](QUICKSTART.md) — from nothing to a verified build.

[CAVEATS.md](CAVEATS.md) — the failures that do not announce themselves. Worth
reading before you debug anything.

## Tools

```
tools/build-in-docker.sh      everything below, in a container
tools/setup-host.sh           cross-compiler and prerequisites
tools/mk-sysroot.sh           27 MB Diablo sysroot, checksummed
tools/env.sh                  cross-env: modern GCC -> glibc 2.5
tools/build-openssl.sh        OpenSSL 3.5 LTS for armv6
tools/mk-truststore.sh        current CA store, checksum-verified
tools/build-stunnel.sh        stunnel 5.80 against the above
tools/check-artifact.sh       static checks: will this run on the device
tools/qemu-smoke.sh           run it on the device's own glibc 2.5
tools/qemu-stunnel-test.sh    plain HTTP in, verified TLS 1.3 out
tools/mk-diablo-emulator.sh   fetch and unpack the real firmware
tools/emulator-smoke.sh       run it on the real 2.6.21 kernel
tools/emulator-gui-build.sh   build an image that reaches the desktop
tools/emulator-gui.sh         boot that, over VNC
tools/device-smoke-test.sh    run this on the tablet itself
```

Three test levels, each catching what the one above cannot:

| | Runs on | Catches |
| --- | --- | --- |
| `check-artifact.sh` | nothing — static | symbol versions, ABI note, IFUNC, NEEDED |
| `qemu-smoke.sh` | the device's glibc 2.5, host kernel and network | loading, crypto, real TLS handshakes |
| `emulator-smoke.sh` | the real 2.6.21 kernel and userland | whether the kernel serves the syscalls |

## The flags that matter

Cross-compiling for a 2008 device from a 2026 host fails in ways that are
silent on the host and fatal on the device. All of these are handled in
`tools/env.sh` and `tools/build-openssl.sh`.

| Flag | Without it |
| --- | --- |
| `-B$SYSROOT/usr/lib` | Links the host's `crt1.o`, whose ABI note demands Linux 3.2. The device's loader refuses: `FATAL: kernel too old`. |
| `-nostdinc -isystem …` | Compiles against the host's glibc headers, which sit ahead of the sysroot even with `--sysroot`. |
| `-U_FILE_OFFSET_BITS -U_TIME_BITS` | Ubuntu enables 64-bit time_t and LFS by default on 32-bit targets. glibc 2.5 predates both. |
| `-fgnu89-inline` | glibc 2.5's `string2.h` uses GNU89 `extern __inline`; GCC's C99 rules emit it in every translation unit. |
| `-DBROKEN_CLANG_ATOMICS` | GCC calls into `libatomic`, whose entry points are all `IFUNC`. glibc 2.5 predates IFUNC and resolves none of them. |

Four of the five exist because the **host** is modern, not because the target
is old.

## Documentation

| | |
| --- | --- |
| [docs/RESEARCH.md](docs/RESEARCH.md) | What the device has, and why nothing connects. |
| [docs/DESIGN.md](docs/DESIGN.md) | The cross-compilation environment and the packages. |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Every decision, its reason, and what it beat. |
| [docs/BUILDLOG.md](docs/BUILDLOG.md) | What actually happened, failures kept in. |
| [docs/OPEN.md](docs/OPEN.md) | Unresolved questions. |
| [docs/NEXT.md](docs/NEXT.md) | Ordered next actions. |

## See also

Prior work this builds on:

- [Maemo In Qemu](https://www.slideshare.net/hrw/maemo-in-qemu-presentation) —
  emulating the N800/N810, from the era when QEMU's `n810` machine was new
- [ssvb/linux-n810](https://github.com/ssvb/linux-n810) — kernel tree for the
  device
- [Diablo Community Project](https://wiki.maemo.org/Diablo_Community_Project) —
  community updates for Diablo; repositories now offline

## Licence

MIT. See [LICENSE](LICENSE).

Nokia's firmware is downloaded from community mirrors at build time and is not
redistributed here.
