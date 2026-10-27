# syntax=docker/dockerfile:1
#
# MeshLAN Linux 控制面镜像：一台镜像、一个容器一个角色。
# 契约来源：docs/adr/0001-no-graceful-shutdown-in-container.md、
#          docs/research/nebula-v1.11.0-build-inputs.md、
#          issue #7（状态根/身份/密钥边界）与 #8（入口契约与端口映射）。
#
# 构建：docker compose build      运行：docker compose up -d
# 不向任何 registry 发布镜像。

ARG GO_VERSION=1.26
ARG DEBIAN_VERSION=stable-slim

# ---- 构建阶段：静态链接的 server 二进制（CGO 关闭，按目标架构交叉编译） ----
FROM golang:${GO_VERSION} AS build
ARG TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
# 只拷构建真正需要的源码目录（构建上下文白名单式拷贝，见 #7）。
COPY cmd/ ./cmd/
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux GOARCH="${TARGETARCH}" \
    go build -trimpath -ldflags="-s -w" -o /out/meshlan ./cmd/meshlan

# ---- Nebula 阶段：按目标架构取 v1.11.0 官方预编译产物，sha256 钉死 ----
FROM debian:${DEBIAN_VERSION} AS nebula
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG NEBULA_VERSION=v1.11.0
ARG TARGETARCH
# hadolint ignore=DL3008
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) checksum=e7cdb240597d0783c9943e9c89aad3c96c59b67e75c644d62f33ae558e69d09e ;; \
      arm64) checksum=da314d9791185583dddceb14dffe991caa6997eaff8dbe0445331a2fa70c6fd9 ;; \
      *) echo "不支持的架构：${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /out; \
    curl -fsSL -o /tmp/nebula.tar.gz \
      "https://github.com/slackhq/nebula/releases/download/${NEBULA_VERSION}/nebula-linux-${TARGETARCH}.tar.gz"; \
    printf '%s  %s\n' "${checksum}" /tmp/nebula.tar.gz | sha256sum -c -; \
    tar -xzf /tmp/nebula.tar.gz -C /out nebula nebula-cert; \
    chmod 0755 /out/nebula /out/nebula-cert; \
    /out/nebula -version; \
    /out/nebula-cert -version; \
    rm -f /tmp/nebula.tar.gz

# ---- 运行阶段 ----
FROM debian:${DEBIAN_VERSION} AS runtime
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

LABEL org.opencontainers.image.title="MeshLAN Linux control plane" \
      org.opencontainers.image.description="自托管 Nebula 控制面：Lighthouse 与 Node 两种角色，一台镜像" \
      org.opencontainers.image.source="https://github.com/kjeung/MeshLAN" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive

# curl 供 compose 健康检查使用（不依赖基础镜像自带什么）；libcap2-bin 供入口设置 file capability；
# util-linux 提供 setpriv（入口用它降权）。
# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl libcap2-bin util-linux; \
    rm -rf /var/lib/apt/lists/*

# 固定非 root 用户（uid/gid 10001），状态根在镜像里预建并归属它。
RUN set -eux; \
    groupadd --gid 10001 meshlan; \
    useradd --uid 10001 --gid 10001 --no-create-home --home-dir /var/lib/meshlan --shell /usr/sbin/nologin meshlan

COPY --from=nebula /out/nebula /out/nebula-cert /usr/local/bin/
COPY --from=build /out/meshlan /usr/local/bin/meshlan
COPY docker/entrypoint.sh /usr/local/bin/meshlan-entrypoint

# 状态根与二进制就位；Nebula 与 server 二进制带 file capability，非 root 才拿得到 tun 管理权。
RUN set -eux; \
    chmod 0755 /usr/local/bin/nebula /usr/local/bin/nebula-cert /usr/local/bin/meshlan /usr/local/bin/meshlan-entrypoint; \
    mkdir -p /var/lib/meshlan/node; \
    chown 10001:10001 /var/lib/meshlan /var/lib/meshlan/node; \
    chmod 0700 /var/lib/meshlan /var/lib/meshlan/node; \
    command -v setpriv; \
    command -v setcap; \
    /usr/local/bin/nebula -version; \
    /usr/local/bin/nebula-cert -version; \
    usage="$(/usr/local/bin/meshlan 2>&1 || true)"; \
    case "$usage" in *用法*) : ;; *) echo "meshlan 无法执行或没有打印用法" >&2; exit 1 ;; esac; \
    setcap cap_net_admin+ep /usr/local/bin/nebula; \
    setcap cap_net_admin+ep /usr/local/bin/meshlan; \
    getcap /usr/local/bin/nebula /usr/local/bin/meshlan

# 构建期断言：最终层不含任何私钥、证书、状态文件与数据库（#7 的密钥边界）。
# 只放行基础镜像自带的系统 CA 库。
RUN set -eux; \
    if find / -xdev \( -path /proc -o -path /sys -o -path /etc/ssl -o -path /usr/share/ca-certificates \) -prune -o -type f \
        \( -name '*.key' -o -name '*.pem' -o -name '*.p12' -o -name '*.pfx' -o -name '*.crt' \
           -o -name '*state*.json' -o -name '*.sqlite' -o -name '*.sqlite-wal' -o -name '*.sqlite-shm' \) -print \
        | head -n 3 | grep -q .; then \
      echo "镜像里出现了密钥/证书/状态材料，构建中止" >&2; exit 1; \
    fi

# 入口必须在 root 下启动：先 chown 状态根、设置 file capability，再 setpriv 降权到 10001。
# 降权之后 exec 的仍是服务进程本身，因此它成为 PID 1（ADR-0001）。
# hadolint ignore=DL3002
USER 0:0

EXPOSE 8090/tcp 4242/udp 18090/tcp 14242/udp

ENTRYPOINT ["/usr/local/bin/meshlan-entrypoint"]
