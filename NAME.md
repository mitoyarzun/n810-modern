# Name

**Handshake.**

The device can still reach the network. It can still resolve DNS, open a socket,
and send bytes. What it cannot do is complete a TLS handshake with anything
built after about 2013 — the conversation ends at ClientHello, before
certificates are ever discussed. One missing handshake is the entire problem.

The name is also the shape of the fix: we are not modernising the N810, not
porting a distro, not rewriting Maemo. We are restoring one exchange.

Provisional. It beat:

| Candidate | Why not |
| --- | --- |
| `diablo-tls` | Accurate and inert. Names the layer, not the problem. |
| `dragoman` | A dragoman interprets for travellers in a foreign land — exactly right, and two syllables too pleased with itself. |
| `lazarus` | Resurrection framing oversells it. Nothing here is dead; one library is old. |
| `n810-openssl` | Too narrow. OpenSSL is the first package, not the project. |
