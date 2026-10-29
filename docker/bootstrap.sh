#!/usr/bin/env bash
# MeshLAN 容器部署引导脚本：问几个问题，写 .env，可选立刻构建并启动。
#
#   docker/bootstrap.sh                 # 交互式
#   docker/bootstrap.sh --ip 203.0.113.10 --yes   # 非交互（自动化）
#
# 它做的事，按顺序：
#   1. 检查 docker / docker compose v2 / /dev/net/tun 是否就绪；
#   2. 问公网地址（**只填 IP 或域名，端口由入口按角色补**）、状态目录、端口；
#   3. 建好状态目录（0700；能以 root 跑就把属主先对齐到 10001，省得入口再 chown 宿主目录）；
#   4. 写仓库根的 .env（0600，已进 .gitignore），compose 会自动读它做插值；
#   5. 用 `docker compose config` 校验一遍（插值/端口/设备挂载写错会在这里就报出来，
#      而不是等容器起一半才炸）；
#   6. 问是否立刻 `docker compose up -d --build`（带 --yes 时直接起）。
#
# 它**不**碰产品代码、不改 compose 定义，只生成本机配置。

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

ENV_FILE="$REPO_ROOT/.env"
ASSUME_YES=0
OPT_IP=""
OPT_STATE_DIR=""
OPT_PAIRING_PORT=""
OPT_NEBULA_PORT=""
OPT_WITH_NODE=0
OPT_NO_UP=0

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }
ask() { # $1=提示 $2=缺省值 -> 打印结果
  local prompt="$1" default="${2:-}" answer=""
  if [ "$ASSUME_YES" = "1" ]; then printf '%s' "$default"; return 0; fi
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi
  IFS= read -r answer || answer=""
  printf '%s' "${answer:-$default}"
}
ask_yes_no() { # $1=提示 $2=缺省 y/n
  local answer
  answer="$(ask "$1 (y/n)" "$2")"
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

usage() {
  cat <<'EOF'
用法：docker/bootstrap.sh [选项]

  --ip <地址>            公网 IP 或域名（Lighthouse 用；Node 默认复用同一个）
  --state-dir <目录>     状态绑定目录（缺省 ./meshlan-state）
  --pairing-port <端口>  Lighthouse 配对/管理 HTTPS 端口（缺省 8090）
  --nebula-port <端口>   Lighthouse Nebula UDP 端口（缺省 4242）
  --with-node            同时启用 node profile
  --no-up                只写 .env，不启动
  --yes                  非交互，全部取缺省值（须配 --ip）
  -h, --help             显示本帮助
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ip) OPT_IP="${2:-}"; shift 2 ;;
    --state-dir) OPT_STATE_DIR="${2:-}"; shift 2 ;;
    --pairing-port) OPT_PAIRING_PORT="${2:-}"; shift 2 ;;
    --nebula-port) OPT_NEBULA_PORT="${2:-}"; shift 2 ;;
    --with-node) OPT_WITH_NODE=1; shift ;;
    --no-up) OPT_NO_UP=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（用 --help 看用法）" ;;
  esac
done

# ---------------------------------------------------------------- 前置检查

for bin in docker; do
  command -v "$bin" >/dev/null 2>&1 || die "缺 $bin：请先安装 Docker（或 Podman 的 docker 兼容层）"
done
docker compose version >/dev/null 2>&1 || die "docker compose v2 不可用（本脚本不做 v1 降级）"
[ -e /dev/net/tun ] || die "没有 /dev/net/tun：Nebula 建不出 tun 设备（宿主机需要 tun 模块，容器要透传该设备）"

# ---------------------------------------------------------------- 采集参数

if [ -n "$OPT_IP" ]; then
  PUBLIC_IP="$OPT_IP"
else
  PUBLIC_IP="$(ask '公网 IP 或域名（只填地址，端口自动补）' '')"
  [ -n "$PUBLIC_IP" ] || die "必须提供公网地址：它会被写进状态且之后改不动（填错只能删状态目录重建 PKI）"
fi

# 形状检查：与入口同一套规则（不做 DNS 查询，可达性等容器起来再验）。
case "$PUBLIC_IP" in
  ""|*[!0-9A-Za-z.:_-]*) die "公网地址不合法：$PUBLIC_IP" ;;
  *..*) die "公网地址不合法：$PUBLIC_IP" ;;
esac
# 用户若照旧文档带了端口，这里帮他剥掉并提醒（入口也会归一化，但别让他以为端口生效）。
case "$PUBLIC_IP" in
  \[*\]:*) PUBLIC_IP="${PUBLIC_IP%%\]:*}"; PUBLIC_IP="${PUBLIC_IP#\[}"; note "提示：已去掉地址里的端口（端口由 MESHLAN_*_PORT 控制）" ;;
  *:*)
    host_part="${PUBLIC_IP%%:*}"
    port_part="${PUBLIC_IP#*:}"
    case "$port_part" in
      ""|*[!0-9]*) die "地址里的端口部分不是数字：$PUBLIC_IP" ;;
    esac
    PUBLIC_IP="$host_part"
    note "提示：已去掉地址里的端口 $port_part（端口由 MESHLAN_*_PORT 控制）"
    ;;
esac

if [ -n "$OPT_STATE_DIR" ]; then
  STATE_DIR="$OPT_STATE_DIR"
else
  STATE_DIR="$(ask '状态目录（绑定目录，不是命名卷）' './meshlan-state')"
fi
case "$STATE_DIR" in
  /*) : ;;
  *) STATE_DIR="$REPO_ROOT/${STATE_DIR#./}" ;;
esac

PAIRING_PORT="${OPT_PAIRING_PORT:-}"
if [ -z "$PAIRING_PORT" ]; then
  PAIRING_PORT="$(ask 'Lighthouse 配对/管理 HTTPS 端口' '8090')"
fi
NEBULA_PORT="${OPT_NEBULA_PORT:-}"
if [ -z "$NEBULA_PORT" ]; then
  NEBULA_PORT="$(ask 'Lighthouse Nebula UDP 端口' '4242')"
fi
for pair in "MESHLAN_PAIRING_PORT:$PAIRING_PORT" "MESHLAN_NEBULA_PORT:$NEBULA_PORT"; do
  name="${pair%%:*}"; value="${pair#*:}"
  case "$value" in ""|*[!0-9]*) die "$name 必须是整数：$value" ;; esac
  [ "$value" -ge 1 ] && [ "$value" -le 65535 ] || die "$name 必须是 1-65535：$value"
done

WITH_NODE="$OPT_WITH_NODE"
if [ "$WITH_NODE" != "1" ] && [ "$ASSUME_YES" != "1" ]; then
  ask_yes_no '现在就一起起一台 Node 吗？' 'n' && WITH_NODE=1 || WITH_NODE=0
fi

# ---------------------------------------------------------------- 状态目录

mkdir -p "$STATE_DIR"
chmod 0700 "$STATE_DIR"
if [ "$(id -u)" = "0" ]; then
  # 能让入口少做一次 chown：绑定目录时 `chown -R` 改的是宿主目录属主，先对齐更干净。
  chown 10001:10001 "$STATE_DIR"
  note "状态目录 $STATE_DIR 属主已对齐到 10001:10001（0700）"
else
  note "状态目录 $STATE_DIR 已就绪（0700）。容器内以 root 启动后会把它 chown 到 10001；"
  note "若宿主目录属主随之改变，属预期行为（状态根里是身份与主密钥，属主必须归运行用户）。"
fi

# ---------------------------------------------------------------- 写 .env

umask 077
cat >"$ENV_FILE" <<EOF
# 由 docker/bootstrap.sh 生成于 $(date -u +%Y-%m-%dT%H:%M:%SZ)。改这个文件即改部署参数。
# 注意：MESHLAN_IP 在首次初始化时写进状态，之后改不动（仓库里没有修改命令）。

# 公网地址（只填 IP 或域名；端口由入口按角色补）
MESHLAN_IP=$PUBLIC_IP
# Node 复用同一地址；跨主机部署时改成 Node 自己的公网地址
MESHLAN_NODE_IP=$PUBLIC_IP

MESHLAN_SUBNET=$(ask 'Nebula 虚拟网段' '10.77.0.0/24')
MESHLAN_PAIRING_PORT=$PAIRING_PORT
MESHLAN_NEBULA_PORT=$NEBULA_PORT

# 状态绑定目录（不是命名卷）：备份 = 打包这个目录
MESHLAN_STATE_DIR=$STATE_DIR

# Node 端口（与 Lighthouse 错开，两者都在同一台宿主上时不会冲突）
MESHLAN_NODE_PAIRING_PORT=18090
MESHLAN_NODE_NEBULA_PORT=14242
EOF
chmod 0600 "$ENV_FILE"
note "已写 $ENV_FILE（0600，已进 .gitignore）"

# ---------------------------------------------------------------- 校验 compose

cd "$REPO_ROOT"
if [ "$WITH_NODE" = "1" ]; then
  compose_args=(--profile node)
else
  compose_args=()
fi
if ! docker compose "${compose_args[@]}" config --quiet >/tmp/meshlan-bootstrap-config.$$ 2>&1; then
  note "docker compose config 校验失败，以下是原文："
  cat /tmp/meshlan-bootstrap-config.$$ >&2
  rm -f /tmp/meshlan-bootstrap-config.$$
  die "compose 定义或 .env 有错，未启动任何容器"
fi
rm -f /tmp/meshlan-bootstrap-config.$$
note "docker compose config 校验通过"

# ---------------------------------------------------------------- 启动

if [ "$OPT_NO_UP" = "1" ]; then
  note "已按要求停在写配置这一步。启动："
  if [ "$WITH_NODE" = "1" ]; then
    note "  docker compose --profile node up -d --build"
  else
    note "  docker compose up -d --build"
  fi
  exit 0
fi

run_up=1
if [ "$ASSUME_YES" != "1" ]; then
  ask_yes_no '现在构建并启动吗？（首次构建要下载 Go 与 Nebula，几分钟）' 'y' || run_up=0
fi
if [ "$run_up" = "1" ]; then
  note "开始构建并启动……"
  docker compose "${compose_args[@]}" up -d --build
  note ""
  note "起来了。接下来："
  note "  1) 取一次性凭据：docker compose exec lighthouse cat /var/lib/meshlan/first-credentials.txt"
  note "     （配对哈希与管理令牌只在初始化时生成一次；这个文件建议读完就删）"
  note "  2) 管理台：https://$PUBLIC_IP:$PAIRING_PORT/admin"
  note "  3) 备份：docker compose stop 后打包 $STATE_DIR（必须含 history.sqlite-wal）"
else
  note "未启动。随时可以用：docker compose ${compose_args[*]} up -d --build"
fi
