# Decisions

Why this is built the way it is.

The full record of what went wrong getting here is in [BUILDLOG.md](BUILDLOG.md).
The traps worth knowing before you debug anything are in [CAVEATS.md](CAVEATS.md).

## What the device ships

From `dists/diablo/sdk/free/binary-armel/Packages` (796 packages) on the
repository.maemo.org mirror:

| Package | Version | Released |
| --- | --- | --- |
| `openssl`, `libssl0.9.8`, `libssl-dev` | **0.9.8e-9maemo3** | 0.9.8e = Feb 2007 |
| `libc6`, `libc6-dev` | **2.5.0-1osso10** | glibc 2.5 = Sep 2006 |
| `linux-kernel-headers` | **2.6.16.osso11-1** | 2.6.16 = Mar 2006 |
| `libnss3` | 1.0.4-60.19 (Nokia versioning) | — |
| `libcurl3` | 7.15.5-1osso4 | — |
| `zlib1g` | 1.2.3-9.osso8 | — |
| `gcc`, `gcc-3.4` | 4:3.4.4-7osso2 / 3.4.4cs2005q3.2 | — |

From `extras` for diablo (74,981 lines of index):

| Package | Version |
| --- | --- |
| `libgnutls13` / `libgnutls26` | 2.0.4-3maemo3 / **2.4.2-5** |
| `libgcrypt11` | 1.4.1-2 |
| `python2.5` | 2.5.2-1osso4 |
| `python2.5-pyopenssl` | 0.6-2osso1 |

The kernel headers are *older* than the running kernel (2.6.21). That is normal
for the era and matters only in that nothing in the SDK knows about any syscall
added after 2006.

## Hardware that shapes the build

Confirmed by reading the device's own binaries out of the sysroot, and the
mainline device tree:

- **`ld-linux.so.3`** is the loader → the device is `armel`, base AAPCS
  (soft-float *calling convention*). Exactly what `arm-linux-gnueabi` targets.
  Not `armhf`, which would be `ld-linux-armhf.so.3`.
- Diablo's `libm-2.5.so` contains **~6,800 VFP instructions**, so the ARM1136JF-S
  VFPv2 unit is present, enabled, and already used by the stock system.
  `-mfloat-abi=softfp` is therefore safe and link-compatible.
- ELF header reads `Version4 EABI`; the ARM attributes section is in the old
  pre-2008 format that modern `readelf -A` cannot parse. Harmless.
- 128 MB RAM, confirmed in mainline's `omap2420-n8x0-common.dtsi`
  (`reg = <0x80000000 0x8000000>`).
- No usable crypto acceleration: ARM1136 has no NEON and no ARMv8 crypto
  extensions. This drives the cipher preference in [DECISIONS.md](DECISIONS.md).

Tier 1 prep, session of 2026-09-08. Every decision with the reason and what it
beat. Nothing here has been tested on hardware yet — see [README.md](README.md).

## Scope

| # | Decision | Reason | Rejected |
| --- | --- | --- | --- |
| 1 | **Fix TLS, nothing else.** No distro port, no kernel work, no UI | It is the one dependency under every other useful thing the device could do. Everything else on the N810 is optional; this is not | Bundling it into a wider "modernise the N810" effort |
| 2 | **Coexist, never replace.** New library installs alongside `libssl0.9.8` | Different sonames make this free. The device must stay bootable and usable at every single step — there is no recovery story worth having on 2008 hardware | Upgrading the system OpenSSL in place |
| 3 | **Install under `/opt/n810-modern`, not `/usr`** | Keeps the stock system pristine, and keeps several MB off a 256 MB rootfs | `/usr/local`; overwriting `/usr` |
| 4 | **The browser is explicitly out of scope** | MicroB is Gecko 1.9 on NSS; modern NSS needs C++11 and gyp/ninja, and old Gecko calls APIs NSS has removed. The N900 community had more people and never managed it | Attempting an NSS drop-in; patching MicroB |
| 5 | **NetSurf, if a browser is ever wanted** | Small, maintained, C, already uses libcurl + OpenSSL — it falls out of the consumer work almost free | Porting a modern Gecko or WebKit |

## Toolchain

| # | Decision | Reason | Rejected |
| --- | --- | --- | --- |
| 6 | **Modern cross-GCC against a device sysroot.** Not Scratchbox | Scratchbox 1 needs a Debian 6 VM and gives us GCC 4.2, which cannot build OpenSSL 3.x. The sysroot approach decouples us from 2007 permanently and is reusable for every later package | Scratchbox 1 in a Debian 6 container; building a full crosstool-NG toolchain |
| 7 | **Ubuntu's stock `gcc-arm-linux-gnueabi` 13.3** | It is packaged, current, and targets `arm-linux-gnueabi` exactly. Confirmed by the device's loader being `ld-linux.so.3` | crosstool-NG (hours of build for the same result) |
| 8 | **`-march=armv6 -mtune=arm1136jf-s`** | The OMAP2420's actual core. The toolchain defaults to armv5t, which works but leaves instructions unused | Accepting the armv5t default |
| 9 | **`-mfloat-abi=softfp -mfpu=vfp`** | The ARM1136JF-S has VFPv2 and Diablo already uses it — the device's own `libm` holds ~6,800 VFP instructions. softfp keeps the base AAPCS convention, so it stays link-compatible with every stock library | `soft` (leaves the FPU idle); `hard` (changes the calling convention — would not link) |
| 10 | **`-U_FILE_OFFSET_BITS -U_TIME_BITS`** | Ubuntu 24.04's 32-bit cross-compilers enable the 64-bit time_t/LFS transition by default. glibc 2.5 predates both, and `_FILE_OFFSET_BITS=64` triggers a header bug that breaks the assembly | Leaving the host defaults; patching glibc 2.5's headers |
| 11 | **`-nostdinc` with explicit `-isystem`** | `--sysroot` does **not** stop Ubuntu's cross-GCC searching its own glibc 2.39 headers first. Without this the build silently compiles against the wrong libc | Trusting `--sysroot` |
| 12 | **`-B$SYSROOT/usr/lib`** | Same class of problem for startfiles: without it the link takes the host's `crt1.o`, whose ABI note demands Linux 3.2 and which the device's loader rejects | Trusting `--sysroot` |
| 13 | **Pin package versions and MD5s in a manifest** | Both mirrors are volunteer-run and one is already rate-limiting. The build must not depend on either staying up, or on an index changing under us | Resolving from a live index each time |
| 14 | **Verify every artefact mechanically** (`tools/check-artifact.sh`) | Every failure mode here is silent on the host and fatal on the device. A checklist a human runs is a checklist a human forgets | Eyeballing `file` output |

## OpenSSL

| # | Decision | Reason | Rejected |
| --- | --- | --- | --- |
| 15 | **OpenSSL 3.5 LTS**, supported to 2030 | If we are doing this once, do it against something that will still be receiving fixes | 1.0.2 (what the N900 shipped; EOL 2019); 3.0 (LTS ends this month); LibreSSL; mbedTLS (no OpenSSL ABI, so no drop-in for consumers) |
| 16 | **`--with-rand-seed=devrandom`** | Default seeding wants `getrandom()`, kernel 3.17+. The device runs 2.6.21. Wrong here means a clean build that fails obscurely at runtime | The default |
| 17 | **`no-afalgeng`** | The AF_ALG engine needs a far newer kernel | Leaving it on |
| 18 | **Keep ARM assembly on** | AES, bit-sliced AES, P-256, SHA and Keccak all have ARMv4-baseline paths that run here. On a 400 MHz core this is not a micro-optimisation | `no-asm` for an easier build |
| 19 | **Prefer ChaCha20-Poly1305 over AES-GCM** | No NEON, no ARMv8 crypto extensions, so AES is table-driven software. ChaCha20 is designed for exactly this kind of 32-bit integer core, and is constant-time without special instructions | Standard AES-first ordering |
| ~~20~~ | ~~**Bundle `libatomic.so.1`** rather than static-linking it~~ **Reversed — see 23** | ARMv6 has no 64-bit atomic instructions so GCC calls into libatomic, which arrived with GCC 4.7 and does not exist anywhere in Diablo. The toolchain's copy needs only `GLIBC_2.4`, so shipping 40 KB looked safer than betting the static library is PIC | Static-linking `libatomic.a`; `-march=armv6k` to get native 64-bit atomics (the ARM1136 in the OMAP2420 is plain ARMv6) |
| 21 | **`stunnel` is the first consumer, before `wget`** | It retroactively gives modern TLS to every stock app that can be pointed at localhost, so it is worth more than any single rebuilt client | `wget` first (more obvious, less leverage) |
| 23 | **`-DBROKEN_CLANG_ATOMICS`: no libatomic at all.** Reverses 20 | Every 64-bit entry point in GCC's libatomic is an `IFUNC`, and glibc 2.5 predates IFUNC by three years, so its loader resolves none of them — shipped or not. `libatomic.a` is IFUNC-based too, so 20's rejected alternative fails identically. Only `crypto/threads_pthread.c` uses the builtins, and OpenSSL's own switch replaces them with mutexes. On one uncontended 400 MHz core that costs nothing measurable | Bundling libatomic (decision 20, wrong); static libatomic (same failure); writing our own IFUNC-free libatomic shim (works, but hand-rolled atomics to avoid mutexes we do not need) |
| 24 | **Test every build under QEMU against the device's own glibc 2.5** (`tools/qemu-smoke.sh`) | Decision 14 said verify mechanically, and a static checker passed two builds that could not have started. `qemu-arm -L sysroot-diablo` runs the real loader on the real binaries, so the whole class of "links fine, will not load" fails on the build host instead of on the tablet | Trusting `check-artifact.sh` alone; waiting for hardware to find out (which is what let 20 stand) |
| 25 | **Ship Mozilla's full CA store** (`tools/mk-truststore.sh`), not a trimmed one | ~150 KB of PEM against 2 GB of flash is not a cost worth managing, and a trimmed store is a standing maintenance job that fails closed and confusingly — a site stops working and nothing says why. Fetched over HTTPS from the build host and verified against the published sha256, because the transport is not the trust | A hand-trimmed store (README (status) #6); reusing the 2008 store (every root expired or distrusted) |
| 26 | **Test the checker in both directions before trusting it** | The IFUNC check passed the library it was written to reject, because `pipefail` plus `grep -q` reports SIGPIPE. A check that has only ever returned "ok" is not evidence of anything. Every check now has a known-bad input that must fail it | Adding checks and assuming they work (which hid a vacuous `time_t` check for the whole project) |
| 27 | **Run the real firmware under full-system QEMU** (`tools/mk-diablo-emulator.sh`, `tools/emulator-smoke.sh`) | Decision 24 tests on the device's glibc but translates syscalls to the host kernel, so it cannot say whether 2.6.21 serves them. Nokia's final N810 release still exists with a matching MD5; unpacked, it gives the real kernel and the real 220 MB userland. This answered the largest question README had marked hardware-only, and closed README (status) #1 from the firmware rather than the package index | Waiting for the tablet (which is blocked on a battery); trusting the package index for versions |
| 28 | **Do not treat emulated timings as measurements** | `openssl speed` runs under emulation and came out matching the ChaCha20-over-AES prediction, which is tempting. QEMU's TCG retranslates ARM to the host ISA and models neither pipeline nor cache, so it distorts exactly the instruction-mix costs that a cipher comparison depends on. Decision 19 stays a prediction | Recording the emulated ratio as confirmation of 19 |

## Distribution

| # | Decision | Reason | Rejected |
| --- | --- | --- | --- |
| 22 | **Serve the repo over plain HTTP, sign the packages** | You cannot fetch the thing that enables HTTPS over HTTPS. Signing gives integrity without needing the transport | An HTTPS-only repo |
