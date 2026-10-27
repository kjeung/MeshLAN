#!/bin/sh
# MeshLAN 容器入口（Entrypoint contract，见 issue #8 与 ADR-0001）。
#
# 职责，按顺序：
#   1. 有命令行参数 -> 原样转发给 /usr/local/bin/meshlan（不做任何翻译），以 root 直接 exec。
#   2. 无参数 -> 按 MESHLAN_ROLE 补齐缺省值：状态文件、端口、子命令。
#   3. 初始化幂等：只认“本角色状态文件是否存在”。状态文件不在但已有初始化材料 -> 拒绝重跑。
#   4. 首次初始化：缺公网地址即失败；初始化输出里只提取一次性凭据落盘（0600），不落持久日志。
#   5. root -> chown 状态根 -> 二进制加 file capability -> setpriv 降权到 10001 -> exec 服务进程。
#
# 不做的事：不引入信号代理（服务进程经 exec 成为 PID 1）、不对退出码做断言（ADR-0001）、
# 不猜公网地址、不在入口改写二进制参数语义。

set -eu

PROG=meshlan-entrypoint
MESHLAN_BIN=/usr/local/bin/meshlan
NEBULA_BIN=/usr/local/bin/nebula
NEBULA_CERT_BIN=/usr/local/bin/nebula-cert
STATE_ROOT=/var/lib/meshlan
RUN_UID=10001
RUN_GID=10001
CREDENTIALS_NAME=first-credentials.txt

log() { printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PROG" "$*"; }
warn() { log "$*" >&2; }
die() { warn "错误：$*"; exit 1; }

# ---------------------------------------------------------------- 参数透传

if [ "$#" -gt 0 ]; then
  exec "$MESHLAN_BIN" "$@"
fi

# ---------------------------------------------------------------- 角色分派

ROLE="${MESHLAN_ROLE:-}"
case "$ROLE" in
  lighthouse|node) ;;
  "")
    die "必须设置 MESHLAN_ROLE（合法值：lighthouse、node）。一台容器只承担一个角色；Relay 是 Lighthouse 的能力，不是第三个角色。"
    ;;
  *)
    die "MESHLAN_ROLE=[$ROLE] 不合法（合法值：lighthouse、node）。"
    ;;
esac

require_port() {
  # $1 = 变量名，$2 = 取值
  case "${2:-}" in
    ""|*[!0-9]*) die "$1 必须是 1-65535 的整数（当前：[${2:-}]）" ;;
  esac
  if [ "$2" -lt 1 ] || [ "$2" -gt 65535 ]; then
    die "$1 必须是 1-65535 的整数（当前：[$2]）"
  fi
}

NEBULA_PORT="${MESHLAN_NEBULA_PORT:-}"
PAIRING_PORT="${MESHLAN_PAIRING_PORT:-}"
SUBNET="${MESHLAN_SUBNET:-10.77.0.0/24}"
ENDPOINT="${MESHLAN_PUBLIC_ENDPOINT:-}"

case "$ROLE" in
  lighthouse)
    STATE_DIR="$STATE_ROOT"
    STATE_FILE="$STATE_ROOT/server-state.json"
    NEBULA_PORT="${NEBULA_PORT:-4242}"
    PAIRING_PORT="${PAIRING_PORT:-8090}"
    SERVE_SUBCOMMAND=serve
    ;;
  node)
    # Node 用同一个卷内的子目录，身份与 Lighthouse 分开（issue #7 / #8）。
    STATE_DIR="$STATE_ROOT/node"
    STATE_FILE="$STATE_ROOT/node/node-state.json"
    NEBULA_PORT="${NEBULA_PORT:-14242}"
    PAIRING_PORT="${PAIRING_PORT:-18090}"
    SUBNET=""
    SERVE_SUBCOMMAND=node-serve
    ;;
esac

require_port MESHLAN_NEBULA_PORT "$NEBULA_PORT"
require_port MESHLAN_PAIRING_PORT "$PAIRING_PORT"

INIT_ONLY=0
case "${MESHLAN_INIT_ONLY:-}" in
  ""|0|false|no|off) INIT_ONLY=0 ;;
  1|true|yes|on) INIT_ONLY=1 ;;
  *) die "MESHLAN_INIT_ONLY=[${MESHLAN_INIT_ONLY}] 不合法（留空即关闭；1/true/yes/on 开启）" ;;
esac

# ---------------------------------------------------------------- 运行身份

AS_ROOT=0
if [ "$(id -u)" = "0" ]; then
  AS_ROOT=1
fi

as_user() {
  if [ "$AS_ROOT" = "1" ]; then
    setpriv --reuid="$RUN_UID" --regid="$RUN_GID" --clear-groups -- "$@"
  else
    "$@"
  fi
}

prepare_runtime() {
  # 命名卷首次挂载的属主是 0:0，非 root 写不进去（2026-10-27 实测）——这条是固定路径，不是备用分支。
  if [ "$AS_ROOT" = "1" ]; then
    mkdir -p "$STATE_DIR"
    chown -R "$RUN_UID:$RUN_GID" "$STATE_DIR"
    chmod 0700 "$STATE_DIR"
    if command -v setcap >/dev/null 2>&1; then
      # 非 root 的 Nebula 需要“bounding set 里有 NET_ADMIN”+“二进制 file capability”两样齐备。
      # 必须逐个文件调用：libcap 2.75 在第二个文件上会以 EINVAL 失败（内核 6.1 实测），
      # 而 setcap 的多文件形式不是原子操作——第一个文件会成功、第二个失败，退出码非零。
      setcap cap_net_admin+ep "$NEBULA_BIN" \
        || die "给 $NEBULA_BIN 设置 cap_net_admin 失败：需要 CAP_SETFCAP（默认具备）与可写的 /usr/local/bin；若用了只读 rootfs，请在镜像构建期就设好 capability 并保留它"
      setcap cap_net_admin+ep "$MESHLAN_BIN" \
        || die "给 $MESHLAN_BIN 设置 cap_net_admin 失败：需要 CAP_SETFCAP（默认具备）与可写的 /usr/local/bin；若用了只读 rootfs，请在镜像构建期就设好 capability 并保留它"
    else
      die "镜像里没有 setcap（libcap2-bin），无法给 Nebula 二进制设置 file capability"
    fi
    log "状态根 $STATE_DIR 已归 $RUN_UID:$RUN_GID，下一步以该用户运行"
  else
    if [ "$(id -u)" != "$RUN_UID" ]; then
      warn "当前以 uid $(id -u) 运行而不是 $RUN_UID；状态根属主需要与该用户对齐"
    fi
  fi
}

# ---------------------------------------------------------------- 初始化

materials_present() {
  for name in ca.key ca.crt lighthouse.crt lighthouse.key node.key node.pub; do
    if [ -e "$STATE_DIR/$name" ]; then
      return 0
    fi
  done
  if [ -e "$STATE_FILE.master.key" ]; then
    return 0
  fi
  return 1
}

extract_field() {
  # $1 = 输出文件，$2 = 字段前缀（含冒号与空格）
  sed -n "s/^$2//p" "$1" | head -n 1
}

capture_credentials() {
  # $1 = 初始化子进程的 stdout/stderr 暂存文件
  out_file="$STATE_DIR/$CREDENTIALS_NAME"
  umask 077
  {
    printf '# MeshLAN %s 首次启动凭据（一次性机密）\n' "$ROLE"
    printf '# 这是“配对”所需的东西：把它存进你的密码管理器。不要提交进仓库、工单或持久日志。\n'
    printf '# 本文件不会被容器自动删除；读完后建议手工删除。重新生成见 README 的容器章节。\n'
  } >"$out_file"
  if [ "$ROLE" = "lighthouse" ]; then
    pairing="$(extract_field "$1" '配对哈希: ')"
    token="$(extract_field "$1" '管理令牌: ')"
    [ -n "$pairing" ] || warn "未能从初始化输出里提取配对哈希；请到管理台重新生成"
    [ -n "$token" ] || warn "未能从初始化输出里提取管理令牌；请用 admin-token 子命令重新生成"
    printf '配对哈希: %s\n管理令牌: %s\n' "$pairing" "$token" >>"$out_file"
  else
    node_code="$(extract_field "$1" '子节点哈希: ')"
    [ -n "$node_code" ] || warn "未能从初始化输出里提取子节点哈希；只能删节点状态后重新初始化"
    printf '子节点哈希: %s\n' "$node_code" >>"$out_file"
  fi
  chmod 0600 "$out_file"
  if [ "$AS_ROOT" = "1" ]; then
    chown "$RUN_UID:$RUN_GID" "$out_file"
  fi

  # 内容仍然只在这一次输出里出现（随后落盘 0600）；markdown 里说过：不许进持久日志。
  warn "首次凭据已写入 $out_file（0600）。下面的内容只应保存在密码管理器里，不要重定向进日志。"
  printf '%s\n' "---- 一次性凭据（$ROLE）----"
  sed -n 's/^# //p' "$out_file"
  sed -n '/^配对哈希: /p;/^管理令牌: /p;/^子节点哈希: /p' "$out_file"
  printf '%s\n' "---- 一次性凭据结束（路径：$out_file）----"
}

run_init() {
  if [ -z "$ENDPOINT" ]; then
    die "缺少 MESHLAN_PUBLIC_ENDPOINT，拒绝初始化（不猜 localhost、不探测出口地址）。
  这个地址在初始化时被写进状态，仓库里没有修改命令，写错就只能删卷重建 PKI。
  $(role_endpoint_hint)"
  fi
  log "首次初始化 $ROLE：状态文件不在、状态根没有残留材料；公网端点 $ENDPOINT（写入后不可改）"

  tmp_out="$STATE_DIR/.init-output.$$"
  umask 077
  : >"$tmp_out"
  trap 'rm -f "$tmp_out"' EXIT HUP INT TERM

  if [ "$ROLE" = "lighthouse" ]; then
    if ! as_user "$MESHLAN_BIN" server init \
      -state "$STATE_FILE" \
      -endpoint "$ENDPOINT" \
      -subnet "$SUBNET" \
      -nebula-port "$NEBULA_PORT" \
      -pairing-port "$PAIRING_PORT" \
      -nebula "$NEBULA_BIN" \
      -nebula-cert "$NEBULA_CERT_BIN" >"$tmp_out" 2>&1; then
      init_failed "$tmp_out"
    fi
  else
    if ! as_user "$MESHLAN_BIN" server node-init \
      -state "$STATE_FILE" \
      -endpoint "$ENDPOINT" \
      -control-port "$PAIRING_PORT" \
      -nebula-port "$NEBULA_PORT" \
      -nebula "$NEBULA_BIN" \
      -nebula-cert "$NEBULA_CERT_BIN" >"$tmp_out" 2>&1; then
      init_failed "$tmp_out"
    fi
  fi

  capture_credentials "$tmp_out"
  rm -f "$tmp_out"
  trap - EXIT HUP INT TERM
}

init_failed() {
  warn "初始化失败。原始输出如下（可能短暂包含明文 CA 私钥：不要复制进任何持久日志）："
  cat "$1" >&2
  if [ -e "$STATE_FILE" ]; then
    rm -f "$1"
    die "初始化子命令失败但状态文件已落盘；状态根保持原样，未做任何清理。"
  fi
  rm -f "$1"
  trap - EXIT HUP INT TERM
  die "初始化失败，状态根保持原样（未清理）。修好后重启容器即可重试；若上一次是中途失败、材料已部分落盘，需要清空状态卷。"
}

role_endpoint_hint() {
  if [ "$ROLE" = "lighthouse" ]; then
    printf 'Lighthouse 要“主机:端口”，例如：MESHLAN_PUBLIC_ENDPOINT=203.0.113.10:%s' "$NEBULA_PORT"
  else
    printf 'Node 要纯主机（不带端口），例如：MESHLAN_PUBLIC_ENDPOINT=198.51.100.20'
  fi
}

# ---------------------------------------------------------------- 主流程

prepare_runtime

if [ -e "$STATE_FILE" ]; then
  log "$ROLE 状态文件已存在：跳过初始化（只看文件是否存在，不看内容）"
else
  if materials_present; then
    die "$STATE_DIR 里已有本角色的初始化材料、但没有状态文件——上次初始化未完成。
  清空状态卷后重试（nebula-cert 的 ca/sign 拒绝覆盖已有文件，重跑必败）。"
  fi
  run_init
fi

if [ "$INIT_ONLY" = "1" ]; then
  log "MESHLAN_INIT_ONLY=1：只初始化，不启动服务"
  exit 0
fi

if [ "$ROLE" = "lighthouse" ]; then
  set -- "$MESHLAN_BIN" server "$SERVE_SUBCOMMAND" -state "$STATE_FILE" -nebula "$NEBULA_BIN"
else
  set -- "$MESHLAN_BIN" server "$SERVE_SUBCOMMAND" -state "$STATE_FILE"
fi

log "启动 $ROLE：$*"
if [ "$AS_ROOT" = "1" ]; then
  # 降权之后 exec 的仍是服务进程本身：它成为 PID 1，不引信号代理（ADR-0001）。
  exec setpriv --reuid="$RUN_UID" --regid="$RUN_GID" --clear-groups -- "$@"
fi
exec "$@"
