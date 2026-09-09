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
| `libgsthantrocodec.so` | **hardware video decode** |
| `libgstdspg711/g729/ilbc/amr/mp3/aac` | **DSP audio codecs** |
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
does not help, because the gap is the kernel, not glibc.

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

## The pattern worth reusing

Three separate problems — TLS, video calls, media streaming — have the same
shape of answer: **put the modern protocol work on hardware that can afford
it, and let the tablet speak something old and cheap.**

That is exactly what stunnel already does: a stock app talks plain HTTP to
localhost and reaches a TLS 1.3 site. A SIP bridge transcoding WebRTC to
H.263, or a shim transcoding Plex to baseline H.264, is the same idea applied
again.

Porting the modern thing is usually the harder and worse option.
