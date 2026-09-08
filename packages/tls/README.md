# TLS

OpenSSL 3.5.8 and stunnel 5.80, cross-compiled for Maemo Diablo.

The stock device ships OpenSSL 0.9.8e: TLS 1.0 at best, no ECDHE, no AES-GCM,
no SNI. Modern servers require TLS 1.2/1.3 with ECDHE and an AEAD cipher, so
there is no overlap and connections die at ClientHello. No certificate work
fixes that.

These install to `/opt/handshake` and sit alongside the stock library rather
than replacing it.

Built by `tools/build-openssl.sh` and `tools/build-stunnel.sh`; both run from
`tools/build-in-docker.sh`. Everything about how and why is in
[docs/BUILDLOG.md](../../docs/BUILDLOG.md) and
[docs/DECISIONS.md](../../docs/DECISIONS.md).
