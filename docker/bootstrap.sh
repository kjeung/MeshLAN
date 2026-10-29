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
# 起 Node 后要用 curl + jq 自动配对；缺它们时不报错，只把自动配对降级成打印手工步骤。
HAVE_CURL_JQ=0
if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  HAVE_CURL_JQ=1
fi
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

# 起 Node 时配对要用到的端口：与写进 .env 的保持一致。
NODE_PAIRING_PORT=18090
NODE_NEBULA_PORT=14242

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

  # ---------------------------------------------------------------- 等 Lighthouse 就绪
  note ""
  note "等待 Lighthouse 健康（冷启动要签发 PKI、拉起 Nebula，最多 3 分钟）……"
  lh_deadline=$((SECONDS + 180))
  lh_ready=0
  while [ "$SECONDS" -lt "$lh_deadline" ]; do
    cid="$(docker compose ps -q lighthouse 2>/dev/null || true)"
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo unknown)"
    if [ "$status" = "healthy" ]; then lh_ready=1; break; fi
    sleep 3
  done
  if [ "$lh_ready" != "1" ]; then
    note "Lighthouse 还没转 healthy。先看日志：docker compose logs lighthouse"
    note "（健康只说明控制面在监听；若只是慢，稍等再看管理台）"
  else
    note "Lighthouse 已 healthy。"
  fi

  admin_token="$(docker compose exec -T lighthouse sh -c \
    'sed -n "s/^管理令牌: //p" /var/lib/meshlan/first-credentials.txt' 2>/dev/null | tr -d '\r' || true)"

  if [ "$WITH_NODE" = "1" ]; then
    # -------------------------------------------------------------- Node 自动配对
    note ""
    note "把 Node 加入主控（自动）……"
    if [ "$lh_ready" != "1" ]; then
      note "Lighthouse 未就绪，跳过自动配对。手工步骤见下方。"
    elif [ -z "$admin_token" ]; then
      note "没能从 first-credentials.txt 取到管理令牌，跳过自动配对。手工步骤见下方。"
    elif [ "$HAVE_CURL_JQ" != "1" ]; then
      note "缺 curl 或 jq，跳过自动配对。手工步骤见下方。"
    else
      node_hash="$(docker compose exec -T node sh -c \
        'sed -n "s/^子节点哈希: //p" /var/lib/meshlan/node/first-credentials.txt' 2>/dev/null | tr -d '\r' || true)"
      if [ -z "$node_hash" ]; then
        note "没能取到 Node 的子节点哈希（Node 可能还没初始化完），跳过自动配对。"
      else
        session="$(curl -kfsS --max-time 10 -X POST \
          -H "X-MeshLAN-Admin-Token: $admin_token" \
          -H 'Content-Type: application/json' -d '{}' \
          "https://127.0.0.1:$PAIRING_PORT/v1/admin/session" 2>/dev/null \
          | jq -r '.sessionToken // empty' 2>/dev/null || true)"
        if [ -z "$session" ]; then
          note "管理令牌换不到会话（管理台可能已开 TOTP），跳过自动配对。"
        else
          # endpoint 用 host.docker.internal：产品定义已给两个服务加了 extra_hosts。
          code="$(curl -ksS --max-time 40 -o /tmp/meshlan-addnode.$$ -w '%{http_code}' -X POST \
            -H "X-MeshLAN-Admin-Session: $session" \
            -H 'Content-Type: application/json' \
            -d "$(jq -nc --arg e 'host.docker.internal' --arg h "$node_hash" --arg n 'edge-01' '{endpoint:$e,hash:$h,name:$n}')" \
            "https://127.0.0.1:$PAIRING_PORT/v1/admin/nodes" 2>/dev/null || echo 000)"
          body="$(cat /tmp/meshlan-addnode.$$ 2>/dev/null || true)"
          rm -f /tmp/meshlan-addnode.$$
          if [ "$code" = "201" ]; then
            note "已加入主控（POST /v1/admin/nodes -> 201），名字 edge-01。"
            note "等 Node 完成 enroll 并拉起 Nebula（最多 60 秒）……"
            enrolled=0
            pair_deadline=$((SECONDS + 60))
            while [ "$SECONDS" -lt "$pair_deadline" ]; do
              h="$(curl -kfsS --max-time 10 "https://127.0.0.1:$NODE_PAIRING_PORT/v1/node/health" 2>/dev/null || true)"
              if [ "$(printf '%s' "$h" | jq -r '.enrolled // false' 2>/dev/null)" = "true" ] \
                 && [ "$(printf '%s' "$h" | jq -r '.nebulaRunning // false' 2>/dev/null)" = "true" ]; then
                enrolled=1; break
              fi
              sleep 3
            done
            if [ "$enrolled" = "1" ]; then
              note "Node 配对完成：enrolled=true、nebulaRunning=true。"
            else
              note "Node 还没转到 enrolled+nebulaRunning。查：docker compose logs node"
            fi
          else
            note "加节点失败（HTTP $code）。响应体："
            printf '%s\n' "${body:0:600}" | sed 's/^/    /'
            note "409 是笼统码：常见原因是主控到 Node 的 $NODE_PAIRING_PORT 不通，"
            note "或该 Node 已被加过（换名字或删 Node 状态目录后重来）。"
          fi
        fi
      fi
    fi
  fi

  # ---------------------------------------------------------------- 手工步骤（始终打印）
  note ""
  note "手工加入 Node（自动配对没成功、或想改名字/地址时用）："
  note "  1) 取 Node 哈希："
  note "     docker compose exec node cat /var/lib/meshlan/node/first-credentials.txt"
  note "  2) 取管理令牌："
  note "     docker compose exec lighthouse cat /var/lib/meshlan/first-credentials.txt"
  note "  3) 打开管理台 https://$PUBLIC_IP:$PAIRING_PORT/admin ，用管理令牌登录，"
  note "     进「多节点」页，填 节点名称 / 子节点 IP 或域名 / 子节点哈希（MLNODE1…），点「验证并添加」。"
  note "     子节点 IP 或域名 填 host.docker.internal（同主机）或 Node 的真实公网地址。"
  note ""
  note "  还可以纯 API（脚本用的就是这条）："
  note "     SESSION=\$(curl -kfsS -X POST -H \"X-MeshLAN-Admin-Token: <管理令牌>\" \\"
  note "       -H 'Content-Type: application/json' -d '{}' \\"
  note "       https://127.0.0.1:$PAIRING_PORT/v1/admin/session | jq -r .sessionToken)"
  note "     curl -kfsS -X POST -H \"X-MeshLAN-Admin-Session: \$SESSION\" \\"
  note "       -H 'Content-Type: application/json' \\"
  note "       -d '{\"endpoint\":\"host.docker.internal\",\"hash\":\"MLNODE1…\",\"name\":\"edge-01\"}' \\"
  note "       https://127.0.0.1:$PAIRING_PORT/v1/admin/nodes"
  note ""
  note "备份：docker compose stop 后打包 $STATE_DIR（整目录，天然含 history.sqlite-wal）"
else
  note "未启动。随时可以用：docker compose ${compose_args[*]} up -d --build"
  if [ "$WITH_NODE" = "1" ]; then
    note "起来之后，Node 的加入方式见部署手册 5.1：管理台「多节点」页，或同一节里的纯 API 命令。"
  fi
fi
