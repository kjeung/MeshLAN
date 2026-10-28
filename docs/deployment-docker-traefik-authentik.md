# MeshLAN 容器部署手册

面向自托管运维者：在一台 Linux 主机上用 Docker Compose 拉起 MeshLAN 的
**Lighthouse**（控制面）与可选的 **Node**（第二座灯塔），并在前面接
**Traefik**（动态配置）与 **Authentik**（管理台 SSO）。

> 读这一页之前先读两条硬约束，它们不是建议，是这套软件当前的实现决定的。

---

## 0. 两条硬约束

### 0.1 Traefik 只能透传 TLS，不能终止

设备（Windows/Mac 客户端）连接控制面时**不做证书链校验，只比对指纹**：

```
VerifyConnection:
  len(PeerCertificates) != 1        → "配对服务证书链异常"
  sha256(PeerCertificates[0].Raw) != pin → "配对服务证书指纹不匹配"
```

（`cmd/meshlan/paircode.go:170`，Node 走同一函数、用 Lighthouse 记录的 `ControlPin`。）

所以任何**换掉证书**的中间层——Traefik 的 `tls:`、任何 terminating ingress、CDN——
都会让**所有已配对设备**同时连不上，症状看起来像网络故障。Traefik 必须做
**TCP 透传**，TLS 端到端打到 MeshLAN 自己。

### 0.2 Authentik 只能保护管理台，不能保护 API

- 管理台 `GET /admin` 是**自包含**的同源页面（`cmd/meshlan/admin/index.html`，约 47 KB，
  无外部资源），只 `fetch` 三个同源路径：`/v1/admin/auth-info`、`/v1/admin/session`、
  `/v1/admin/session/revoke`。
- 设备与节点 API 是**机器对机器**，凭据分别是 `Authorization: MeshLAN-Device <name>:<token>`、
  `Authorization: MeshLAN <secret>` + `X-MeshLAN-Enrollment: <id>`、
  `Authorization: MeshLAN-Node <id>:<secret>`。它们没有 cookie，也无法完成交互式登录。

把 SSO 挡在这些路径前面 → 客户端收到 302 登录页 → 配对、心跳、节点探活全部失败。

**一个端口同时服务管理台和 API**（`server serve` 只在 `state.PairingPort` 上 `tls.Listen` 一次，
`cmd/meshlan/server.go:663`），所以不能靠「另开一个端口只给 API」来绕开——路由必须在
Traefik 层按路径分。

决策理由与备选方案见 `docs/adr/0003-tls-passthrough-and-sso-boundary.md`。

---

## 1. 前置条件

| 项目 | 要求 |
| --- | --- |
| 主机 | Linux x86_64（arm64 可构建，未实跑） |
| 内核 | 有 `/dev/net/tun`（`ls -l /dev/net/tun` 应存在） |
| Docker | Engine 24+ 与 Compose v2 |
| 端口 | 8090/tcp、4242/udp（Lighthouse）；18090/tcp、14242/udp（Node，可选） |
| 公网地址 | 一个能写进状态的地址：Lighthouse 要 `host:4242`，Node 要**纯主机** |
| 磁盘 | 镜像约 272 MB + 状态卷 |

检查：

```bash
ls -l /dev/net/tun
docker version --format '{{.Server.Version}}'
docker compose version --short
ss -lntup | grep -E '8090|4242|18090|14242' || echo "端口空闲"
```

---

## 2. 取代码并构建

```bash
git clone https://github.com/kjeung/MeshLAN.git
cd MeshLAN
docker compose build
```

镜像在本地构建，**不向任何 registry 发布**。

验证：`docker images meshlan:local` 有记录；`docker run --rm --entrypoint /bin/sh meshlan:local \
-c 'ls /usr/local/bin/{meshlan,nebula,nebula-cert,meshlan-entrypoint}'` 四个都在。

---

## 3. 第一件必做的事：**先想清楚公网地址**

初始化时地址被**写进状态**，仓库里**没有修改命令**。填错只能删卷重建 PKI，
所有已配对设备永久失联。

| 角色 | 形状 | 例子 | 说明 |
| --- | --- | --- | --- |
| Lighthouse | `host:nebulaPort` | `203.0.113.10:4242` | 端口必填；服务把它原样存进状态、原样下发当客户端 `static_host_map` |
| Node | **纯主机** | `198.51.100.20` | `node-init` 自己拼两次（对外端点 `host:nebulaPort`、控制端点 `host:controlPort`） |

IPv6 写成 `[addr]:port`。**不要填 localhost**，也不要用占位符——不猜、不探测出口地址是刻意设计。

---

## 4. 首次启动 Lighthouse

```bash
MESHLAN_PUBLIC_ENDPOINT=203.0.113.10:4242 docker compose up -d
```

首次启动会：签发 CA 与 Lighthouse 证书 → 打开历史库 → 拉起 Nebula → 监听 TLS。

等待健康转绿（冷启动有 30 s 宽限）：

```bash
docker compose ps            # STATUS 应出现 (healthy)
```

验证控制面：

```bash
curl -kfsS -o /dev/null -w '%{content_type}\n' \
  https://127.0.0.1:8090/v1/admin/auth-info    # 期望 application/json
```

### 4.1 取一次性凭据

配对哈希与管理令牌只在初始化时打印一次，同时落盘到状态卷内（`0600`）：

```bash
docker compose exec lighthouse cat /var/lib/meshlan/first-credentials.txt
```

拿到两样东西：

- `配对哈希: MLN1…` —— 给设备/节点配对用
- `管理令牌: …` —— 登录管理台用

> **初始化阶段的 stdout 不得接进持久日志系统**：`server init` 会先落明文 `ca.key`，
> 随后才加密并删除，那一小段输出可能带出私钥。compose 已配日志轮转，但那只是降低
> 暴露面，不替代这条口径。

需要重新生成时（旧值立即失效，已配对设备不受影响）：

```bash
docker compose exec lighthouse meshlan server pairing -state /var/lib/meshlan/server-state.json
docker compose exec lighthouse meshlan server admin-token -state /var/lib/meshlan/server-state.json
```

---

## 5. 可选：加一台 Node

Node 与 Lighthouse **共用同一命名卷**，但身份分目录（`/var/lib/meshlan/node`）。

```bash
MESHLAN_PUBLIC_ENDPOINT=203.0.113.10:4242 \
MESHLAN_NODE_PUBLIC_ENDPOINT=198.51.100.20 \
MESHLAN_NODE_NEBULA_PORT=14242 \
  docker compose --profile node up -d node
```

取 Node 的哈希：

```bash
docker compose exec node cat /var/lib/meshlan/node/first-credentials.txt   # 子节点哈希: MLNODE1…
```

### 5.1 在主控上加节点（可纯 API，适合自动化）

同主机部署时，主控需要能连到 Node 发布的 `18090/tcp`。**compose 服务名只在同一
compose 网络内可解析**，那不是「真的通」；用宿主网关别名：

```bash
# 1) 管理令牌换会话
SESSION=$(curl -kfsS -X POST \
  -H "X-MeshLAN-Admin-Token: <管理令牌>" \
  -H 'Content-Type: application/json' -d '{}' \
  https://127.0.0.1:8090/v1/admin/session | jq -r .sessionToken)

# 2) 加节点（endpoint 是主控视角下 Node 的地址）
curl -kfsS -X POST \
  -H "X-MeshLAN-Admin-Session: $SESSION" \
  -H 'Content-Type: application/json' \
  -d '{"endpoint":"host.docker.internal","hash":"MLNODE1…","name":"edge-01"}' \
  https://127.0.0.1:8090/v1/admin/nodes
```

要让 Lighthouse 容器解析得到 `host.docker.internal`，给它加（验收用的
`docker/acceptance.compose.yml` 就是这么做的）：

```yaml
services:
  lighthouse:
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

验证配对成功（三步都要过）：

```bash
# a) Node 侧：enrolled 与 nebulaRunning 都应为 true
curl -kfsS https://127.0.0.1:18090/v1/node/health | jq '{enrolled,nebulaRunning}'

# b) 主控侧：该节点 online 且 nebulaRunning
curl -kfsS -H "X-MeshLAN-Admin-Session: $SESSION" \
  https://127.0.0.1:8090/v1/admin/overview | jq '.nodes[] | {name,online,nebulaRunning}'
```

> 这条链路已由 `docker/acceptance.sh` 在真机上全绿验证（65/65）。

---

## 6. Traefik 动态配置

原则：**TCP 透传**。MeshLAN 自己出示并持有的证书不动。

### 6.1 前提

- Traefik 需要接触发器：`--providers.file.directory=/etc/traefik/dynamic`
- **不要**在 MeshLAN 的 router 上写 `tls:`、`certResolver`、`serversTransport`

### 6.2 场景 A：设备用**主机名**连接（推荐，可做 SNI 路由）

```yaml
# /etc/traefik/dynamic/meshlan.yml
tcp:
  routers:
    meshlan-ctrl:
      entryPoints: ["websecure"]
      rule: "HostSNI(`mesh.example.com`)"
      service: meshlan-ctrl
      # 注意：没有 tls: 段 —— 这段流量原样透传给后端
  services:
    meshlan-ctrl:
      loadBalancer:
        servers:
          - address: "10.0.0.10:8090"   # MeshLAN 宿主 IP:配对端口
```

**关键**：`HostSNI` 匹配需要真实的 TLS ClientHello，透传模式下可用。
若你的 Traefik 在 websecure 入口配了默认 certResolver，**要为这条 router 显式关闭**，
否则 Traefik 会自己握手。

### 6.3 场景 B：设备用 **IP** 连接（无 SNI）

设备如果连的是 IP，ClientHello 里没有 SNI，`HostSNI` 无法匹配。用纯 TCP router：

```yaml
tcp:
  routers:
    meshlan-ctrl:
      entryPoints: ["meshctrl"]      # 单独开一个 TCP 入口，端口如 8443
      rule: "HostSNI(`*`)"          # 兜底匹配所有
      service: meshlan-ctrl
  services:
    meshlan-ctrl:
      loadBalancer:
        servers:
          - address: "10.0.0.10:8090"
```

静态配置里加这个入口：

```yaml
# traefik.yml
entryPoints:
  meshctrl:
    address: ":8443/tcp"
```

### 6.4 不要做的事

```yaml
# ✗ 绝对不要：这会换掉证书，所有设备立刻掉线
tcp:
  routers:
    meshlan-ctrl:
      tls:
        certResolver: le
```

### 6.5 UDP（Nebula 数据面）

`4242/udp`（Node 是 `14242/udp`）**不进 Traefik**。它必须在同一端口上直接可达，
因为端点地址是初始化时写死的、且要求宿主 1:1 映射、禁止端口翻译。

```yaml
# docker-compose.yml 里必须保持 1:1
ports:
  - "4242:4242/udp"
```

防火墙放行 UDP 4242 即可，不需要也不应该经代理。

---

## 7. Authentik 接入

目标：**管理台 `/admin` 走 SSO**，其余路径不经 SSO。

### 7.1 必须放行（不经 forward-auth）的路径

| 路径 | 原因 |
| --- | --- |
| `/v1/pair` | 设备配对，凭 `Authorization: MeshLAN <secret>` |
| `/v1/heartbeat` | 设备心跳，凭 `MeshLAN-Device` |
| `/v1/node/*` | Node 的 info/enroll/health/revocations，凭 `MeshLAN-Node` |
| `/v1/admin/*` | 浏览器 `fetch` 的同源调用，鉴权由 MeshLAN 自己的 admin token/session 承担 |
| `/download/*` | 安装脚本与二进制，被安装脚本直接 `curl` |
| `/assets/*` | 管理台静态资源 |

> 为什么 `/v1/admin/*` 也要放行：管理台页面本身要在**登录前**调
> `/v1/admin/auth-info`（读 `totpRequired`）。若这一段被 SSO 拦，页面拿不到认证策略。
> MeshLAN 自己的 admin token 才是真正的授权边界；Authentik 在这里只做「人」的门禁，
> 不做「机器」的门禁。

### 7.2 Traefik 中间件：要按路径白名单

因为**一个端口同时服务管理台与 API**，forward-auth 不能整段挂在那个 router 上，
必须拆成两个 router（同一后端）：

```yaml
# /etc/traefik/dynamic/meshlan-http.yml   （仅在你不做 TLS 透传、改走 HTTP 时使用）
# 注意：HTTP 路由会绕过 MeshLAN 的 TLS —— 设备必须仍走 TCP 透传那条。
http:
  routers:
    # 管理台：走 SSO
    meshlan-console:
      entryPoints: ["websecure"]
      rule: "Host(`mesh.example.com`) && PathPrefix(`/admin`)"
      middlewares: ["authentik-forwardauth"]
      service: meshlan-console
      tls:
        certResolver: le            # 这一段 Traefik 自己的证书可以换，因为浏览器用系统信任
    # 机器调用：不经 SSO
    meshlan-api:
      entryPoints: ["websecure"]
      rule: "Host(`mesh.example.com`) && (PathPrefix(`/v1/`) || PathPrefix(`/download/`) || PathPrefix(`/assets/`))"
      service: meshlan-api
      tls:
        certResolver: le

  middlewares:
    authentik-forwardauth:
      forwardAuth:
        address: "http://authentik-server:9000/outpost.goauthentik.io/auth/traefik"
        trustForwardHeader: true
        authResponseHeaders:
          - X-authentik-username
          - X-authentik-groups
          - X-authentik-email
          - X-authentik-name
          - X-authentik-uid
          - X-authentik-jwt
          - X-authentik-meta-jwks
          - X-authentik-meta-outpost
          - X-authentik-meta-provider
          - X-authentik-meta-app
          - X-authentik-meta-version

  services:
    meshlan-console:
      loadBalancer:
        servers:
          - url: "https://10.0.0.10:8090"
        serversTransport: meshlan-selfsigned
    meshlan-api:
      loadBalancer:
        servers:
          - url: "https://10.0.0.10:8090"
        serversTransport: meshlan-selfsigned

  serversTransports:
    meshlan-selfsigned:
      insecureSkipVerify: true      # Traefik → MeshLAN 这一跳自签，跳过校验
```

> **这一段是「浏览器走 HTTP 路由」的可选形态**：它让管理台拿到受信任的证书、方便接 SSO。
> 但**设备用的控制连接不能走这里**——设备必须继续走第 6 节的 TCP 透传，否则指纹校验失败。
> 若你不想同时维护两套入口，**更简单的做法**见 7.4。

### 7.3 Authentik 侧要配的东西

1. **Provider**：选 *Proxy Provider*，模式 **Forward auth (single application)**。
   - External host：`https://mesh.example.com`
2. **Application**：绑定上面的 provider，slug 如 `meshlan`。
3. **Outpost**：把该 provider 挂到一个 *Proxy Outpost* 上（embedded 或独立容器）。
   - 独立容器的 outpost 路径即 `/outpost.goauthentik.io/auth/traefik`。
4. **Policy / Group**：给能登录管理台的组做绑定（例如 `meshlan-admins`）。
   未绑定策略的 application 默认对所有已认证用户开放，这通常不是你想要的。

### 7.4 更简单、也更贴近本软件设计的做法

Authentik 保护**管理台**，而管理台本身已经有一道 `管理令牌 + 可选 TOTP` 的门。
若你不想为路径白名单费心：

- Traefik **只**做第 6 节的 TCP 透传，不做任何 HTTP 路由；
- 管理台的访问控制靠 **MeshLAN 自己的 admin token**（够强：32 字节随机、会话短时、
  可开 TOTP）；
- 要加一道「人」的门，就把 `/admin` 的**外部可达性**收窄（只允许办公网/VPN 源 IP），
  或用 Authentik 的 **LDAP/反向代理到管理台前面的一层独立页面**——但**不要把 SSO
  挡在同源 `/v1/admin/*` 上**，理由见 7.1。

两种形态都成立，区别只是「SSO 落在哪一跳」。ADR-0003 记录了取舍。

---

## 8. 反向代理相关的实现细节（读码确认过）

| 事项 | 结论 |
| --- | --- |
| 服务端读 `X-Forwarded-*` 吗 | **不读**。只有 Windows 网关在**出站**时设置它们 |
| 管理台会用外部 CDN 吗 | **不会**。单个自包含 HTML，约 47 KB，无外链 |
| 管理台是 SPA 需要 history fallback 吗 | **不需要**。`GET /admin` 是独立路由 |
| API 走 cookie 吗 | **不走**。全部是 `Authorization` 头，天然免疫 CSRF |
| 能做源 IP 白名单吗 | 能，但注意所有设备共用同一个公网 IP 时无法区分设备 |
| 能改端口映射吗 | **不能**。1:1，禁翻译（Node 宣称的端点与配对载荷里的控制端口会被主控原样取用） |

---

## 9. 运维

### 9.1 停止

`stop_grace_period: 30s`。**不要对退出码断言**：容器 init 受内核 `SIGNAL_UNKILLABLE`
保护，SIGTERM 到不了服务进程，143/137 都不是判据；看到 137 应读作「宽限期不够」。
实测退出码恒为 **2**，停止耗时约 1 s。理由见 `docs/adr/0001-no-graceful-shutdown-in-container.md`。

### 9.2 备份（必须冷备）

```bash
docker compose stop
docker run --rm -v meshlan_meshlan-state:/src -v "$PWD/backup":/dst alpine \
  sh -c 'cd /src && tar czf /dst/meshlan-state-$(date +%F).tgz .'
docker compose start
```

必须**连同 SQLite 的 WAL 附属文件**一起（`history.sqlite-wal`、`-shm`）。

> **卷 = 身份 + 主密钥。删卷 = 重建整个 PKI，所有已配对设备永久失联。**

### 9.3 升级

```bash
git pull
docker compose build
docker compose up -d
```

重建容器**不会**改变 CA 指纹、配对码与历史库。

### 9.4 健康检查的盲区

`healthy` 只说明控制面在监听，**既不说明 Nebula 打通，也不说明能配对**。探针走免认证
端点并对自签证书放行（`curl -k`），不验证证书链。

### 9.5 验收脚本（部署后建议跑一次）

```bash
docker/acceptance.sh
```

覆盖构建 → 配置 → 双 profile 健康 → 身份跨 restart 与 `--force-recreate` 不变 →
四条 fail-fast → INIT_ONLY → Node 起得来 → **Node 真配对**，结束自清理。
它用独立项目名 `meshlan-acceptance`，会先探测端口与同名栈，命中即拒绝运行——
**不要在跑着真实部署的机器上直接跑**。

---

## 10. 故障排查

| 症状 | 先看这里 |
| --- | --- |
| 设备全部连不上，日志却正常 | Traefik 是否 terminate 了 TLS（违反 0.1） |
| 配对/心跳 302 到登录页 | SSO 误挡了 `/v1/*`（违反 0.2） |
| 容器起不来，提示缺地址 | `MESHLAN_PUBLIC_ENDPOINT` 未设；地址形状按角色（Lighthouse 带端口 / Node 纯主机） |
| 首次初始化后重启报「材料已存在」 | 上次初始化中途失败；需清空状态卷重来 |
| `healthy` 但设备配不上 | 正常现象，见 9.4；查 UDP 4242 与端点地址 |
| Node 加不进 | 主控到 Node `18090` 不通；同主机需 `host.docker.internal` 或宿主 IP |
| 容器内 Nebula 起不来 | `/dev/net/tun` 与 `NET_ADMIN` 是否给到（两样缺一不可） |
| 想改公网地址 | **做不到**，只能删卷重建 PKI；见第 3 节 |

---

## 附：环境变量速查

| 变量 | 角色 | 映射到 | 缺省 |
| --- | --- | --- | --- |
| `MESHLAN_ROLE` | 两者 | 入口分派 | 无，必填 `lighthouse` / `node` |
| `MESHLAN_PUBLIC_ENDPOINT` | Lighthouse | `-endpoint`，须 `host:4242` | 无，缺失即失败 |
| `MESHLAN_PUBLIC_ENDPOINT` | Node | `-endpoint`，须纯主机 | 无，缺失即失败 |
| `MESHLAN_NODE_PUBLIC_ENDPOINT` | Node（compose） | 同上 | 无 |
| `MESHLAN_SUBNET` | 仅 Lighthouse | `-subnet` | `10.77.0.0/24` |
| `MESHLAN_NEBULA_PORT` | 两者 | `-nebula-port` | Lighthouse `4242` / Node `14242` |
| `MESHLAN_PAIRING_PORT` | Lighthouse | `-pairing-port` | `8090` |
| `MESHLAN_NODE_PAIRING_PORT` | Node（compose） | `-control-port` | `18090` |
| `MESHLAN_INIT_ONLY` | 两者 | 入口自身 | 关闭 |
| `MESHLAN_MASTER_KEY_FILE` | 两者 | 外部主密钥 | 不设（默认在卷内） |

空串视为未设置。命令行参数优先于环境变量。
