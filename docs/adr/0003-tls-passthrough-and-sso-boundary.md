# Traefik passes TLS through; Authentik guards the console, not the API

Traefik must **not** terminate TLS in front of MeshLAN. Devices pin the control
plane certificate by sha256 fingerprint, so any proxy that presents its own
certificate breaks every paired device at once. Authentik belongs in front of
the human-facing console (`/admin`), never in front of the device and node API.

## Status

proposed (awaiting a real deployment to confirm)

## Context

MeshLAN speaks HTTP over a **self-signed** certificate at the pairing port (8090
by default, `state.TLSCertificatePEM`). Two separate trust models meet at that
listener:

- **Devices** (Windows/Mac clients) do not use the system trust store. They call
  `pinnedTLSConfig(payload.Pin)` — `InsecureSkipVerify: true` plus a
  `VerifyConnection` that (a) requires **exactly one** certificate in the chain
  (`len(connection.PeerCertificates) != 1` → "配对服务证书链异常") and (b)
  constant-time compares `sha256(PeerCertificates[0].Raw)` against the pin baked
  into the `MLN1…` pairing hash. `cmd/meshlan/paircode.go:170`
- **Nodes** do the same on `/v1/node/*` via `pinnedTLSConfig(node.ControlPin)`,
  which the Lighthouse recorded when the node was added. `cmd/meshlan/multinode.go`

Consequently a certificate-swapping proxy (Traefik with `tls: true`, any
terminating ingress, a CDN) makes `VerifyConnection` fail with "配对服务证书指纹
不匹配" on **every** request: pairing, heartbeat, node health polling, enrollment.
The failure is total, not partial, and it looks like a network outage.

The second constraint is about **who authenticates**. The console at `GET /admin`
is a single self-contained HTML file (`cmd/meshlan/admin/index.html`, ~47 KB, no
external assets) that calls `/v1/admin/auth-info`, `/v1/admin/session`,
`/v1/admin/session/revoke` **same-origin**. Its own auth is the admin token
(`X-MeshLAN-Admin-Token`) exchanged for a short-lived session
(`X-MeshLAN-Admin-Session`), issued by `POST /v1/admin/session`.

The device and node API is machine-to-machine: `Authorization: MeshLAN-Device
<name>:<token>`, `Authorization: MeshLAN <secret>` +
`X-MeshLAN-Enrollment: <id>`, `Authorization: MeshLAN-Node <id>:<secret>`. None
of them carry cookies, and none of them can complete an interactive login. An
SSO gateway in front of those routes would answer 302 to a login page, which the
clients treat as a malformed response.

Third detail that matters for routing: **one listener serves both** the console
and the API. `server serve` calls `tls.Listen` once on `state.PairingPort` and
muxes `/admin`, `/assets/`, `/download/` and `/v1/` onto it
(`cmd/meshlan/server.go:663`). There is no separate port to firewall differently
— if a request reaches MeshLAN at all, it reaches the API too.

## Considered Options

- **Traefik in TCP pass-through mode (SNI router, no `tls:`)** and Authentik only
  on `/admin` — the shape this ADR proposes. TLS stays end-to-end to MeshLAN, so
  the pin holds; the console gets SSO in front of it.
- **Traefik with TLS termination + `serversTransport.insecureSkipVerify`** —
  rejected. It solves the proxy→backend leg but not the client→proxy leg; the
  client still sees Traefik's certificate and the pin still fails.
- **Re-issue the control-plane certificate so Traefik and MeshLAN share it** —
  rejected. The certificate's private key lives encrypted in the state root
  (`cmd/meshlan/server_secret_store.go`), rotating it changes the pin, and every
  already-paired device would have to be re-paired by hand. It also hands the
  control-plane key to the proxy.
- **Put Authentik in front of everything, including `/v1/*`** — rejected. It
  breaks exactly the machine-to-machine calls that have no browser in the loop.
- **Expose MeshLAN only on the LAN and skip the proxy** — viable but not what is
  being asked; documented as the simplest alternative.

## Consequences

- Traefik uses a **TCP router** (`HostSNI` when devices connect by hostname, or a
  plain TCP router when they connect by IP). MeshLAN keeps its own certificate;
  no `tls:` block, no cert resolver, no `insecureSkipVerify` on that router.
- The routing hostname must **match the endpoint written into state at init**
  (or at least be irrelevant): devices connect to the IP/host recorded in the
  pairing payload but validate only the fingerprint, so the SAN is not checked.
  Changing the public hostname later does not require re-pairing — changing the
  **certificate** does.
- Authentik sits in front of `/admin` only. Because the console is same-origin
  and calls `/v1/admin/*` from the browser, the API paths it uses must be
  **excluded from the SSO forward-auth** while still being reachable: the browser
  already proved who it is to Authentik, but MeshLAN's own admin token/session is
  still required and is the actual authorisation boundary.
- `/v1/pair`, `/v1/heartbeat`, `/v1/node/*`, `/download/*` must never be behind
  forward-auth.
- Anything that rewrites `X-Forwarded-*` is harmless: the server never reads
  those headers (only the Windows gateway sets them outbound).
- The Nebula data plane (UDP 4242) does not go through Traefik at all, and must
  stay directly reachable on the same 1:1 port the endpoint advertises.

## Not verified

No real Traefik + Authentik deployment was run while writing this. The two
claims above are read from code (`paircode.go`, `multinode.go`, `server.go`,
`admin/index.html`); the pass-through and forward-auth shape is standard Traefik
behaviour but has not been exercised against this server.
