# Open

Things that are unresolved, and — importantly — which of them need the device in
hand. Session of 2026-09-08, revised the same day.

**The device is blocked:** its battery is swollen and a replacement is on order.
Do not charge it.

**QEMU moved the line, twice.** `tools/qemu-smoke.sh` runs our binaries against
the device's own glibc 2.5 loader (BUILDLOG §7). Then `tools/emulator-smoke.sh`
went further and boots the **real Diablo firmware** — the actual 2.6.21 kernel
and the actual 220 MB userland, from Nokia's final N810 release — under
full-system QEMU (BUILDLOG §10). Items 1, 2, 4 and 9 are answered, and 10 has
been reproduced. What is left below genuinely needs the hardware.

## Needs the device (first session with hardware)

1. ~~**Confirm the installed versions.**~~ **Answered from the firmware
   itself**, not the package index: glibc 2.5, `libc6 2.5.0-1osso10`,
   `zlib1g 1:1.2.3-9.osso8`, `libssl0.9.8 0.9.8e-9maemo3`,
   `libcurl3 7.15.5-1osso4`, `Linux version 2.6.21-omap1`, 622 packages. Both
   sysroot pins are exactly right and the `check-artifact.sh` thresholds hold.
   See BUILDLOG §10.

   Still worth running on **your** tablet, which may have been updated or have
   extras installed — but the baseline is no longer a guess.

   One thing the index could not have shown: a stock device has **no `openssl`
   CLI, no `wget`, no `curl` and no Python**, only `libssl0.9.8`.

2. **Does anything built here actually run?** — **answered, under QEMU.** It
   starts, both providers load, RSA and EC keygen work, and it completes a real
   TLS 1.3 handshake. That took finding and fixing an IFUNC bug that two clean
   `check-artifact.sh` runs had passed (BUILDLOG §7).

   What QEMU cannot answer, and the device still must: `qemu-arm` translates
   syscalls to the host kernel and does not refuse what 2.6.21 lacked. So a
   syscall the real kernel does not serve would still surface only on the
   tablet.

3. **Free space.** The built runtime is **5.3 MB** (libcrypto 3.6 MB, libssl
   832 KB, openssl CLI 772 KB, libatomic 40 KB, legacy provider 88 KB). Check
   what the rootfs and the 2 GB internal flash actually have, and decide where
   `/opt/handshake` really lives.

4. ~~**Does `/dev/urandom` behave?**~~ **Present and readable** on the real
   firmware under emulation, and `openssl rand` works on the 2.6.21 kernel.
   Not yet shown: that it is not starved early in boot on real hardware, which
   is a timing property an emulator cannot reproduce.

5. **Benchmark, do not guess.** `openssl speed chacha20-poly1305 aes-128-gcm
   sha256` and `openssl s_time`. The ChaCha20-over-AES preference in
   [DESIGN.md](DESIGN.md) is a well-founded prediction, not a measurement.
   Record real handshake latency to a TLS 1.3 host.

13. **How to get files onto a stock tablet, and a shell on it.** It has no
    `rootsh` and no `openssh`. USB mass storage needs nothing installed and is
    the way in; from there, `dpkg -i` the two packages from an xterm. The
    armel `.deb` files are in the mirror pool
    (`pool/maemo4.1.2/free/o/openssh/ssh_3.8p1-3osso7.2_armel.deb`). Assemble
    this kit before the battery arrives, not during that session.

## Needs a decision

6. ~~**Which CA bundle.**~~ **Decided: the full Mozilla store.** A trimmed
   store is a standing maintenance job that fails closed and confusingly, and
   150 KB against 2 GB of flash is not worth managing. `tools/mk-truststore.sh`
   fetches and checksum-verifies it; `qemu-smoke.sh` confirms
   `Verification: OK`. See DECISIONS.md #25.

7. **Package naming.** `libssl3` collides conceptually with Debian's own
   package of that name, which could confuse anyone who later puts a Debian
   chroot on the device. `handshake-openssl` is uglier and unambiguous.

8. **How far to take Python.** Rebuilding just `_ssl.so` against the new
   library is a couple of hours and makes the device scriptable against modern
   services. Rebuilding all of Python 2.5 is a much larger job for little more
   benefit. Start with the extension module only.

## Unresolved technical questions

9. ~~**Does `stunnel` need anything Diablo lacks?**~~ **Answered: no.** It
   cross-builds first time and needs `libutil.so.1` on top of libc, pthreads
   and our OpenSSL — all stock. Proven under QEMU to wrap a plain-HTTP client
   into a verified TLS 1.3 connection. See BUILDLOG §9.

10. **Certificate validation needs a correct clock.** Still open, and now
    **reproduced**: the emulator boots to `Thu Jan  1 00:00:09 UTC 1970`. It
    does that for its own reasons (no RTC), but the symptom is identical to a
    dead backup battery, which an 18-year-old device will likely have. Every
    certificate reads "not yet valid" and TLS fails looking exactly like a TLS
    bug. Needs an NTP story — plain UDP, so it works without any of this.

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
