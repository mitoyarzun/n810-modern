# Handshake — design

> Tier 1 prep, 2026-09-08. Section 1 is built and verified. Sections 2 and 3 are
> designed but not yet executed. Section 4 is named, not designed.

## Contents

1. [The cross-compilation environment](#1-the-cross-compilation-environment)
2. [The OpenSSL package](#2-the-openssl-package)
3. [The consumers](#3-the-consumers)
4. [Distribution](#4-distribution)
5. [What this deliberately does not do](#5-what-this-deliberately-does-not-do)

---

## 1. The cross-compilation environment

The whole project rests on one idea: **compile against the device's libraries
with a modern compiler**. We do not rebuild glibc, we do not touch the device's
toolchain, and we never run Scratchbox.

```
  Ubuntu 24.04 host
    arm-linux-gnueabi-gcc 13.3          <- modern compiler, C99/C11/C17
      --sysroot=sysroot-diablo          <- device's glibc 2.5 headers + libs
      -B sysroot-diablo/usr/lib         <- device's crt files  (load-bearing)
      -march=armv6 -mtune=arm1136jf-s   <- OMAP2420
      -mfloat-abi=softfp -mfpu=vfp      <- VFPv2, base AAPCS
    -> ELF32 ARM EABI, ld-linux.so.3, GLIBC_2.4, ABI note 2.6.8
```

The sysroot is six `.deb` files unpacked into a directory: `libc6`, `libc6-dev`,
`linux-kernel-headers`, `libgcc1`, `zlib1g`, `zlib1g-dev`. 27 MB. Versions and
MD5s are pinned in `tools/diablo-sysroot.manifest` so this reproduces even if a
mirror changes or disappears.

### The `-B` flag is the whole ballgame

Ubuntu's cross-GCC is configured with its own startfile prefix, and `--sysroot`
does **not** override it. Without `-B`, the link picks up the *host* toolchain's
`crt1.o`, which carries a `.note.ABI-tag` of `Linux 3.2.0`. The device's loader
reads that note and refuses the binary outright — `FATAL: kernel too old` — on a
device running 2.6.21. The sysroot's own `crt1.o` says `2.6.8`.

This fails silently at build time and loudly on the device, which is the worst
possible ordering. Every artefact must be checked:

```sh
arm-linux-gnueabi-readelf -n <binary> | grep -A2 NT_GNU_ABI   # must read 2.6.8
```

`tools/check-artifact.sh` does this and three other checks; run it on everything
before it goes near the device.

### Why softfp and not soft

The ARM1136JF-S has a VFPv2 unit, and Diablo already uses it — the device's own
`libm-2.5.so` contains about 6,800 VFP instructions. `softfp` emits VFP
instructions while keeping the base AAPCS calling convention (floats passed in
core registers), so it stays link-compatible with every stock Diablo library.
`hard` would change the calling convention and must never be used here.

For OpenSSL specifically this is nearly irrelevant — crypto is integer work —
but the environment is meant to outlive OpenSSL, and the next consumers
(`curl`, `git`, NetSurf) do care.

## 2. The OpenSSL package

**Version: OpenSSL 3.5.x LTS** (3.5.8 at time of writing), supported upstream to
2030. Deliberately not 1.0.2, which is what the N900 community shipped and which
went EOL in 2019. Deliberately not 3.0, whose LTS window closes this month.

### Configuration

```
./Configure linux-armv4 \
    --prefix=/opt/handshake --openssldir=/opt/handshake/ssl \
    --with-rand-seed=devrandom \
    shared threads no-tests no-docs no-afalgeng
```

Two of those are not optional on this target:

- **`--with-rand-seed=devrandom`** — the default seeding path wants `getrandom()`,
  which is kernel 3.17+. On 2.6.21 it must read `/dev/urandom` instead. Get this
  wrong and OpenSSL builds cleanly and then fails at runtime, obscurely.
- **`no-afalgeng`** — the AF_ALG kernel crypto socket engine needs a kernel far
  newer than this one.

ARM assembly stays **on**. The build picks up `AES_ASM`, `BSAES_ASM`,
`ECP_NISTZ256_ASM`, `SHA1/256/512_ASM` and `KECCAK1600_ASM`, all of which have
ARMv4-baseline paths that run on ARM1136. On a 400 MHz core this is not a
micro-optimisation.

### Coexistence, not replacement

The stock library is `libssl.so.0.9.8`; ours is `libssl.so.3`. Different sonames,
so both can be installed and nothing that currently works stops working. This is
the single most important safety property of the project — **the device must
remain bootable and usable at every step**, and it is free, so take it.

Everything installs under **`/opt/handshake`**, never `/usr`. Two reasons: it
keeps the stock system pristine, and it keeps several MB off a 256 MB rootfs.
Symlink or mount `/opt/handshake` from the 2 GB internal flash.

### Cipher preference on this hardware

ARM1136 has no NEON and no ARMv8 crypto extensions, so AES is pure table-driven
software. **Prefer ChaCha20-Poly1305**, which is designed to be fast on exactly
this kind of 32-bit integer core, and is constant-time without special
instructions:

```
TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256   # TLS 1.3
ECDHE+CHACHA20:ECDHE+AESGCM                            # TLS 1.2
```

Prefer P-256 over P-384, and RSA verification over RSA signing wherever the
choice exists. Expected handshake cost is in the low hundreds of milliseconds —
acceptable on a device whose radio is 802.11g. Real numbers go in BUILDLOG.md
once the device is in hand.

## 3. The consumers

A library nothing links against changes nothing. Ordered by value per unit of
work:

| Package | Why it is on the list | Notes |
| --- | --- | --- |
| `openssl` CLI | The test instrument. `s_client` tells you whether tier 1 worked at all. | Ships with the library |
| `ca-certificates` | Without a current trust store the new library still fails, just later. | Data only, no compile |
| **`stunnel`** | Turns the LAN-side proxy into an on-device one. Retroactively gives modern TLS to *every* stock app that can be pointed at localhost. | The highest-leverage consumer |
| `wget` / `curl` | The things you actually reach for. | curl also needs a rebuild of `libcurl3` consumers, or install parallel |
| `git` | Makes the device a development target rather than only a host. | Wants curl |
| `python2.5` `_ssl` | Rebuild just the extension module against the new lib; leaves the interpreter alone. | Smallest useful win for scripting |

`stunnel` first. It is small, has few dependencies, and once it exists the
Tier 0 workaround stops needing a second machine.

## 4. Distribution

Not designed yet. The shape is a static apt repository served over **plain
HTTP** — you cannot fetch the thing that enables HTTPS over HTTPS — with the
packages signed rather than the transport secured. GitHub Pages would host it
for free. Diablo's `Hildon Application Manager` also wants a `.install` file to
add a catalogue in one tap.

## 5. What this deliberately does not do

- **It does not touch the browser.** MicroB is Gecko 1.9 on NSS 3.x; modern NSS
  needs C++11 and a gyp/ninja build, and old Gecko calls into APIs NSS has since
  removed. The N900 community had more people and never cracked it. If a
  browsing story is wanted, the answer is a NetSurf port, which falls out of
  section 3 nearly free — and that is a separate project.
- **It does not replace anything in `/usr`.**
- **It does not make the modern web work.** Even with a perfect TLS 1.3 stack,
  nothing on this device renders a 2026 site. What tier 1 buys is package repos,
  `git`, mail, IRC, RSS, and — the actual point — any networked app you write
  yourself.
