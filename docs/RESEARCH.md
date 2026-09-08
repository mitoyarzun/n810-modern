# Research

What is actually installed, what is actually reachable, and what other people
already did. Everything in this file was verified on 2026-09-08, not recalled.
Where a fact still needs the device to confirm it, it is in [OPEN.md](OPEN.md)
instead.

## 1. What Diablo actually ships

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

## 2. Why nothing connects

Three defects, stacked. They must be fixed in this order, because each one hides
the next.

**a. Protocol and cipher — the blocker.** OpenSSL 0.9.8e tops out at **TLS 1.0**.
TLS 1.1/1.2 arrived in OpenSSL 1.0.1; ECDHE in 1.0.0; AES-GCM in 1.0.1. The
alternative stack is no better: TLS 1.2 did not land in GnuTLS until the 2.12
branch, and Diablo has 2.0.4/2.4.2. A 2026 server offers TLS 1.2/1.3 with ECDHE
and an AEAD cipher. The device offers TLS 1.0 with CBC and RSA key exchange.
There is **no overlap at all** — the connection dies at ClientHello. This is not
a certificate problem and no certificate work will fix it.

**b. No SNI.** SNI shipped in OpenSSL **0.9.8f**. Diablo has **0.9.8e** — one
release earlier. So even against a server that would still speak TLS 1.0, any
virtual-hosted site returns the wrong certificate. (This one was a guess in
conversation and turned out to be exactly true; it is worth stating precisely
because it means SNI cannot be enabled by a rebuild flag — the code is not there.)

**c. Trust store.** A 2008 CA bundle has no ISRG Root X1, so nothing rooted at
Let's Encrypt validates, and DST Root CA X3 expired in September 2021.

## 3. Prior art: the N900 did this

Fremantle/N900 got a community OpenSSL rebuild — `libssl1.0.2` at
`1.0.2o-1+maemo` — distributed through CSSU. The reports are consistent:

- it works for command-line consumers (`wget` over HTTPS to real sites),
- it does **not** fix the MicroB browser, and nobody ever managed to,
- it needed a matching `ca-certificates` refresh to be useful.

That is a working template and a calibrated expectation. Nobody did the
equivalent for Diablo/N810 — this project is that gap. Note we should not copy
their version choice: OpenSSL 1.0.2 went EOL in December 2019.

## 4. Where the bits still live

`repository.maemo.org` has been down since roughly 2021 (503). Two community
mirrors carry it:

| Mirror | Carries | Notes |
| --- | --- | --- |
| `maemo.wunderwungiel.pl/repository.maemo.org` | full `pool/`, all dists | No hotlink protection. **Primary.** |
| `maemo.viniciuspaes.com` | `dists/` indexes, `extras`, flasher, firmware | Referer-checked; rate-limits bursts with 403. |

Two operational notes, both learned the hard way:

- The viniciuspaes mirror returns **403** unless the request carries a `Referer`
  pointing back into the mirror. It is not down when this happens.
- It also rate-limits. After roughly two dozen requests it 403s everything for a
  while, `Referer` or not. Its front page asks people not to bulk-mirror it, and
  that request is worth honouring — hence pinning checksums in
  [`tools/diablo-sysroot.manifest`](tools/diablo-sysroot.manifest) and pulling
  the actual `.deb` payloads from wunderwungiel.

`wiki.maemo.org` and `talk.maemo.org` are both still up and remain the reference
for Hildon APIs and Maemo packaging.

## 5. Hardware facts that shape the build

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
  extensions. This drives the cipher preference in [DESIGN.md](DESIGN.md).
