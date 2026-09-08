# Quickstart

From nothing to a verified build.

## Requirements

**Docker, and that is not optional.** The build unpacks 2008 Debian packages
containing hardlinked files, which fails on macOS shared filesystems and is
awkward elsewhere. Everything runs in a container, and the build tree lives in
a Docker volume rather than on your disk. See [CAVEATS.md](CAVEATS.md).

Linux hosts need nothing else. macOS:

```sh
brew install colima docker
colima start --cpu 4 --memory 8 --disk 60
```

Do **not** install QEMU from Homebrew and expect it to work — the `n810`
machine was removed in QEMU 9.2, and `qemu-arm` user-mode does not run on
macOS at all. The container supplies the right versions.

## Build and test

```sh
tools/build-in-docker.sh
```

Fetches a Diablo sysroot from the community mirrors, cross-compiles OpenSSL
3.5.8 and stunnel 5.80, installs a current CA store, and runs both test suites
against the device's own glibc 2.5 under QEMU — including a real TLS 1.3
handshake.

Measured from a clean tree:

| Host | Time |
| --- | --- |
| Apple M4, native arm64 container | 2m 03s |
| x86-64, 4 cores, Debian 13 | ~15m |

The result lands in `dist/handshake-diablo-armel.tar.gz` — 5.3 MB, unpacks to
`/opt/handshake` on the device.

Runs native by default. `PLATFORM=linux/amd64` if you need to match a specific
build host.

## Run the real firmware

Optional, and needs no hardware. Downloads Nokia's final N810 release
(124 MB, checksummed) and boots it.

```sh
tools/mk-diablo-emulator.sh     # fetch and unpack the firmware
tools/emulator-smoke.sh         # run our binaries on the real 2.6.21 kernel
```

`emulator-smoke.sh` answers the one thing the static checks and user-mode QEMU
cannot: whether the real kernel serves every syscall the binaries make.

For the desktop:

```sh
tools/emulator-gui-build.sh     # eight fixes, all documented in the script
tools/emulator-gui.sh           # boots to the Hildon home screen, over VNC
```

Then tunnel to it — the VNC server binds loopback and has a password printed
at startup:

```sh
ssh -N -L 5901:127.0.0.1:5901 <host>
open vnc://127.0.0.1:5901
```

## On the device

```sh
tar xzf handshake-diablo-armel.tar.gz -C /opt
export LD_LIBRARY_PATH=/opt/handshake/lib
/opt/handshake/bin/openssl version -a
```

A stock device has no `openssl` CLI, no `wget`, no `curl` and no Python, so
plan how you will get files onto it. USB mass storage needs nothing installed.

## If something breaks

Read [CAVEATS.md](CAVEATS.md) first — most failures here are silent or report
the wrong cause. [docs/BUILDLOG.md](docs/BUILDLOG.md) has every failure in
full, with the logs.
