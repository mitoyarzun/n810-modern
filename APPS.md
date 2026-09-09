# What can realistically run on this device

A backlog, with reasons. Everything here is checked against the actual
firmware — `var/lib/dpkg/status` and the shipped libraries — not guessed from
the spec sheet.

## The two gates

**CPU.** 400 MHz ARM11 (ARMv6), no NEON, 128 MB RAM. Roughly a hundredth of a
modern phone, with no SIMD to soften it. Anything that encodes video or does
heavy DSP work in software is out.

**C++ ABI.** The device has `libstdc++.so.6.0.3` — GCC 3.4, `GLIBCXX_3.4`
only. Anything needing C++11 or later means shipping our own runtime: possible,
but it turns an afternoon into a risk. **Pure C predicts feasibility better
than any other single factor.**

There is a third, softer gate: a stock device has **no `openssl` CLI, no
`wget`, no `curl`, no Python** — only `libssl0.9.8`. Assume nothing is present.

## What the device already has

Worth knowing before porting anything, because several "hard" problems are
already solved in hardware:

| | |
| --- | --- |
| `libgsthantrocodec.so` | MPEG-4/H.263 codecs **in software, on the ARM** — see below |
| `libgstdspg711/g729/ilbc/amr/mp3/aac` | **DSP audio codecs** — a real TMS320C55x |
| `libsofia-sip-ua`, `telepathy-sofiasip` | a complete **SIP stack** |
| `osso-voip-ui`, `osso-accounts-plugin-sip` | SIP account UI and calling UI |
| `farsight`, `telepathy-stream-engine` | media/call framework |
| `libgstvideo4linux2.so` | camera capture |
| `mediaplayer-ui`, `osso-media-server` | a real media player |
| `libgupnp0` | UPnP library — **but nothing links against it** |
| gstreamer `rtsp`, `tcp`, `udp` | streaming sources; **no HTTP source plugin** |
| `/dev/net/tun` | **TUN/TAP is in the kernel** — verified, see below |
| `iptables`, `ip`, `pppd` | routing tools are already installed |
| kernel `cbc(aes)`, `sha256`, xfrm | crypto API and IPsec — named in the kernel image; `/proc/crypto` is empty until something registers |
| `gst_dsppcmsrc` in `libgstdsppcm.so` | **DSP audio capture**, not raw ALSA |

## Done

OpenSSL 3.5.8 · stunnel 5.80 · zlib 1.3.2 · curl 8.22.0 · OpenSSH 10.5p1

## Realistic — pure C, mostly things TLS unlocks

| | Notes |
| --- | --- |
| **git** | needs curl, which is done |
| **irssi / weechat** | IRC over TLS; C + glib |
| **profanity** | XMPP over TLS; C + libstrophe |
| **mutt / msmtp / fetchmail** | email over TLS |
| **rsync, tmux, vim, sqlite, tcpdump** | small, plain C |
| **Python 3** | pure C; RAM-hungry but makes the device scriptable |
| **NetSurf** | own layout engine, C, framebuffer frontend needs no X. ~15 small packages: libpng, libjpeg, freetype, libexpat, then its own nine libraries. **TLS 1.3 transport, 2005-era rendering** — no flexbox, no grid, Duktape ES5.1 at best. Wikipedia and HN work; anything React-shaped does not. |

## Plausible, with caveats

**SIP audio calls — possibly zero porting.** The device has sofia-sip, a
calling UI, and DSP-accelerated G.711. SIP has barely changed since 2008, so a
self-hosted server (Asterisk, FreeSWITCH, Kamailio) may work by configuration
alone. Untested — needs the hardware.

**SIP video calls.** Unlike WebRTC, SIP lets you *negotiate* the codec, and
both ends are yours. `/etc/farsight/gstcodecs.conf` says exactly what the
device will offer:

```
[video/H263]       QCIF=2          176x144
[video/H263-1998]  QCIF=2
[audio/PCMA] [audio/PCMU]          G.711 A-law / mu-law
[audio/iLBC] mode=30
[audio/G729]

disabled (id=-1): SPEEX, GSM, AMR, VORBIS, THEORA
```

So a bridge must transcode **VP8/H.264 -> H.263 QCIF** and **Opus -> G.711**.
FreeSWITCH and Janus both do this already. Audio needs no transcoding at all:
G.711 is universal on modern SIP servers.

**Video playback from Plex/Jellyfin.** The most feasible app of the lot: the
hard part (hardware decode) already exists. The crux is the transcode profile,
not the client — roughly:

```
-c:v libx264 -profile:v baseline -level 3.0 -vf scale=800:-2
-b:v 700k -c:a aac -b:a 96k -movflags +faststart
```

Jellyfin fits better than Plex because you can define a custom device profile.
Note gstreamer has no HTTP source plugin, so RTSP or fetch-then-play is safer
than HTTP streaming. Cheapest first step: transcode one file server-side,
fetch it with curl, play it locally — proving the profile before writing an app.

**baresip** — pure C, modular SIP, if the device's own stack proves unusable.

## Not realistic

**Modern video chat (WebRTC).** C++17, VP8/VP9/H.264, DTLS-SRTP, ICE. Even
with a shipped libstdc++, software video encode has no CPU headroom, and the
hardware that could do it (DSP, Hantro) has no open toolchain and is not
emulated.

**Signal, WhatsApp, Matrix clients.** Proprietary or modern C++/Rust, with
protocols that change faster than a port could track.

**Modern browser engines.** Blink, Gecko and WebKit all need C++17 and
hundreds of MB of RAM.

## VPN, AI harnesses, push-to-talk

Three questions asked together. The answers are not the same, so here is the
evidence for each.

### The kernel has TUN/TAP

This decides every VPN option, so it is a test, not a guess. The 2.6.21
kernel contains `drivers/net/tun.c`. A 40-line C probe on the real kernel
under emulation opens the device and creates an interface:

```
200 tun                                    <- /proc/misc
crw-r--r--  1 root root  10, 200 /dev/net/tun
  open /dev/net/tun: ok (fd 3)
  TUNSETIFF: ok -- interface 'wg0' created
```

So a userspace VPN can move packets. That was the only hard blocker.

### WireGuard

**Kernel WireGuard: no.** `wireguard-linux-compat` reaches back to Linux 3.10.
This kernel is 2.6.21, which is not close.

**wireguard-go and boringtun: no,** and the reason is sharper than "the
kernel is too old". `tools/probe-kernel.sh` asks the kernel for the syscalls
these runtimes make:

```
futex WAIT         present, errno=Resource temporarily unavailable
futex WAIT_PRIVATE ABSENT  (ENOSYS)   (Go runtime locks)
eventfd2           ABSENT  (ENOSYS)   (Go netpollBreak)
epoll_create1      ABSENT  (ENOSYS)   (Go + Node netpoll)
pipe2              ABSENT  (ENOSYS)   (Node, libuv)
accept4            ABSENT  (ENOSYS)   (Go, libuv)
getrandom          ABSENT  (ENOSYS)   (Go, Rust, Node)
```

Plain `futex` works. `FUTEX_WAIT_PRIVATE`, which the Go runtime uses for every
mutex, does not exist -- it arrived in 2.6.22. **Go cannot take a lock on this
kernel**, so no Go program runs, whatever you compile it with. Static linking
does not help, because the gap is the kernel, not glibc. This is the one gate
you can remove -- see [Upgrading the kernel](#upgrading-the-kernel).

**A userspace WireGuard in C: yes, and nothing blocks it.** WireGuard needs
three primitives, and the OpenSSL 3.5.8 we already ship has all three. Asked
of the real binary, on the device's own glibc:

```
X25519             { 1.3.101.110, X25519 } @ default
ChaCha20-Poly1305  ChaCha20-Poly1305
BLAKE2s256         { 1.3.6.1.4.1.1722.12.2.2.8, BLAKE2S-256 } @ default
```

TUN moves the packets, OpenSSL does the crypto, `ip` and `iptables` do the
routing. The missing piece is the Noise IK handshake and a data-plane loop.

Be clear about what this is: **writing code, not porting it.** It is the only
item in this document where the device needs no bridge at all.

### Tailscale

The client is Go, so the syscall table above rules it out. The tablet cannot
be a tailnet node. It can still reach the tailnet, in three ways.

**1. A SOCKS5 proxy. Works today, no code.** Run `tailscaled` in userspace
mode on any machine on the LAN:

```
tailscaled --tun=userspace-networking --socks5-server=<lan-ip>:1055
```

Our curl already speaks it, and `--socks5-hostname` resolves at the proxy, so
MagicDNS names work:

```
curl --socks5-hostname <lan-ip>:1055 http://host.tailnet-name.ts.net/
```

Both flags are in tailscaled 1.98.9. Only proxy-aware programs benefit.

**Warning: tailscaled's SOCKS5 server has no authentication.** Anything that
reaches that port gets your whole tailnet. Bind it to one interface and
firewall it to the tablet's address. Never bind it to `0.0.0.0`.

**2. A subnet router. Works today, and every program benefits.** A LAN machine
runs `tailscale up --advertise-routes=100.64.0.0/10`, and the tablet takes a
static route through it:

```
ip route add 100.64.0.0/10 via <router-lan-ip>
```

More transparent than the proxy, because it needs no per-program support. The
tablet still has no Tailscale identity, and MagicDNS needs its resolver
pointed at the router.

**3. A WireGuard bridge. Needs the C client above written first.** A plain
WireGuard endpoint that is itself on the tailnet gives the tablet an encrypted
tunnel that also works away from home, on untrusted WiFi, which neither option
above does. [TailGuard](https://github.com/juhovh/tailguard) is an existing
container for exactly this case: a WireGuard host that cannot run Tailscale
binaries.

**Joining as a real node: no.** That means reimplementing the control plane,
DERP relays, MagicDNS and NAT traversal in C. Whether Tailscale still accepts
WireGuard-only peers directly is worth checking before building option 3; we
did not confirm it either way.

### Claude Code and other AI harnesses

**Claude Code itself: no.** It is Node.js, and the syscall probe above shows
`epoll_create1`, `pipe2` and `accept4` all missing, so libuv has no event loop
to build on. Node also needs glibc 2.28 and C++17 against the device's glibc
2.5 and `GLIBCXX_3.4`. No bridge argument saves this.

Two things do work:

**Use the tablet as a terminal.** We built OpenSSH 10.5p1. Run `ssh`, and the
harness runs on a real machine. An 800x480 screen and a hardware keyboard make
a good terminal. This works now and needs no new code.

**Write a small client.** The Messages API is HTTPS and JSON, and curl 8.22.0
already does TLS 1.3 on the device. A few hundred lines of C, plus a
header-only JSON parser, give an on-device client with no Node at all.

### Push-to-talk AI

The best fit of the three, and the same bridge pattern as SIP and Plex.

The shape: hold a hardware key, capture PCM, POST it over TLS, play the reply.
Every modern part — speech to text, the model, text to speech — runs on the
server. The tablet records and plays.

Two facts help. The device has a DSP capture element, `gst_dsppcmsrc`, so
audio capture needs no ALSA porting. And 16 kHz mono PCM is 32 KB/s, which
WiFi carries easily, so **send raw audio and encode nothing**. That avoids the
CPU gate completely.

**Not yet testable.** QEMU's `n810` machine models no audio codec:

```
=== 2. Audio ===
--- no soundcards ---
  no /dev/snd
  no OSS nodes
```

That is a limit of the emulator, not of the device. Audio work waits for
hardware.

## Upgrading the kernel

Every "no" above traces back to Linux 2.6.21. That gate is the only one you
can remove, so it is worth knowing the price.

**It has been done, several times.** [ssvb/linux-n810](https://github.com/ssvb/linux-n810)
is mainline 2.6.38.8 with the OpenWrt patches. OpenWrt itself ran 3.3.8 on the
N810. There was a Debian port on post-2.6.30 kernels.

**Mainline still carries the board.** `arch/arm/mach-omap2/board-n8x0.c` is in
Linus's tree today and someone still works on it:

```
2026-05-07  p54spi: convert to devicetree
2025-07-18  arm: omap2: use string choices helper
2024-02-23  ARM: OMAP2+: fix USB regression on Nokia N8x0
```

WiFi (`p54spi`), MMC, USB and the Menelaus PMIC are all mainline. So is the
N810 audio machine driver, `sound/soc/ti/n810.c`.

### What a newer kernel buys

Measured against the syscall probe above:

| Syscall | Arrived in |
| --- | --- |
| `FUTEX_WAIT_PRIVATE` | 2.6.22 |
| `eventfd2`, `epoll_create1`, `pipe2` | 2.6.27 |
| `accept4` | 2.6.28 |
| `getrandom` | 3.17 — Go falls back to `/dev/urandom`, so not fatal |

Go needs 2.6.32 up to Go 1.23, and **3.2 from Go 1.24**. So the 3.3.8 kernel
clears current Go, and **Tailscale runs on the device itself**. Its
userspace-networking mode is wireguard-go over TUN, and TUN already works
here. Kernel WireGuard is separate: `wireguard-linux-compat` wants 3.10, so
that needs a mainline build, not a community one.

### Keeping Diablo, on a newer kernel

This is a different goal from the ports above, which all replaced the
userspace. It is also the most tractable, because the question is narrow: what
does Diablo need from 2.6.21 that a newer kernel would not give it?

The kernel image answers most of it. It embeds its own source paths, so the
out-of-tree surface can be listed rather than guessed:

| Piece | Path in Nokia's tree | On a newer kernel |
| --- | --- | --- |
| DSP Gateway | `arch/arm/plat-omap/dsp/{dsp_core,dsp_ctl,task}.c` | GPL, never mainlined — forward-port it |
| Power, PMIC, power button | `drivers/cbus/{retu,tahvo,retu-pwrbutton}.c` | GPL; retu and tahvo later reached mainline |
| Display | `drivers/video/omap/{blizzard,dispc,rfbi}.c` | GPL; **gone from current mainline** — only `hwa742.c` survives |
| Board glue | `arch/arm/mach-omap2/board-n800-{audio,bt,camera,mmc}.c` | superseded by mainline `board-n8x0.c` |
| Keypad | `drivers/input/keyboard/tsc2301_kp.c` | GPL |
| WiFi | `cx3110x.ko`, `umac.ko` | **closed, and you do not need them** |

**WiFi is the happy surprise.** The one piece with no source is the one to
throw away. Mainline's `p54spi` says so itself:

```
config P54_SPI
	tristate "Prism54 SPI (stlc45xx) support"
	  This driver is for stlc4550 or stlc4560 based wireless chips
	  such as Nokia's N800/N810 Portable Internet Tablet.
```

and it loads `3826.arm` -- the same firmware blob already sitting in the
device's own initfs. Diablo's `wlancond` drives WiFi through Wireless
Extensions (`SIOCGIWAP`), which `CONFIG_CFG80211_WEXT` still provides. So an
open driver can sit under an unmodified Maemo.

### How far to go

| Target | Gains | Risk to Diablo |
| --- | --- | --- |
| **2.6.28-2.6.31** | every syscall that blocks modern C: `FUTEX_WAIT_PRIVATE` (2.6.22), `epoll_create1`, `eventfd2`, `pipe2` (2.6.27), `accept4` (2.6.28) | low — omapfb v1 still has `blizzard.c`, and the Nokia drivers still fit the era's APIs |
| **2.6.38** | as above; [ssvb/linux-n810](https://github.com/ssvb/linux-n810) proves the hardware runs here | medium — omapfb gives way to DSS2, and platform code churns |
| **3.2+** | Go 1.24, so Tailscale runs on the device | high — this is where keeping Diablo starts to fight you |

**This is now started, not theory.** `tools/mk-kernel-2628.sh` fetches Nokia's
GPL kernel source, computes their delta against vanilla 2.6.21, applies it to
2.6.28, and generates their board config on the result:

```
Computing the Nokia delta      638 files, 5.0M
Applying it to 2.6.28          patched: 508 files   rejects: 173 files

  arch/arm/plat-omap/dsp       10 .c files, 0 rejects
  drivers/cbus                 10 .c files, 0 rejects
  drivers/video/omap           21 .c files, 0 rejects
  sound/arm/omap               12 .c files, 0 rejects

.config written: 1804 lines
  CONFIG_OMAP_DSP=y
  CONFIG_ARCH_OMAP2420=y
```

**Every Nokia subsystem applies with zero rejects**, because they are new
files rather than edits. The 173 rejects are all in shared core files, and
most need no work at all -- Nokia was a large OMAP contributor, so 2.6.28
already has their change:

```
file                       van-2.6.21  NOKIA  van-2.6.28
fs/jffs2/readinode.c       1019        1435   1438
arch/arm/plat-omap/fb.c    79          344    342
```

Check each reject against vanilla 2.6.28 **before** porting it. The usual
right answer is to drop it.

**It compiles, and it links.** With `omap_generic_2420_defconfig` the rebased
tree builds a **760,952 byte zImage**. With `nokia_2420_defconfig` the final
link still fails; that is the open item.

Getting there needed a period compiler. GCC 13 cannot build a 2008 kernel: it
dies on GNU89 inline semantics, then a cast-as-lvalue that GCC 4.0 removed,
then assembler syntax. kernel.org publishes prebuilt crosstools for exactly
this job, and 4.9.4 is the oldest for an arm64 host, so it runs natively on
Apple silicon.

### The trap worth knowing

**2.6.28 moved the ARM headers.**

```
include/asm-arm/           -> arch/arm/include/asm/
include/asm-arm/arch-omap/ -> arch/arm/plat-omap/include/mach/
```

56 of the 638 files in Nokia's delta live under the old paths, and 50 of those
are the OMAP headers -- `blizzard.h`, `board-nokia.h`, `aic23.h`. Patching them
at the old path **succeeds and then does nothing**, because the build never
reads that directory. No error, no reject. The failure surfaces much later as
a missing `ATAG_BOARD` in a different file.

Four more are pure 2026-host problems: GNU Make 4.3 rejects the old mixed
implicit rules; `kernel/timeconst.pl` uses `defined(@array)`, which Perl 5.22
removed; and empty `built-in.o` files are empty `ar` archives, which binutils
2.29 cannot derive a machine from -- it says `no machine record defined` and
names no file.

### The rule that made it converge

Fixing files one at a time was slow. Stating the rule once was not:

> Keep Nokia's changes where the hardware lives -- `plat-omap`, `mach-omap2`,
> `cbus`, `video/omap`, `sound/arm/omap`, their configs. Take vanilla 2.6.28
> everywhere else.

Nokia was a large upstream contributor, so their core-kernel edits are usually
already in 2.6.28, and keeping them only duplicates definitions. That one rule
took the build from 270 files to 752.

The flashing mechanism is known to work and to keep Maemo -- Diablo-Turbo did
it in 2011 with `fiasco-flasher -f -k zImage`.

**Aim at 2.6.28 first.** It is about 18 months of kernel churn, not eighteen
years. It keeps the display, keeps the DSP for a short forward-port, swaps
closed WiFi for open, and unblocks most modern C software.

One concrete check that this repository already depends on: `fb-autoupdate.c`
uses `OMAPFB_SET_UPDATE_MODE`, an omapfb v1 ioctl. It survives at 2.6.28 and
breaks at DSS2. That single ioctl is a good early warning for the whole
display path.

What 2.6.28 does **not** buy is Go, so Tailscale stays on the SOCKS5 or
subnet-router bridge above. That is the trade: a short hop keeps the tablet, a
long hop gets Go.

### What it costs

**Maemo goes.** Every port above replaced the userspace — OpenWrt, Debian,
Android. Diablo's closed Nokia modules are built against 2.6.21 and will not
rebuild. You get a Linux box in a tablet case, not a tablet.

**The DSP goes.** It was never mainlined. That throws away the hardware video
decode and the DSP audio codecs — which are exactly what made Plex playback
and SIP video plausible in the first place.

**On mainline, the N810 screen goes too.** `drivers/video/fbdev/omap/` offers
the Epson HWA742, which is the N800's controller. The N810 uses the Blizzard,
and there is no driver for it in the current tree. The older community kernels
still have one.

### So which way

The two strategies pull against each other, and that is the real decision:

- **Keep 2.6.21.** Keep Maemo, the DSP and the screen. Reach the modern world
  through bridges — stunnel, a SOCKS5 proxy, a transcode shim. Nothing here
  needs new hardware support.
- **Upgrade.** Get Go, Tailscale, current everything. Lose the tablet.

This repository takes the first path (DECISIONS #1). The second is a real
option, not a fantasy, and someone should try it. It is a different project.

## The DSP, and why it is the wrong thing to reverse engineer

### First, a correction

An earlier version of this file called `libgsthantrocodec.so` "hardware video
decode". **That is wrong.** The library reports itself as `HantroSwMpeg4v3.4`
-- *Sw*. It has no `ioctl`, no `dlopen`, no device node, no firmware file, and
there is no Hantro kernel driver anywhere in the firmware. It is Hantro's
software MPEG-4/H.263 codec, running on the ARM.

**This device has no hardware video decode.** That is why its own SIP profile
offers H.263 at QCIF, 176x144.

### What the DSP is

Audio only. `/lib/dsp/modules` holds one task per codec: `g711`, `g729`,
`ilbc`, `amrnb`, `amrwb`, `mp2`, `mp3`, `aac`, `aep`.

The core is a **TI TMS320C55x**: COFF magic `0x00c2`, and the runtime is built
from `c55_c.s55` with `_C55_INTC_*` symbols.

### The interface is not a black box

This is the good news. The ARM talks to the DSP through **Nokia's DSP
Gateway**: `/dev/dsptask/<name>`, `/dev/dspctl/ctl`, `/dev/dspctl/mem`, with a
version handshake in `/sys/devices/platform/dsp.0/ifver`.

The task ABI is small and legible. Symbols in an 8 KB task object:

```
.text:create  .text:init  .text:delete  .text:exit     <- lifecycle
_bksnd  _ipbuf_d                                       <- buffer transfer
```

The `.cmd` linker files are plain text and ship on the device:

```
SECTIONS {
	g711_enc_mmap_buffer: align=0x10000 {}	> EXTMEM4
	g711_enc_eap_bufs: align=0x04 {}	> EXTMEM4
}
```

So the protocol needs little reverse engineering. The parts that are closed
are the task objects (~8-13 KB each) and `avs_kernel.out` (962 KB).

### Why reverse engineering it is still the wrong target

**1. The blocker is the toolchain, not the secrets.** No GCC or LLVM backend
for C55x exists; TI's `cl55` is proprietary. You could understand every task
perfectly and still not be able to build a replacement. Writing a C55x backend
is a multi-year project *before* any DSP code gets written.

**2. The payoff is battery life, not capability.** Every codec the DSP
provides already has a mature open implementation that runs on ARM: G.711 is a
table lookup, and there are bcg729, libilbc, opencore-amr, libmad and faad2 for
the rest. One audio stream fits comfortably in 400 MHz. The DSP does it at a
fraction of the power, which matters on a handheld -- but it unlocks nothing.

### The cheaper target, which nobody has taken

**You do not need to replace the blobs.** They run on the DSP. They do not
care which kernel the ARM runs. What is missing on a modern kernel is the
*ARM-side driver* -- and that is GPL source, not a blob.

Nobody has done it. The 2.6.38 N810 kernel has no `arch/arm/plat-omap/dsp`,
and `dsptask` appears nowhere in the tree. Every community port simply dropped
the DSP.

So the highest-value work is **forward-porting the DSP Gateway driver**, which
keeps every codec across a kernel upgrade with no reverse engineering at all.
It also removes the sharpest trade-off in the section above: upgrade the
kernel *and* keep the audio hardware.

Reverse engineering is the right tool when the interface is secret. Here the
interface is published and the compiler is the wall.

## The pattern worth reusing

Three separate problems — TLS, video calls, media streaming — have the same
shape of answer: **put the modern protocol work on hardware that can afford
it, and let the tablet speak something old and cheap.**

That is exactly what stunnel already does: a stock app talks plain HTTP to
localhost and reaches a TLS 1.3 site. A SIP bridge transcoding WebRTC to
H.263, or a shim transcoding Plex to baseline H.264, is the same idea applied
again.

Porting the modern thing is usually the harder and worse option.
