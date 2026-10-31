<div align="center">
  <img src="cmd/meshlan/assets/meshlan-icon.png" width="96" alt="MeshLAN logo">
  <h1>MeshLAN</h1>
  <p><a href="README.md">简体中文</a> · <strong>English</strong> · <a href="README.ja.md">日本語</a></p>
  <p><strong>A self-hosted, P2P-first virtual LAN and local-service collaboration platform with Relay fallback</strong></p>
  <p>
    <img alt="Go" src="https://img.shields.io/badge/Go-1.26-00ADD8?logo=go&logoColor=white">
    <img alt="Nebula" src="https://img.shields.io/badge/Nebula-1.11-315C77">
    <img alt="Windows client" src="https://img.shields.io/badge/Client-Windows-0078D4?logo=windows">
    <img alt="Linux server" src="https://img.shields.io/badge/Server-Linux-FCC624?logo=linux&logoColor=111">
    <img alt="License" src="https://img.shields.io/badge/License-MIT-2E7D65">
  </p>
</div>

MeshLAN extends [SlackHQ Nebula](https://github.com/slackhq/nebula) with automatic enrollment,
P2P/NAT optimization, multiple Lighthouse/Relay nodes, TCP/UDP service mapping, MeshDNS,
direct file transfer, access approval, live topology, local history, secure updates, and optional
AI automation. Windows users run a portable native client, while your own Linux hosts provide the
control plane and optional relay capacity.

> This repository contains the complete source code for the Windows client, Linux main server,
> and Linux child nodes. Screenshots come from the real native client; device identifiers, IP
> addresses, domains, and public endpoints have been redacted.

## Screenshots

### Live network topology

![MeshLAN real-time topology](docs/screenshots/topology.png)

### History and replay

![MeshLAN history and replay](docs/screenshots/history.png)

### AI assistant

![MeshLAN AI assistant](docs/screenshots/ai-assistant.png)

## Core capabilities

- **Virtual LAN:** connect remote Windows devices through Nebula v2 certificates and encrypted tunnels.
- **P2P first:** dual-stack hole punching, stable UDP ports, UPnP, STUN diagnostics, and Route Guard.
- **Relay fallback:** switch automatically when direct connectivity fails and select the healthiest node.
- **Multi-node control plane:** manage Linux child Lighthouse/Relay nodes with health checks and failover.
- **Service mapping:** publish `localhost` TCP/UDP services with custom ports, pause, and health checks.
- **Access approval:** allow direct access or require the service owner to approve each member.
- **MeshDNS:** use stable names such as `alice.mesh` and `api.alice.mesh` instead of memorizing IPs.
- **HTTPS gateway:** issue local certificates for `.mesh` HTTP services and provide portless access.
- **Direct file transfer:** file contents travel through the encrypted device-to-device path.
- **Live observability:** inspect topology, P2P/Relay paths, underlay, latency, traffic, and service health.
- **Per-user token accounting:** accumulate input, output, cached, and reasoning tokens from reported model `usage` without reading conversation content.
- **History and replay:** keep traffic, path, connection, and event history in local SQLite storage.
- **AI assistant:** keep model credentials on the server and require confirmation before every mutation.
- **Secure updates:** Ed25519 manifests, SHA-256 verification, health checks, and automatic rollback.
- **Localized interface and AI:** switch instantly among Simplified Chinese, Traditional Chinese, English, and Japanese; AI replies follow the same language and the choice persists locally.

## Turn remote devices into one LAN

MeshLAN is not limited to publishing a single API. It joins Windows devices behind different ISPs,
NATs, and physical locations into one encrypted LAN. Each device receives a stable Mesh IP, while
the existing home or office network and default gateway remain unchanged.

- Encrypted P2P is preferred; Relay is used only when hole punching cannot establish a direct path.
- Each device can use IPv4, IPv6, or smart dual stack.
- Route Guard prevents global proxies and TUN adapters from hijacking the MeshLAN transport path.
- The topology view shows online devices, real P2P/Relay paths, latency, traffic, and link changes.
- Devices automatically re-register and reconnect after roaming, reconnecting, or endpoint changes.
- Existing protocols such as ping, RDP, SMB, databases, game servers, and custom APIs continue to work.

```text
Windows A ── encrypted P2P ── Windows B
    │                              │
10.77.0.2                      10.77.0.3
    └──── Relay fallback (only when required) ────┘
```

The control server handles enrollment, certificates, and discovery metadata. It does not proxy
ordinary P2P traffic. Even when Relay is required, the relay only sees Nebula-encrypted packets.

## MeshDNS: reach devices and services by name

MeshDNS gives every user/device an editable, unique prefix and generates records from live device
and service state. No per-machine `hosts` file is required.

If a device prefix is `alice`:

| Target | MeshDNS name | Example use |
|---|---|---|
| Device | `alice.mesh` | ping, RDP, SMB, or any other protocol |
| HTTP service | `chat.alice.mesh` | portless access through the local gateway |
| TCP service | `db.alice.mesh:5432` | database, API, or custom TCP protocol |
| UDP service | `game.alice.mesh:27015` | game server or another UDP service |

Users can change their own device prefix and the third-level prefix of every published service.
Creating, editing, pausing, or deleting a mapping updates both the shared service directory and
MeshDNS records from current state. Name conflicts are rejected before saving. Only HTTP/HTTPS
gateway mode can omit the port; normal TCP/UDP services still use their mapped port.

## Service mapping: share localhost without exposing the Internet

Many development tools listen only on `localhost`, including local APIs, dashboards, databases,
and game servers. MeshLAN publishes them to the encrypted virtual LAN without router port forwarding
or a public Internet listener.

To create a mapping, choose:

1. a service name, such as `Chat API`;
2. a local host and port, such as `localhost` and `4571`;
3. TCP or UDP;
4. an automatically assigned or custom Mesh port;
5. a MeshDNS service prefix, such as `chat`;
6. direct access or owner approval.

Members see the owner, service name, protocol, health, address, and port in the live shared-service
directory. For example, `localhost:4571` can become:

```text
http://chat.alice.mesh
# or standard port mode
chat.alice.mesh:20000
```

Each member may publish multiple TCP and UDP mappings. Port conflicts are reported before creation.
Owners can pause a whole mapping, pause one approved user, inspect current connections and traffic,
and resume access later. Approval-required services create a message that the owner can accept or
reject. Everyone can browse the directory, but users can modify only mappings they created.

```text
peer request
    │
    ▼
chat.alice.mesh:20000
    │  MeshDNS + access policy
    ▼
alice (10.77.0.2)
    │  local encrypted forwarding
    ▼
localhost:4571
```

## Architecture

```mermaid
flowchart LR
  subgraph Endpoints[Windows endpoints]
    A[Windows Client A\nWebView2 + Nebula]
    B[Windows Client B\nWebView2 + Nebula]
    C[Windows Client C\nWebView2 + Nebula]
  end

  subgraph Control[Self-hosted control plane]
    M[Main Linux Server\nEnrollment + Admin + Lighthouse + Relay]
    N1[Linux Child Node\nLighthouse + Relay]
    N2[Linux Child Node\nLighthouse + Relay]
  end

  A <-->|preferred encrypted P2P| B
  B <-->|preferred encrypted P2P| C
  A -.->|discovery / heartbeat| M
  B -.->|discovery / heartbeat| M
  C -.->|discovery / heartbeat| M
  M <-->|health + signed revocations| N1
  M <-->|health + signed revocations| N2
  A -.->|fallback relay| N1
  C -.->|fallback relay| M
```

| Component | Platform | Responsibility |
|---|---|---|
| Windows Client | Windows 10/11 | Native UI, enrollment, Nebula service, Route Guard, service mapping, MeshDNS, file transfer, AI assistant |
| Main Server | Linux amd64/arm64 | Admin console, authorization, certificates, revocation, updates, main Lighthouse/Relay, AI provider |
| Child Node | Linux amd64/arm64 | Additional Lighthouse/Relay, health reporting, revocation sync, and failover |

## Technology stack

| Layer | Technology |
|---|---|
| Language | Go 1.26, PowerShell, Bash, and vanilla JavaScript |
| Overlay | SlackHQ Nebula 1.11, Noise handshake, v2 certificates, Lighthouse/Relay/Punchy |
| Windows UI | Native WebView2 window with embedded HTML/CSS/JavaScript and no external frontend CDN |
| Visualization | SVG topology, live throughput, and dual-layer history charts |
| Persistence | SQLite WAL, JSON state, and Windows DPAPI |
| Cryptography | TLS 1.3 pinning, X25519, AES-256-GCM, Ed25519, and SHA-256 |
| Windows integration | SCM, IP Helper API, WFP, Task Scheduler, native routes, and certificate store |
| Linux integration | systemd, `LoadCredential`, file permissions, and atomic upgrades |
| AI | OpenAI-compatible Chat Completions, SSE streaming, and a server-side tool allowlist |
| CI | GitHub Actions tests, vet, and multi-platform builds |

## Repository layout

```text
.
├── cmd/meshlan/               # MeshLAN executable source
│   ├── admin/                 # Linux main-server admin console
│   ├── assets/                # Icons and Windows manifests
│   ├── deploy/                # Linux child-node scripts and systemd files
│   ├── web/                   # Windows client UI
│   ├── *_windows.go           # Windows client and OS integration
│   ├── server.go              # Main server and admin API
│   ├── node_agent.go          # Linux child node
│   ├── multinode.go           # Multi-Lighthouse/Relay management
│   └── ai_*.go                # AI encryption, streaming, sessions, and tools
├── docs/                      # Documentation and redacted screenshots
├── tools/                     # Diagnostic scripts
├── build.ps1                  # Tests and cross-platform builds
└── VERSION
```

## Quick start

### Requirements

- Go 1.26+
- Windows 10/11 for building and running the client
- Microsoft Edge WebView2 Runtime
- Nebula and `nebula-cert` 1.11.x
- A Linux host for the main server and optional child nodes

### Build every component

```powershell
git clone https://github.com/zhaoxuya520/MeshLAN.git
cd MeshLAN
.\build.ps1
```

Artifacts are written to `dist/`:

```text
MeshLAN-Nebula-Windows.exe
meshlan-nebula-server-linux-amd64
meshlan-nebula-server-linux-arm64
meshlan-nebula-node-linux-amd64
meshlan-nebula-node-linux-arm64
SHA256SUMS.txt
```

**You do not need a Windows machine to build the client.** `cmd/meshlan` is pure Go with
`CGO_ENABLED=0` by default, so it cross-compiles from Linux/macOS:

```bash
VERSION="$(cat VERSION)"
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath \
  -ldflags "-s -w -H=windowsgui -X main.clientVersion=meshlan-nebula/$VERSION" \
  -o dist/MeshLAN-Nebula-Windows.exe ./cmd/meshlan
```

The result is a PE32+ / amd64 / **GUI-subsystem** binary (not a console program), about 15 MB.

> **This repo publishes no GitHub releases** (only a tag), and `dist/` is not committed. A ready-made
> exe therefore comes from `build.ps1` or from a CI artifact in Actions (downloadable per commit,
> subject to expiry).

### Initialize the main server

Replace the example addresses, ports, and paths:

```bash
sudo install -d -m 0700 /etc/meshlan-nebula
sudo install -m 0755 meshlan-nebula-server-linux-arm64 /usr/local/bin/meshlan-nebula
sudo install -d -m 0755 /dev/net
sudo mknod /dev/net/tun c 10 200 2>/dev/null || true

sudo /usr/local/bin/meshlan-nebula server init \
  -state /etc/meshlan-nebula/server-state.json \
  -endpoint 203.0.113.10:4242 \
  -subnet 10.77.0.0/24 \
  -nebula-port 4242 \
  -pairing-port 8443 \
  -nebula /usr/local/bin/nebula \
  -nebula-cert /usr/local/bin/nebula-cert
```

The init command displays the pairing hash and admin token once. Save them in a password manager,
then run `server serve` under systemd. Allow the configured Nebula UDP port and pairing/admin HTTPS
port through the firewall. Nebula also needs a tun device: run `server serve` as root (or with
`CAP_NET_ADMIN`) on a host that has `/dev/net/tun`, otherwise it exits when Nebula fails to start. The
tun device name is fixed at `meshlan-lh` (15 bytes, the kernel `IFNAMSIZ-1` limit). Production
deployments should use a valid domain certificate, a dedicated
systemd user, `LoadCredential`, minimal firewall rules, and offline backups.

### Run the Windows client

```powershell
.\dist\MeshLAN-Nebula-Windows.exe
```

On first run, enter the device name, the main server address, and an `MLN1...` one-time enrollment
hash. The client generates its Nebula private key locally and installs the `Nebula` Windows service.
Closing the desktop window does not disconnect the virtual network.

The client is a `windowsgui` binary, so no console window appears at startup. Its own output
(startup notices, errors, and anything the standard `log` package writes) all goes to
`client\logs\meshlan-client.log` in the runtime directory above. The file rotates at 2 MB and
keeps the active file plus two generations (`.1`, `.2`). Launching it from `cmd.exe` keeps that
shell's console: MeshLAN does not close a window it does not own. Settings can open the log file
directly, and `client\log-rotation.json` (`directory` / `filename` / `maxBytes` / `maxBackups`)
overrides where it lives and how large it may grow.

#### Runtime directory (where `nebula.exe` goes)

**Do not** put `nebula.exe` next to `MeshLAN-Nebula-Windows.exe`. The location is hard-coded and
independent of where the exe lives (`cmd/meshlan/client_windows.go:1970`):

```text
%APPDATA%\MeshLANNebula\        <- appRoot() = os.UserConfigDir()/MeshLANNebula
├── client\                     <- client state; deleting it resets the client (re-pair needed)
│   ├── client-state.json
│   ├── history.sqlite
│   ├── host.key / host.pub / host.crt / ca.crt   <- created after pairing
│   ├── config.yml              <- the rendered nebula config
│   ├── logs\                   <- client log; output goes to the file, never to a console window
│   │   ├── meshlan-client.log      <- active log, rotated at 2 MB
│   │   └── meshlan-client.log.1 / .2 <- the two retained generations
│   └── (file-shares.json, shares\, updates\, apply-update.ps1, ...)
├── native-webview2\EBWebView\  <- WebView2 cache; safe to delete, rebuilt automatically
└── runtime\
    └── nebula-v1.11.0\         <- runtimeDir = root/runtime/nebula-v<version>
        ├── nebula.exe          <- required
        ├── nebula-cert.exe     <- required
        └── dist\windows\wintun\
            └── bin\amd64\wintun.dll   <- required (nebula.exe loads it at runtime)
```

`ensureNebulaRuntime` skips the download only when **both** files are present; dropping in
`nebula.exe` alone still triggers a re-download.

**First run needs GitHub**: the client downloads
`https://github.com/slackhq/nebula/releases/download/v1.11.0/nebula-windows-amd64.zip`
and verifies its SHA-256 (`dc6b144bd852b5a17fc0c9283d96e6309fd918c9e8f385fab256da6dfdd42232`).
Behind a proxy or on an isolated network the download fails with
"Nebula download interrupted repeatedly; check proxy or network".

#### Offline deployment (many clients, no internet)

Fetch the official zip once on a machine with internet, verify it, and lay it out as above —
the client then skips the download:

```powershell
# 1) Verify (must match the SHA-256 above, or the client refuses the package)
Get-FileHash .\nebula-windows-amd64.zip -Algorithm SHA256

# 2) Lay it out at the fixed location (Expand-Archive also unpacks dist\, which is what we need)
$dst = "$env:APPDATA\MeshLANNebula\runtime\nebula-v1.11.0"
New-Item -ItemType Directory -Force -Path $dst | Out-Null
Expand-Archive .\nebula-windows-amd64.zip -DestinationPath $dst -Force

# 3) Confirm the three required files exist
Test-Path "$dst\nebula.exe"
Test-Path "$dst\nebula-cert.exe"
Test-Path "$dst\dist\windows\wintun\bin\amd64\wintun.dll"
```

The other architectures under `dist\windows\wintun\` (`arm`, `arm64`, `x86`) plus `include\`,
`README.md` and `LICENSE.txt` can be deleted; **`bin\amd64\wintun.dll` must stay** — nebula.exe
loads it from its own directory at runtime. `native-webview2\EBWebView\` is Edge's engine
cache, not program data, and is safe to delete (it is recreated on next start).

### Add a Linux child node

```bash
export MESHLAN_RELEASE_BASE_URL=https://your-meshlan.example
curl -fsSL "$MESHLAN_RELEASE_BASE_URL/download/node/install.sh" -o /tmp/install-mesh-node.sh
sudo -E bash /tmp/install-mesh-node.sh --endpoint 198.51.100.20 --name edge-01
```

The script prints an `MLNODE1...` enrollment hash. Add the node address and hash in the main
server's multi-node page.

## Running it in a container (Docker / Podman)

> The image is built locally and **never pushed to any registry**. Definitions: `Dockerfile`,
> `docker-compose.yml`, `.dockerignore`, `docker/entrypoint.sh`.

One image, one role per container (`MESHLAN_ROLE=lighthouse|node`). **Relay is a capability of a
Lighthouse, not a third role**, so there is no "relay service" in the compose file.

```bash
# One address is required, and that is all: the entrypoint appends the port per role.
MESHLAN_IP=203.0.113.10 docker compose up -d --build
```

Prefer an interactive setup? It asks a few questions, writes `.env`, prepares the state directory and
validates the compose file before starting anything:

```bash
docker/bootstrap.sh
```

The first start signs the CA and both identities, then starts Nebula. All state lands in the **bind
mount** `./meshlan-state` (override with `MESHLAN_STATE_DIR`) at `/var/lib/meshlan` (Node uses
`/var/lib/meshlan/node` inside the same directory). A bind mount rather than a named volume, so that
"backup = archive one directory" actually holds.

**The directory is the identity and the master key. Deleting it rebuilds the whole PKI and every paired
device is lost for good.** Upgrading is just `docker compose up -d --build`; recreating the container
keeps the CA fingerprint, the pairing codes and the history database.

**First start**

- With no `MESHLAN_IP` (the legacy `MESHLAN_PUBLIC_ENDPOINT` also works) the container exits non-zero
  immediately and prints one copyable command. It does **not** guess localhost and does **not** probe
  the egress address.
- That address is written into the state at init time and there is no command to change it:
  **get it wrong and the only way back is deleting the state directory and rebuilding the PKI.**
- Initialisation is idempotent on one criterion only: does this role's state file exist. If the state
  file is missing while init material (`ca.key` and friends) is already there, the entrypoint refuses
  with "the previous init did not finish" instead of silently re-running (`nebula-cert`'s `ca`/`sign`
  refuse to overwrite).
- Init only, no service: `MESHLAN_INIT_ONLY=1`.

**One-time credentials**

The pairing hash and admin token (Node gets an `MLNODE1…` hash) are printed once at init and also
written to `first-credentials.txt` in the state root (`0600`, inside the volume, never auto-deleted):

```bash
docker compose exec lighthouse cat /var/lib/meshlan/first-credentials.txt
```

**Do not pipe the init phase's stdout into a persistent log sink**: `server init` writes a plaintext
`ca.key` before encrypting it, so that short window can leak a private key. The compose file rotates its
logs, which lowers the exposure but does not replace this rule.

To regenerate (the old value dies immediately; already-paired devices are unaffected):

```bash
docker compose exec lighthouse meshlan server admin-token -state /var/lib/meshlan/server-state.json
docker compose exec lighthouse meshlan server pairing -state /var/lib/meshlan/server-state.json
```

**Ports, capabilities, health**

| Role | Ports (host:container, 1:1) | Health check |
| --- | --- | --- |
| Lighthouse | `8090/tcp`, `4242/udp` | `GET /v1/admin/auth-info`, 200 with a JSON `Content-Type` |
| Node | `18090/tcp`, `14242/udp` | `GET /v1/node/health`, 200 with parseable JSON |

**Ports are always 1:1; never translate them.** The Nebula endpoint a Node advertises and the control
port in its pairing payload are used verbatim by the Lighthouse, so a translated mapping points devices
at the wrong port.

No root, no `privileged`, no kernel modules — but Nebula needs two things: the `/dev/net/tun` device node
and the `NET_ADMIN` capability. A non-root process also needs a file capability on the binary, so the
entrypoint `setcap`s it and `setpriv`s down to uid/gid 10001 (the state directory does not belong to
10001 on first creation, so the entrypoint chowns it first — with a bind mount that changes the host
directory's owner, which is intended).

**The blind spot of the health check**: `healthy` means the control plane is listening. It does not mean
Nebula is up, and it does not mean pairing works. The probe uses unauthenticated endpoints, accepts the
self-signed certificate (`curl -k`) and does not verify the certificate chain.

**Stop, backup, upgrade**

- `stop_grace_period: 30s`. **Do not assert exit codes**: the container init is protected by the kernel's
  `SIGNAL_UNKILLABLE`, so SIGTERM never reaches the server and 143/137 are not criteria; a 137 means the
  grace period was too short. See `docs/adr/0001-no-graceful-shutdown-in-container.md`.
- Backups are **cold**: stop the container, copy the whole state directory, and include SQLite's WAL side
  files.
- External master key (optional, advanced): point `MESHLAN_MASTER_KEY_FILE` at a platform secret and
  **every subcommand must then also pass `-state` explicitly**, or it will look at the wrong default path
  and miss the key. Subcommands inside the container:

```bash
docker compose exec lighthouse meshlan server list -state /var/lib/meshlan/server-state.json
```

**Node role**

```bash
# A Node reuses MESHLAN_IP by default; set MESHLAN_NODE_IP when it lives elsewhere.
MESHLAN_IP=203.0.113.10 MESHLAN_NODE_IP=198.51.100.20 \
  docker compose --profile node up -d --build
```

The profile name is `node` (never `relay`). A Node shares the state directory with the Lighthouse but keeps
its identity in a subdirectory; take the `MLNODE1…` hash from `first-credentials.txt` and add the node on
the Lighthouse's multi-node admin page.

## AI assistant

AI is optional. Administrators can configure any OpenAI-compatible HTTPS endpoint and model. The
model API key remains encrypted on the main server and is never distributed to clients. Client and
server derive X25519 session keys and use AES-256-GCM for requests and streaming results. AI tools
are allowlisted, and every modifying operation requires explicit user confirmation.

## Security and privacy

- Device private keys are generated on endpoints and never uploaded to the control server.
- One-time enrollment hashes bind the device name and public key.
- Server CA, TLS, signing, TOTP, and AI credentials use AES-256-GCM envelope encryption.
- Windows device tokens are protected with the current user's DPAPI.
- Revocation lists and update manifests are signed with an independent Ed25519 key.
- Updates verify signatures, length, and SHA-256, with health checks and rollback.
- The local management API listens only on `127.0.0.1`.
- Ordinary P2P traffic and file contents do not pass through the control plane.
- Relay nodes forward only Nebula-encrypted packets.
- Local history records metadata, not application payload contents.

Read [SECURITY.md](SECURITY.md) before deploying. Self-hosting still requires operating-system
updates, firewall policy, secure administrator devices, backups, and code-signing practices.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Contributions for Windows/IPv6/NAT compatibility,
multi-Relay selection, Linux deployment, accessibility, localization, documentation, testing, and
security review are welcome.

## License

[MIT License](LICENSE)

## Acknowledgements

- [SlackHQ Nebula](https://github.com/slackhq/nebula)
- [WebView2](https://developer.microsoft.com/microsoft-edge/webview2/)
- [modernc.org/sqlite](https://pkg.go.dev/modernc.org/sqlite)
