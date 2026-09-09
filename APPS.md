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
both ends are yours. With Hantro doing the work rather than the CPU, H.263 at
QCIF is plausible. Read `/etc/farsight/gstcodecs.conf` before assuming what
gets offered.

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

## The pattern worth reusing

Three separate problems — TLS, video calls, media streaming — have the same
shape of answer: **put the modern protocol work on hardware that can afford
it, and let the tablet speak something old and cheap.**

That is exactly what stunnel already does: a stock app talks plain HTTP to
localhost and reaches a TLS 1.3 site. A SIP bridge transcoding WebRTC to
H.263, or a shim transcoding Plex to baseline H.264, is the same idea applied
again.

Porting the modern thing is usually the harder and worse option.
