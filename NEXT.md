# Next

Written 2026-09-08, at the end of the Tier 1 prep session. Ordered. Each step
says what to run, what "done" looks like, and what to do when it isn't.

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

…or unpack the tarball from the session, which is the same tree, already
verified: `handshake-openssl-3.5.8-diablo-armel.tar.gz`.

The build host does not need to be the same machine as the one talking to the
tablet. The artefacts are 5.3 MB.

---

## Step 1 — Prove it runs (needs the device)

Everything downstream is blocked on this, and it is one command.

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
checker bug, not a build bug — see BUILDLOG §6).

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

---

## Step 2 — Certificates

Without a current trust store the new library still fails, just later and more
confusingly.

```sh
# on the build host
curl -O https://curl.se/ca/cacert.pem
# on the tablet
cp cacert.pem /opt/handshake/ssl/cert.pem
/opt/handshake/bin/openssl s_client -connect example.org:443 -servername example.org
```

**Done when** `s_client` reports `Verify return code: 0 (ok)` rather than
`unable to get local issuer certificate`.

Decision still open (OPEN.md #6): full Mozilla store vs. a trimmed one. Default
to the full store; only trim with a reason.

---

## Step 3 — stunnel

The highest-leverage consumer, and the reason it comes before `wget`: it
retroactively gives modern TLS to *every* stock app that can be pointed at
localhost. Once it exists, the Tier 0 LAN-proxy workaround stops needing a
second machine.

```sh
. tools/env.sh
./configure --host=arm-linux-gnueabi --prefix=/opt/handshake \
            --with-ssl=$PWD/out/opt/handshake
```

Unknown: whether stunnel needs anything Diablo lacks (OPEN.md #9). Check before
committing to it. Write `tools/build-stunnel.sh` in the same shape as
`build-openssl.sh`, and run everything through `check-artifact.sh`.

**Done when** a stock Diablo app configured to use `localhost:<port>` reaches a
TLS 1.3 site.

---

## Step 4 — wget, then curl and git

`wget` first: smallest, most obviously useful, proves the pattern for
everything after it.

`curl` carries the complication in OPEN.md #11 — Diablo's `libcurl3` is 7.15.5
and links the old OpenSSL. Install ours in parallel under `/opt/handshake`
first; only consider touching the system library with evidence that parallel
install is insufficient. DECISIONS.md #2 says coexist, never replace.

`git` wants curl, so it follows.

---

## Step 5 — Python's `_ssl`

Rebuild only the extension module against the new library, leaving the
interpreter alone (OPEN.md #8). This is the smallest change that makes the
device scriptable against modern services, and it is the point at which the
tablet becomes useful for the thing you actually wanted it for.

---

## Step 6 — Distribution

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

Read in this order: [README.md](README.md) for what and why,
[BUILDLOG.md](BUILDLOG.md) for the five flags and why each exists, then this
file. `DESIGN.md` and `DECISIONS.md` are reference, not narrative.

The one thing worth re-reading before touching the toolchain: four of the five
required compiler flags exist because the *host* is modern, not because the
target is old. Any new build that skips `tools/env.sh` will rediscover all of
them.
