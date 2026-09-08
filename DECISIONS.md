# Decisions

Tier 1 prep, session of 2026-09-08. Every decision with the reason and what it
beat. Nothing here has been tested on hardware yet — see [OPEN.md](OPEN.md).

## Scope

| # | Decision | Reason | Rejected |
| --- | --- | --- | --- |
| 1 | **Fix TLS, nothing else.** No distro port, no kernel work, no UI | It is the one dependency under every other useful thing the device could do. Everything else on the N810 is optional; this is not | Bundling it into a wider "modernise the N810" effort |
| 2 | **Coexist, never replace.** New library installs alongside `libssl0.9.8` | Different sonames make this free. The device must stay bootable and usable at every single step — there is no recovery story worth having on 2008 hardware | Upgrading the system OpenSSL in place |
| 3 | **Install under `/opt/handshake`, not `/usr`** | Keeps the stock system pristine, and keeps several MB off a 256 MB rootfs | `/usr/local`; overwriting `/usr` |
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
| 20 | **`stunnel` is the first consumer, before `wget`** | It retroactively gives modern TLS to every stock app that can be pointed at localhost, so it is worth more than any single rebuilt client | `wget` first (more obvious, less leverage) |

## Distribution

| # | Decision | Reason | Rejected |
| --- | --- | --- | --- |
| 21 | **Serve the repo over plain HTTP, sign the packages** | You cannot fetch the thing that enables HTTPS over HTTPS. Signing gives integrity without needing the transport | An HTTPS-only repo |
