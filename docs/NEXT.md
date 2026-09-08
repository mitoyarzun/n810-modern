# Next

Written 2026-09-08. Revised the same day, after QEMU changed which steps need
hardware. Ordered. Each step says what to run, what "done" looks like, and what
to do when it isn't.

**Device status: blocked.** The N810's battery is swollen. Do not charge it.

That blocks less than it looks. There are now three test levels below the
tablet, and the third runs the **real firmware**:

| Level | What it runs on | Answers |
| --- | --- | --- |
| `check-artifact.sh` | nothing — static | symbol versions, ABI note, IFUNC, NEEDED |
| `qemu-smoke.sh` | device's glibc 2.5, host kernel, host network | loading, crypto, real TLS handshakes |
| `emulator-smoke.sh` | **real 2.6.21 kernel, real 220 MB userland** | whether the kernel serves the syscalls |

See [BUILDLOG §7](BUILDLOG.md) and [§10](BUILDLOG.md).

[OPEN.md](OPEN.md) is the list of unresolved *questions*. This is the list of
*actions*.

---

## Pick it up locally

```sh
git clone git@github.com:mitoyarzun/explorations.git   # or: git fetch && git checkout
cd explorations
git checkout claude/nokia-n810-development-87dqb9
cd handshake
```

Then either rebuild (about fifteen minutes on four cores, Debian/Ubuntu host):

```sh
tools/setup-host.sh          # cross-compiler + prerequisites
tools/mk-sysroot.sh          # 27 MB Diablo sysroot from the mirrors
tools/build-openssl.sh       # OpenSSL 3.5.8 -> ./out
```

On a host with Docker and nothing else, one command does all three plus the
QEMU test:

```sh
tools/build-in-docker.sh
```

…or unpack the tarball from the session, which is the same tree, already
verified: `handshake-openssl-3.5.8-diablo-armel.tar.gz`.

The build host does not need to be the same machine as the one talking to the
tablet. The artefacts are 5.3 MB.

---

## Step 1 — Prove it runs under QEMU (no device needed)

This used to be step 1 *with* the device. It is not, and assuming it was cost
us a shipped build that could never have started. See [BUILDLOG §7](BUILDLOG.md).

```sh
tools/qemu-smoke.sh
```

It runs our armel binaries under `qemu-arm -L sysroot-diablo`, so the loader
resolving the symbols is the device's own glibc 2.5. That catches every class
of failure that lives between "the linker was happy" and "the process starts":
IFUNC symbols, missing libraries, bad relocations, providers that will not
load.

**Done when** all five sections pass, including a real TLS 1.3 handshake to
`example.org` over the build host's network.

**Run it on every build, before packaging.** `tools/build-in-docker.sh` does.

### What QEMU does not answer

`qemu-arm` translates syscalls to the host kernel. It does not refuse what
2.6.21 lacked. So it cannot tell you the real kernel serves every call, and its
timings are the build host's, not a 400 MHz ARM1136's. Those stay in step 2.

---

## Step 1b — Prove it runs on the real kernel (still no device)

```sh
tools/mk-diablo-emulator.sh    # fetches Nokia's final N810 firmware, ~124 MB
tools/emulator-smoke.sh        # boots it with our tree inside
```

Boots the actual `RX-44_DIABLO_5.2008.43-7` firmware under
`qemu-system-arm -M n810` and runs our binaries on the real 2.6.21 kernel and
the real Diablo userland.

**Needs QEMU 9.1 or earlier** — the `n810` machine was removed in 9.2. Ubuntu
24.04 ships 8.2, which works.

**Done when** openssl and stunnel both start, both providers load and keygen
works, on the real kernel. That is currently the case.

It cannot answer: real timings (QEMU's TCG models no pipeline or cache), WiFi,
the RTC, or flash wear. The emulated machine has no working network — its USB
controller does not come up.

### The desktop, if you want it

```sh
tools/emulator-gui-build.sh    # eight fixes, all documented in BUILDLOG §11
tools/emulator-gui.sh          # boots to the Hildon home screen, over VNC
```

Not needed for any of the TLS work, which is why `emulator-smoke.sh` boots
straight to a test script instead. It is useful for one thing: **rehearsing
the first tablet session**. Installing `rootsh` and `openssh` through the real
Application Manager, before the battery arrives, so that first charged hour is
spent testing rather than discovering.

---

## Step 2 — Prove it runs on the tablet (needs the device)

**Blocked: the battery is swollen and a replacement is on order.** Do not
charge a swollen lithium cell. Store it away from anything flammable and
recycle it.

Much of what this step used to be for is now answered. What genuinely remains:
real-hardware timings for DECISIONS.md #19, WiFi, the clock, free flash, and
confirming **your** tablet matches the stock firmware.

```sh
# on the tablet
tar xzf handshake-openssl-3.5.8-diablo-armel.tar.gz -C /opt
sh device-smoke-test.sh 2>&1 | tee ~/smoke-$(date +%F).log
```

**Done when** `openssl version` prints `OpenSSL 3.5.8` on the tablet and section
4 of the smoke test completes a real handshake with `example.org`.

**If it dies with `FATAL: kernel too old`** — the ABI note check was bypassed.
Confirm with `readelf -n /opt/handshake/bin/openssl`; it must read 2.6.8. See
BUILDLOG §2.

**If it dies with `cannot open shared object file`** — something needs a library
Diablo lacks and we did not ship. Name it, add it to the baseline or the bundle
in `tools/check-artifact.sh`, and work out why the checker passed it (that is a
checker bug, not a build bug — see BUILDLOG §6 and §7).

**Whatever happens, paste the whole log into BUILDLOG.md.** Sections 0 and 6 of
the smoke test capture the stock package versions and the speed numbers, which
several decisions in DECISIONS.md are currently resting on as predictions.

### Then immediately

- **Check the clock.** `date`. The RTC depends on a backup battery that is
  probably dead after eighteen years. A 1970 clock makes every certificate "not
  yet valid", which reads exactly like a TLS bug and is not one. Fix with NTP —
  plain UDP, so it works without any of this.
- **Confirm the premise.** Section 5 of the smoke test checks that the *stock*
  0.9.8e still cannot connect. If it can, something about the diagnosis is
  wrong and the project needs re-scoping before any more work.
- **Record `openssl speed`.** DESIGN.md claims ChaCha20-Poly1305 beats AES-GCM
  on this core. That is a well-founded prediction, not a measurement. If it is
  wrong, change the cipher preference and say so in DECISIONS.md #19.

### Before that session, prepare the first-contact kit

The tablet is stock, and the firmware confirms just how stock: **no `openssh`,
no `rootsh`, and also no `openssl` CLI, no `wget`, no `curl` and no Python** —
only the `libssl0.9.8` library. There is no way in but the on-screen keyboard
until something is installed.

Assemble a folder to copy over USB mass storage — `rootsh` and `ssh` `.deb`
files from the mirrors, the artefact tarball, and the smoke test — so the first
charged hour is spent testing, not typing.

The Diablo pool has what is needed:
`pool/maemo4.1.2/free/o/openssh/ssh_3.8p1-3osso7.2_armel.deb`.

Better: the emulator can rehearse this. The `.deb` files can be installed into
the extracted rootfs and the whole flow tested before the battery arrives.

---

## Step 3 — Certificates — **done**

```sh
tools/mk-truststore.sh
```

Mozilla's store, as curl publishes it, checksum-verified, installed to
`/opt/handshake/ssl/cert.pem` — which is the `OPENSSLDIR` compiled into the
library, so nothing needs configuring on the device.

Confirmed by `tools/qemu-smoke.sh` section 4:

```
4. A real TLS 1.3 handshake, over this host's network
   trust store: out/opt/handshake/ssl/cert.pem
   ok    TLS 1.3 to example.org
         Ciphersuite: TLS_AES_256_GCM_SHA384
         Verification: OK
```

OPEN.md #6 (full store vs. trimmed) is settled in favour of the full store.
See DECISIONS.md #25.

`tools/build-in-docker.sh` runs this before the smoke test, so the tarball
ships with a current trust store.

---

## Step 4 — stunnel — **done**

```sh
tools/build-stunnel.sh
tools/qemu-stunnel-test.sh
```

Built first time. OPEN.md #9 is answered: stunnel needs nothing Diablo lacks.
Its `NEEDED` list is `libssl.so.3 libcrypto.so.3 libutil.so.1 libpthread.so.0
libc.so.6 ld-linux.so.3` — two ours, four stock.

Proven under QEMU: a **plain HTTP** client reaches `example.org` over TLS 1.3
with `X25519MLKEM768` and a verified chain. That is a stock Diablo application
getting modern TLS without being rebuilt, which is the reason this package came
before `wget`. See [BUILDLOG §9](BUILDLOG.md).

**Still to do on the device:** write the real config. The test config is a
single client tunnel to one host. What the tablet wants is a small set of
services on fixed local ports, and a note in the README saying which port maps
to what.

---

## Step 5 — wget, then curl and git

`wget` first: smallest, most obviously useful, proves the pattern for
everything after it.

`curl` carries the complication in OPEN.md #11 — Diablo's `libcurl3` is 7.15.5
and links the old OpenSSL. Install ours in parallel under `/opt/handshake`
first; only consider touching the system library with evidence that parallel
install is insufficient. DECISIONS.md #2 says coexist, never replace.

`git` wants curl, so it follows.

---

## Step 6 — Python's `_ssl`

Rebuild only the extension module against the new library, leaving the
interpreter alone (OPEN.md #8). This is the smallest change that makes the
device scriptable against modern services, and it is the point at which the
tablet becomes useful for the thing you actually wanted it for.

---

## Step 7 — Distribution

Only worth doing once several packages exist. Shape is in DESIGN.md §4: a
static apt repo over **plain HTTP** with signed packages, because you cannot
fetch the thing that enables HTTPS over HTTPS. GitHub Pages hosts it free. Add
a `.install` file so Hildon Application Manager can add the catalogue in one
tap.

Settle the naming question (OPEN.md #7) before publishing anything, since
renaming a published package is worse than choosing badly once.

---

## Not next

- **The browser.** DECISIONS.md #4. If a browsing story is ever wanted the
  answer is a NetSurf port, which falls out of Step 4 nearly free — and it is a
  separate project with its own name.
- **Anything needing a kernel change.** Mainline has no display driver for this
  device. Also a separate and much larger project.

---

## If you come back to this cold

Read in this order: [README.md](../README.md) for what and why,
[BUILDLOG.md](BUILDLOG.md) for the five flags and why each exists, then this
file. `DESIGN.md` and `DECISIONS.md` are reference, not narrative.

The one thing worth re-reading before touching the toolchain: four of the six
required compiler flags exist because the *host* is modern, not because the
target is old. Any new build that skips `tools/env.sh` will rediscover all of
them.

The second thing: run `tools/qemu-smoke.sh`. Two builds in a row passed
`check-artifact.sh` and could not have started on the device. A static checker
only knows the failures someone already met.
