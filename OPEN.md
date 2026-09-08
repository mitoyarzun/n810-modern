# Open

Things that are unresolved, and — importantly — which of them need the device in
hand. Session of 2026-09-08.

## Needs the device (first session with hardware)

1. **Confirm the installed versions.** Everything in [RESEARCH.md](RESEARCH.md)
   comes from the Diablo package index, not from your actual tablet, which may
   have been updated or have extras installed. Run and record:
   ```sh
   dpkg -l | grep -iE 'ssl|gnutls|nss|libc6|zlib'
   uname -a
   openssl version -a
   cat /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null
   ```
   In particular: is it really `0.9.8e`, and is the kernel really `2.6.21`? The
   whole `check-artifact.sh` threshold (`GLIBC_2.4`, ABI note ≤ 2.6.21) is
   derived from these.

2. **Does anything built here actually run?** The first real test is not
   OpenSSL, it is `hello`. Copy it over, run it, and confirm no
   `FATAL: kernel too old`. If that fails, nothing else matters.

3. **Free space.** The built runtime is **5.3 MB** (libcrypto 3.6 MB, libssl
   832 KB, openssl CLI 772 KB, libatomic 40 KB, legacy provider 88 KB). Check
   what the rootfs and the 2 GB internal flash actually have, and decide where
   `/opt/handshake` really lives.

4. **Does `/dev/urandom` behave?** Seeding is configured to use it exclusively.
   Confirm it exists, is readable, and is not starved early in boot.

5. **Benchmark, do not guess.** `openssl speed chacha20-poly1305 aes-128-gcm
   sha256` and `openssl s_time`. The ChaCha20-over-AES preference in
   [DESIGN.md](DESIGN.md) is a well-founded prediction, not a measurement.
   Record real handshake latency to a TLS 1.3 host.

## Needs a decision

6. **Which CA bundle.** Shipping Mozilla's full current store is simplest but
   it is ~150 KB of PEM and hundreds of roots the device will never meet. A
   trimmed store is friendlier to 128 MB of RAM but becomes a maintenance
   burden. Undecided; default to the full store until there is a reason not to.

7. **Package naming.** `libssl3` collides conceptually with Debian's own
   package of that name, which could confuse anyone who later puts a Debian
   chroot on the device. `handshake-openssl` is uglier and unambiguous.

8. **How far to take Python.** Rebuilding just `_ssl.so` against the new
   library is a couple of hours and makes the device scriptable against modern
   services. Rebuilding all of Python 2.5 is a much larger job for little more
   benefit. Start with the extension module only.

## Unresolved technical questions

9. **Does `stunnel` need anything Diablo lacks?** Not yet investigated. It is
   the highest-leverage consumer, so this should be checked before `wget`.

10. **Certificate validation needs a correct clock.** The N810's RTC depends on
    the backup battery, which on an 18-year-old device may well be dead. If the
    clock resets to 1970 on every boot, every certificate is "not yet valid" and
    TLS fails in a way that looks like a TLS bug. Needs an NTP story — and NTP
    over plain UDP still works fine, so this is solvable, just easy to miss.

11. **`libcurl3` is 7.15.5 and links the old OpenSSL.** Rebuilding curl means
    either a parallel install under `/opt/handshake` (safe, but stock apps keep
    using the old one) or replacing the system library (fast, but violates
    decision 2). Parallel first; revisit only with evidence.

12. **Is there an `armel` Debian chroot worth having after all?** Decided
    against in conversation because glibc needs a newer kernel than 2.6.21 —
    but that reasoning should be written down properly with versions, since it
    will be asked again.

## Deliberately not doing

- The browser. See [DECISIONS.md](DECISIONS.md) #4.
- Anything requiring a kernel change. Mainline has no display driver for this
  device; that is a separate and much larger project.
