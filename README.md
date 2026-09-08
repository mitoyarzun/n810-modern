# n810-modern

Modern software on the Nokia N800 and N810, running Maemo 4.1.2 (Diablo).

A cross-compilation environment targeting the device's glibc 2.5 from a current
host, and a full-system emulator running the real firmware so you can work
without hardware.

**Why:** the device still does DNS, sockets and bytes, but cannot complete a
TLS handshake with anything built after roughly 2013. OpenSSL 0.9.8e tops out
at TLS 1.0 with no ECDHE, no AES-GCM, no SNI; modern servers require TLS
1.2/1.3 with ECDHE and an AEAD cipher. No overlap, so the connection dies at
ClientHello. No certificate work fixes that.

This does not make the modern web work — nothing here renders a 2026 site. It
buys package repositories, `git`, mail, IRC, RSS, and anything networked you
write yourself.

## Quickstart

**Docker is required, not a convenience.** The build unpacks 2008 Debian
packages containing hardlinked files, which fails on macOS shared filesystems;
the build tree lives in a Docker volume. See [CAVEATS.md](CAVEATS.md).

Linux needs nothing else. macOS:

```sh
brew install colima docker
colima start --cpu 4 --memory 8 --disk 60
```

Do **not** use Homebrew's QEMU — the `n810` machine was removed in QEMU 9.2,
and `qemu-arm` user-mode does not run on macOS at all. The container has the
right versions.

```sh
tools/build-in-docker.sh
```

Fetches a Diablo sysroot from the community mirrors, cross-compiles OpenSSL
3.5.8 and stunnel 5.80, installs a current CA store, and runs both test suites
against the device's own glibc 2.5 under QEMU — including a real TLS 1.3
handshake. Result: `dist/handshake-diablo-armel.tar.gz`, 5.3 MB, unpacks to
`/opt/handshake` on the device.

| Host | Clean build |
| --- | --- |
| Apple M4, native arm64 container | 1m 30s |
| x86-64, 4 cores, Debian 13 | ~15m |

Runs native by default; `PLATFORM=linux/amd64` to match a specific build host.

### The real firmware, no hardware needed

```sh
tools/mk-diablo-emulator.sh     # fetch and unpack Nokia's final N810 release
tools/emulator-smoke.sh         # run our binaries on the real 2.6.21 kernel
tools/emulator-gui-build.sh     # and, if you want it, the desktop
tools/emulator-gui.sh           # over VNC, loopback, password printed at start
```

`emulator-smoke.sh` answers what static checks and user-mode QEMU cannot:
whether the real kernel serves every syscall the binaries make. It does.

### On the device

```sh
tar xzf handshake-diablo-armel.tar.gz -C /opt
export LD_LIBRARY_PATH=/opt/handshake/lib
/opt/handshake/bin/openssl version -a
```

A stock device has no `openssl` CLI, no `wget`, no `curl` and no Python — only
the `libssl0.9.8` library. Plan how you will get files onto it; USB mass
storage needs nothing installed.

## Status

Working: OpenSSL 3.5.8 and stunnel 5.80 for armv6, alongside the stock 0.9.8e
rather than over it. Both providers load, RSA and EC keygen work, TLS 1.3 to
`example.org` verifies, and stunnel turns a plain-HTTP client into a verified
TLS 1.3 connection — which is how stock applications get modern TLS without
being rebuilt. All verified on the real firmware and kernel under emulation.

**Not yet run on physical hardware.** Still hardware-only: real timings, WiFi,
the RTC clock, flash wear.

Next: `wget`, then `curl` and `git`, then Python's `_ssl`. Then a static apt
repository over plain HTTP with signed packages — you cannot fetch the thing
that enables HTTPS over HTTPS.

## Tools

```
build-in-docker.sh      everything below, in a container
setup-host.sh           cross-compiler and prerequisites
mk-sysroot.sh           27 MB Diablo sysroot, checksummed
env.sh                  cross-env: modern GCC -> glibc 2.5
build-openssl.sh        OpenSSL 3.5 LTS for armv6
mk-truststore.sh        current CA store, checksum-verified
build-stunnel.sh        stunnel 5.80 against the above
check-artifact.sh       static checks: will this run on the device
qemu-smoke.sh           run it on the device's own glibc 2.5
qemu-stunnel-test.sh    plain HTTP in, verified TLS 1.3 out
mk-diablo-emulator.sh   fetch and unpack the real firmware
emulator-smoke.sh       run it on the real 2.6.21 kernel
emulator-gui-build.sh   build an image that reaches the desktop
emulator-gui.sh         boot that, over VNC
fb-autoupdate.c         forces the panel to refresh; built for the guest
device-smoke-test.sh    run this on the tablet itself
```

Three test levels, each catching what the one above cannot:

| | Runs on | Catches |
| --- | --- | --- |
| `check-artifact.sh` | nothing — static | symbol versions, ABI note, IFUNC, NEEDED |
| `qemu-smoke.sh` | device's glibc 2.5, host kernel and network | loading, crypto, real TLS handshakes |
| `emulator-smoke.sh` | real 2.6.21 kernel and userland | whether the kernel serves the syscalls |

## The flags that matter

Cross-compiling for a 2008 device from a 2026 host fails in ways that are
silent on the host and fatal on the device. Handled in `tools/env.sh` and
`tools/build-openssl.sh`.

| Flag | Without it |
| --- | --- |
| `-B$SYSROOT/usr/lib` | Links the host's `crt1.o`, whose ABI note demands Linux 3.2. Device loader refuses: `FATAL: kernel too old`. |
| `-nostdinc -isystem …` | Compiles against the host's glibc headers, which sit ahead of the sysroot even with `--sysroot`. |
| `-U_FILE_OFFSET_BITS -U_TIME_BITS` | Ubuntu enables 64-bit time_t and LFS by default on 32-bit targets. glibc 2.5 predates both. |
| `-fgnu89-inline` | glibc 2.5's `string2.h` uses GNU89 `extern __inline`; GCC's C99 rules emit it everywhere. |
| `-DBROKEN_CLANG_ATOMICS` | GCC calls into `libatomic`, whose entry points are all `IFUNC`. glibc 2.5 predates IFUNC. |

Four of the five exist because the **host** is modern, not because the target
is old.

## Also

- [CAVEATS.md](CAVEATS.md) — failures that do not announce themselves. Read
  this before debugging anything.
- [DECISIONS.md](DECISIONS.md) — what the device ships, and why this is built
  the way it is.
- [BUILDLOG.md](BUILDLOG.md) — the long form: every failure, with the logs.

Prior work: [Maemo In Qemu](https://www.slideshare.net/hrw/maemo-in-qemu-presentation),
[ssvb/linux-n810](https://github.com/ssvb/linux-n810),
[Diablo Community Project](https://wiki.maemo.org/Diablo_Community_Project).

MIT licensed. Nokia's firmware is downloaded from community mirrors at build
time, not redistributed here.
