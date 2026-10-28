#!/usr/bin/env bash
# MeshLAN 容器级验收脚本（issue #10；这条接缝由 #7 / #8 的 Testing Decisions 共同指定）。
#
#   docker/acceptance.sh                      # 全量跑；成功即自清理
#   KEEP_ON_FAIL=0 docker/acceptance.sh       # 失败也不留现场（默认失败保留现场供取证）
#   ACCEPTANCE_FORCE=1 docker/acceptance.sh   # 端口或同名栈被占用时强制继续
#
# 它证明的是一条链：构建 → 配置校验 → 首次启动 → 健康转绿 → 停止 → 重启 → 身份不变
# → 缺地址失败 → 角色非法失败 → MESHLAN_INIT_ONLY → Node 起得来 → Node 真配对。
#
# 三条自我约束（来自 #8 的 Testing Decisions）：
#   1. 只断言外部可观察行为：容器状态、状态根里的文件、HTTP 响应、退出码、耗时。
#      不断言镜像层数、基础镜像 tag、脚本内部用了哪个命令。
#   2. 每条断言都必须能变红：末尾的「可失败性」清单逐条说明哪个决策被违背时它会红。
#   3. 不对容器停止的退出码做断言（143/137 都不是判据，ADR-0001）。脚本只打印实测值。
#
# 边界：只证同主机、amd64、compose。跨主机 Node、arm64 实跑、CI 集成都不在本脚本。

set -Eeuo pipefail
umask 022

PROJECT="${ACCEPTANCE_PROJECT:-meshlan-acceptance}"
BASE_COMPOSE="${ACCEPTANCE_BASE_COMPOSE:-docker-compose.yml}"
OVERRIDE_COMPOSE="${ACCEPTANCE_OVERRIDE_COMPOSE:-docker/acceptance.compose.yml}"
IMAGE="${ACCEPTANCE_IMAGE:-meshlan:local}"

PAIR_HOST="${MESHLAN_ACCEPTANCE_ENDPOINT:-host.docker.internal}"
LH_PUBLIC_ENDPOINT="${MESHLAN_ACCEPTANCE_PUBLIC_ENDPOINT:-${PAIR_HOST}:4242}"

# 端口不设环境覆盖：compose 定义里宿主端口是写死的 1:1，给它一个覆盖口只会让
# 「探针打哪个端口」和「compose 实际发布哪个端口」悄悄脱钩——第二次污染运行就是这么红的。
# 四个端口一律从 `compose config` 现读（见「2. 配置校验」），读不到就直接失败。
LH_HTTP_PORT=""
LH_NEBULA_PORT=""
NODE_CTRL_PORT=""
NODE_NEBULA_PORT=""

READY_TIMEOUT="${ACCEPTANCE_READY_TIMEOUT:-180}"
PAIR_TIMEOUT="${ACCEPTANCE_PAIR_TIMEOUT:-120}"
KEEP_ON_FAIL="${KEEP_ON_FAIL:-1}"
ACCEPTANCE_FORCE="${ACCEPTANCE_FORCE:-0}"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/meshlan-acceptance.XXXXXX")"
PASS=0
FAIL=0
RESULTS=()
FAILED_STEP=""
STARTED=0

cleanup() {
  rc=$?
  set +e
  if [ "$rc" -ne 0 ]; then
    echo
    echo "验收失败（退出码 $rc，最后一步：${FAILED_STEP:-未知}）。"
    if [ "$STARTED" != "1" ]; then
      echo "尚未创建任何容器或卷（失败发生在前置条件/构建阶段），没有现场需要清理。"
    elif [ "$KEEP_ON_FAIL" = "1" ]; then
      echo "现场已保留，供取证（用完后手工清理）："
      echo "  docker compose -p ${PROJECT} -f ${BASE_COMPOSE} -f ${OVERRIDE_COMPOSE} --profile node logs --no-color"
      echo "  docker compose -p ${PROJECT} -f ${BASE_COMPOSE} -f ${OVERRIDE_COMPOSE} --profile node down -v --remove-orphans"
    else
      echo "按 KEEP_ON_FAIL=0 清理现场。"
      compose --profile node down -v --remove-orphans >/dev/null 2>&1 || true
    fi
  fi
  rm -rf "$WORKDIR"
  exit "$rc"
}
trap cleanup EXIT

c_reset=$'\033[0m'; c_red=$'\033[31m'; c_green=$'\033[32m'; c_dim=$'\033[2m'
if [ ! -t 1 ]; then c_reset=""; c_red=""; c_green=""; c_dim=""; fi

section() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
info()    { printf '%s     %s%s\n' "$c_dim" "$*" "$c_reset"; }
note()    { printf '      %s\n' "$*"; }

pass() {
  PASS=$((PASS + 1)); RESULTS+=("PASS|$1")
  printf '  %s[PASS]%s %s\n' "$c_green" "$c_reset" "$1"
}

fail() {
  FAIL=$((FAIL + 1)); RESULTS+=("FAIL|$1")
  printf '  %s[FAIL]%s %s\n' "$c_red" "$c_reset" "$1"
  if [ -n "${2:-}" ]; then printf '         %s\n' "$2"; fi
  if [ -z "$FAILED_STEP" ]; then FAILED_STEP="$1"; fi
}

assert_true() { if [ "$1" = "1" ]; then pass "$2"; else fail "$2" "${3:-}"; fi; }

assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "实际=[$2] 期望=[$3]"; fi
}

assert_contains() {
  case "$2" in
    *"$3"*) pass "$1" ;;
    *) fail "$1" "输出里没有 [$3]；实际输出：${2:0:400}" ;;
  esac
}

assert_matches() {
  if printf '%s' "$2" | grep -Eq "$3"; then pass "$1"; else fail "$1" "实际=[${2:0:400}] 期望匹配 /$3/"; fi
}

die() { printf '\n%s前置条件不满足%s：%s\n' "$c_red" "$c_reset" "$*" >&2; FAILED_STEP="前置条件"; exit 2; }

compose() { docker compose -p "$PROJECT" -f "$BASE_COMPOSE" -f "$OVERRIDE_COMPOSE" "$@"; }

section "前置条件"

# 上一次运行或线上部署若在同一个 shell 里留下了这些变量，compose 会照它们改端口/端点，
# 而脚本的探针仍打默认端口——第二次污染运行正是这样红的（宿主 8091 已被占，探针却打 8091）。
# 验收必须从干净环境起跑：发现就拒绝，而不是替用户 unset（那会掩盖真实部署）。
for leaked in MESHLAN_PUBLIC_ENDPOINT MESHLAN_NODE_PUBLIC_ENDPOINT MESHLAN_PAIRING_PORT MESHLAN_NEBULA_PORT MESHLAN_NODE_PAIRING_PORT MESHLAN_NODE_NEBULA_PORT MESHLAN_SUBNET MESHLAN_ROLE MESHLAN_INIT_ONLY; do
  if [ -n "${!leaked:-}" ]; then
    die "当前 shell 里残留了 $leaked=${!leaked}。验收要求干净环境（它自己会设置端点与角色）。
  请先执行 unset $leaked（或直接开一个干净 shell 重跑）。脚本只认 MESHLAN_ACCEPTANCE_* 前缀的覆盖变量。"
  fi
done


for bin in docker curl jq; do
  command -v "$bin" >/dev/null 2>&1 || die "缺 $bin（本脚本基线：bash 4+ / docker compose v2 / curl / jq）"
done
[ "${BASH_VERSINFO[0]}" -ge 4 ] || die "需要 bash 4+（当前 $BASH_VERSION）"
docker compose version >/dev/null 2>&1 || die "docker compose v2 不可用（本脚本不做 v1 降级）"
[ -f "$BASE_COMPOSE" ] || die "找不到 $BASE_COMPOSE（请在仓库根目录执行）"
[ -f "$OVERRIDE_COMPOSE" ] || die "找不到 $OVERRIDE_COMPOSE"

note "引擎：docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)；compose：$(docker compose version --short 2>/dev/null || echo unknown)"
note "项目名：$PROJECT；配对端点：$PAIR_HOST；镜像：$IMAGE"

# 端口必须在这里就从定义文件读出来：下面的"宿主端口是否被占用"检查要用它们，
# 而早前那版把读取放在第 2 段，检查时四个变量还是空串，等于什么都没检查。
cfg_pre="$(compose --profile node config 2>/dev/null || true)"
[ -n "$cfg_pre" ] || die "docker compose config 读不出任何内容，无法确定端口（先看 docker compose config 的报错）"

port_of() {
  # $1=服务名 $2=容器端口；输出 compose 实际发布的宿主端口。
  # compose 对每个端口先出 target 再出 published，所以必须把两者收进同一组再比较；
  # 早前"记住上一个 published"的写法会整体错位一个端口（8090 读成空、4242 读成 8090）。
  printf '%s' "$cfg_pre" | awk -v svc="$1" -v want="$2" '
    function flush() { if (tgt == want && pub != "") { print pub; found = 1 } tgt = ""; pub = "" }
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      flush(); cur = $0; sub(/^  /, "", cur); sub(/:.*/, "", cur); next
    }
    cur == svc && /^[[:space:]]*- / { flush(); next }
    cur == svc && /target:/ { v = $0; sub(/.*target:[[:space:]]*/, "", v); gsub(/"/, "", v); tgt = v; next }
    cur == svc && /published:/ { v = $0; sub(/.*published:[[:space:]]*/, "", v); gsub(/"/, "", v); pub = v; next }
    END { if (!found) flush() }
  '
}

LH_HTTP_PORT="$(port_of lighthouse 8090)"
LH_NEBULA_PORT="$(port_of lighthouse 4242)"
NODE_CTRL_PORT="$(port_of node 18090)"
NODE_NEBULA_PORT="$(port_of node 14242)"

for spec in "Lighthouse 配对端口:$LH_HTTP_PORT" "Lighthouse Nebula 端口:$LH_NEBULA_PORT" "Node 控制端口:$NODE_CTRL_PORT" "Node Nebula 端口:$NODE_NEBULA_PORT"; do
  if ! printf '%s' "${spec#*:}" | grep -Eq '^[0-9]+$'; then
    die "无法从 compose config 读出 ${spec%%:*}（实际取值：[${spec#*:}]）。定义文件的 ports 段被改坏了。"
  fi
done
note "端口（读自 compose config）：Lighthouse ${LH_HTTP_PORT}/tcp + ${LH_NEBULA_PORT}/udp；Node ${NODE_CTRL_PORT}/tcp + ${NODE_NEBULA_PORT}/udp"

if [ "$ACCEPTANCE_FORCE" != "1" ]; then
  busy=()
  for p in "$LH_HTTP_PORT" "$LH_NEBULA_PORT" "$NODE_CTRL_PORT" "$NODE_NEBULA_PORT"; do
    if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then busy+=("$p"); exec 3<&- 3>&-; fi
  done
  if [ "${#busy[@]}" -gt 0 ]; then
    die "宿主端口已被占用：${busy[*]}。真机验收不能与线上部署同端口；确认无冲突后用 ACCEPTANCE_FORCE=1 继续。"
  fi
  if docker ps -a --format '{{.Names}}' | grep -Eq '^meshlan-(acceptance-)?(lighthouse|node)$'; then
    die "已有 meshlan 容器在跑（可能是真实部署）。验收会 down -v 删卷，默认拒绝运行；确无风险时用 ACCEPTANCE_FORCE=1。"
  fi
fi

if [ -e /dev/net/tun ]; then
  pass "宿主存在 /dev/net/tun"
else
  fail "宿主没有 /dev/net/tun" "Nebula 在容器里建不出 tun；这是机器不合适，不是产品缺陷，但配对断言会红在正确的位置。"
fi

section "1. 构建"

if compose build >"$WORKDIR/build.log" 2>&1; then
  pass "docker compose build 成功"
else
  fail "docker compose build 失败" "完整日志：$WORKDIR/build.log"
  tail -n 40 "$WORKDIR/build.log" >&2 || true
  exit 1
fi
info "构建日志末 5 行："
tail -n 5 "$WORKDIR/build.log" | while IFS= read -r line; do note "$line"; done

bins="$(docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'for b in /usr/local/bin/meshlan /usr/local/bin/nebula /usr/local/bin/nebula-cert /usr/local/bin/meshlan-entrypoint; do if [ -x "$b" ]; then echo "$b:ok"; else echo "$b:missing"; fi; done')"
assert_contains "镜像里 meshlan 可执行" "$bins" "/usr/local/bin/meshlan:ok"
assert_contains "镜像里 nebula-cert 可执行" "$bins" "/usr/local/bin/nebula-cert:ok"
assert_contains "镜像里入口脚本可执行" "$bins" "/usr/local/bin/meshlan-entrypoint:ok"

secrets="$(docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'find / -xdev \( -path /proc -o -path /sys -o -path /etc/ssl -o -path /usr/share/ca-certificates \) -prune -o -type f \( -name "*.key" -o -name "*.pem" -o -name "*.p12" -o -name "*.pfx" -o -name "*.crt" -o -name "*state*.json" -o -name "*.sqlite*" \) -print | head -n 5' 2>/dev/null || true)"
assert_eq "最终层不含私钥/证书/状态文件/数据库（放行系统 CA 库）" "$secrets" ""

section "2. 配置校验"

if compose config --quiet >"$WORKDIR/config.log" 2>&1; then
  pass "docker compose config 校验通过（默认 profile）"
else
  fail "docker compose config 校验失败" "见 $WORKDIR/config.log"
fi
if compose --profile node config --quiet >"$WORKDIR/config-node.log" 2>&1; then
  pass "docker compose config 校验通过（node profile）"
else
  fail "docker compose config 校验失败（node profile）" "见 $WORKDIR/config-node.log"
fi

# 端口已在「前置条件」里从定义文件读出（那里要用它做占用检查），这里只做取值断言。
cfg="$cfg_pre"
assert_eq "Lighthouse 配对端口 1:1，没有翻译" "$LH_HTTP_PORT" "8090"
assert_eq "Lighthouse Nebula 端口 1:1，没有翻译" "$LH_NEBULA_PORT" "4242"
assert_eq "Node 控制端口 1:1，没有翻译" "$NODE_CTRL_PORT" "18090"
assert_eq "Node Nebula 端口 1:1，没有翻译" "$NODE_NEBULA_PORT" "14242"
assert_contains "stop_grace_period 为 30s" "$cfg" "stop_grace_period: 30s"
tun_mounts="$(printf '%s' "$cfg" | grep -c 'source: /dev/net/tun' || true)"
assert_eq "两个服务都挂了 /dev/net/tun（自建 tun 需要 CAP_MKNOD，最小能力集里没有）" "$tun_mounts" "2"
assert_eq "compose 只有 lighthouse 与 node 两个服务（Relay 是能力不是角色，没有 relay 服务）" \
  "$(compose --profile node config --services 2>/dev/null | sort | tr '\n' ' ' || true)" "lighthouse node "

section "3. 首次启动（Lighthouse）"

compose --profile node down -v --remove-orphans >/dev/null 2>&1 || true
export MESHLAN_PUBLIC_ENDPOINT="$LH_PUBLIC_ENDPOINT"
export MESHLAN_NODE_PUBLIC_ENDPOINT="$PAIR_HOST"

STARTED=1
if compose up -d lighthouse >"$WORKDIR/up-lh.log" 2>&1; then
  pass "lighthouse 容器已启动（首次初始化）"
else
  fail "lighthouse 启动失败" "见 $WORKDIR/up-lh.log；常见原因：缺 MESHLAN_PUBLIC_ENDPOINT、端口占用"
  sed -n '1,40p' "$WORKDIR/up-lh.log" >&2 || true
  exit 1
fi

wait_healthy() {
  svc="$1"
  deadline=$((SECONDS + READY_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    cid="$(compose ps -q "$svc" 2>/dev/null || true)"
    if [ -n "$cid" ]; then
      status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo unknown)"
      if [ "$status" = "healthy" ]; then return 0; fi
    fi
    sleep 3
  done
  return 1
}

if wait_healthy lighthouse; then
  pass "lighthouse 健康转绿（compose healthcheck）"
else
  fail "lighthouse 在 ${READY_TIMEOUT}s 内没有转 healthy" "看 docker compose logs lighthouse；冷启动要先签发 PKI 再监听 TLS"
fi

probe() { curl -kfsS --max-time 10 "$1" 2>/dev/null || true; }

lh_auth_info="$(probe "https://127.0.0.1:$LH_HTTP_PORT/v1/admin/auth-info")"
assert_contains "GET /v1/admin/auth-info 返回 JSON（免认证端点真的在）" "$lh_auth_info" '"totpRequired"'
assert_eq "管理台未开 TOTP（验收不做人机交互）" \
  "$(printf '%s' "$lh_auth_info" | jq -r '.totpRequired' 2>/dev/null || echo missing)" "false"

state_root="$(compose exec -T lighthouse sh -c 'ls -A /var/lib/meshlan 2>/dev/null | tr "\n" " "' || true)"
assert_contains "状态根落在 /var/lib/meshlan（命名卷）" "$state_root" "server-state.json"
assert_contains "CA 证书在状态根里" "$state_root" "ca.crt"
assert_contains "Nebula 渲染配置在状态根里" "$state_root" "lighthouse.yml"
assert_contains "历史数据库在状态根里" "$state_root" "history.sqlite"

mode_creds="$(compose exec -T lighthouse sh -c 'stat -c "%a %U" /var/lib/meshlan/first-credentials.txt' 2>/dev/null || echo missing)"
assert_eq "first-credentials.txt 权限 0600 且归 uid 10001" "$mode_creds" "600 meshlan"

pid1="$(compose exec -T lighthouse sh -c 'tr "\0" " " < /proc/1/cmdline; echo; grep -E "^(Uid|CapEff):" /proc/1/status' 2>/dev/null || true)"
assert_matches "PID 1 是 meshlan 服务进程（入口已 exec）" "$pid1" '/usr/local/bin/meshlan'
assert_matches "PID 1 以 uid 10001 运行（已降权）" "$pid1" 'Uid:[[:space:]]+10001[[:space:]]+10001'

# 镜像里没有 jq（Dockerfile 只装 ca-certificates/curl/libcap2-bin/util-linux），
# 所以在容器内用 jq 读状态文件只会拿到 "not found"，再被下面的 assert_eq 当成
# "两次一样"——那是假绿。改成把文件原样 cat 出来，在宿主上用 sed 取字段。
lh_fingerprint() {
  compose exec -T lighthouse sh -c 'cat /var/lib/meshlan/server-state.json' 2>/dev/null \
    | sed -n 's/.*"httpsCaFingerprint":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

lh_fp1="$(lh_fingerprint)"
if printf '%s' "$lh_fp1" | grep -Eq '^[0-9a-fA-F]{64}$'; then
  pass "拿到 HTTPS CA 指纹（身份锚点）"
else
  # 这一条红了就说明后面两条「身份不变」不可信：它们比的是这个值。
  # 首版正是在这里假绿的——读不到时两次都得到同一个错误串，比较自然相等。
  fail "拿到 HTTPS CA 指纹（身份锚点）" \
    "实际取值：[$lh_fp1]。状态文件里没有 httpsCaFingerprint 字段，或 state 文件读不到；\
此时下面两条「身份不变」断言不可信，不要因为它们显示 PASS 就认为身份保住了。"
fi

lh_creds="$(compose exec -T lighthouse sh -c 'cat /var/lib/meshlan/first-credentials.txt' 2>/dev/null || true)"
LH_ADMIN_TOKEN="$(printf '%s' "$lh_creds" | sed -n 's/^管理令牌: //p' | head -n 1)"
LH_PAIR_HASH="$(printf '%s' "$lh_creds" | sed -n 's/^配对哈希: //p' | head -n 1)"
assert_matches "从状态根取到管理令牌" "$LH_ADMIN_TOKEN" '^[A-Za-z0-9_-]{16,}$'
assert_contains "从状态根取到配对哈希（MLN1 前缀）" "$LH_PAIR_HASH" "MLN1."

section "4. 停止（宽限期内完成）"

stop_start=$SECONDS
if docker stop --time 35 "$(compose ps -q lighthouse)" >"$WORKDIR/stop.log" 2>&1; then
  stop_elapsed=$((SECONDS - stop_start))
  pass "docker stop 正常返回（用时 ${stop_elapsed}s；判据是 stop 本身返回，不是退出码）"
  if [ "$stop_elapsed" -le 30 ]; then
    pass "停止耗时不超过 stop_grace_period=30s"
  else
    fail "停止耗时超过 stop_grace_period=30s" "实测 ${stop_elapsed}s"
  fi
else
  fail "docker stop 未正常返回" "看 $WORKDIR/stop.log"
fi

exit_code="$(docker inspect --format '{{.State.ExitCode}}' "$(compose ps -aq lighthouse)" 2>/dev/null || echo unknown)"
info "停止后的退出码实测：$exit_code（脚本不对它做断言：容器 init 受 SIGNAL_UNKILLABLE 保护，143/137 都不是判据）"

section "5. 重启与身份不变"

compose start lighthouse >/dev/null 2>&1 || compose up -d lighthouse >/dev/null 2>&1 || true
if wait_healthy lighthouse; then
  pass "restart 后再次健康转绿"
else
  fail "restart 后没有转 healthy"
fi

lh_fp2="$(lh_fingerprint)"
assert_eq "restart 后 HTTPS CA 指纹不变（身份住在卷里）" "$lh_fp2" "$lh_fp1"

hb="$(compose exec -T lighthouse sh -c 'test -s /var/lib/meshlan/history.sqlite && echo nonempty || echo empty' 2>/dev/null | tr -d "\r" || echo unknown)"
assert_eq "restart 后历史库存在且非空" "$hb" "nonempty"

compose up -d --force-recreate --no-deps lighthouse >"$WORKDIR/recreate.log" 2>&1 || true
if wait_healthy lighthouse; then
  pass "--force-recreate 后再次健康转绿"
else
  fail "--force-recreate 后没有转 healthy" "见 $WORKDIR/recreate.log"
fi
lh_fp3="$(lh_fingerprint)"
assert_eq "--force-recreate 后 HTTPS CA 指纹不变（重建容器不重建 PKI）" "$lh_fp3" "$lh_fp1"

leak="$(compose exec -T lighthouse sh -c 'ls -A /var/lib/meshlan/node 2>/dev/null | head -n 3 | tr "\n" " "' || true)"
assert_eq "Lighthouse 状态根下没有 Node 的身份材料（分目录生效）" "$leak" ""

section "6. 失败分支（fail-fast）"

run_once() {
  name="$1"; shift
  args=()
  for kv in "$@"; do args+=(-e "$kv"); done
  docker run --rm "${args[@]}" "$IMAGE" >"$WORKDIR/fail-$name.log" 2>&1
}

set +e
run_once no-endpoint MESHLAN_ROLE=lighthouse; rc_no_endpoint=$?
run_once bad-role MESHLAN_ROLE=relay; rc_bad_role=$?
run_once no-role MESHLAN_PUBLIC_ENDPOINT=example.com:4242; rc_no_role=$?
run_once bad-port MESHLAN_ROLE=lighthouse MESHLAN_PUBLIC_ENDPOINT=example.com:4242 MESHLAN_NEBULA_PORT=99999; rc_bad_port=$?
set -e

assert_true "$([ "$rc_no_endpoint" -ne 0 ] && echo 1 || echo 0)" "缺 MESHLAN_PUBLIC_ENDPOINT 时以非零码退出（实际 $rc_no_endpoint）"
assert_contains "缺地址的失败信息点名字段" "$(cat "$WORKDIR/fail-no-endpoint.log")" "MESHLAN_PUBLIC_ENDPOINT"
assert_contains "缺地址的失败信息给出一行可复制命令" "$(cat "$WORKDIR/fail-no-endpoint.log")" "203.0.113.10"
assert_true "$([ "$rc_bad_role" -ne 0 ] && echo 1 || echo 0)" "非法角色 relay 以非零码退出（实际 $rc_bad_role）"
assert_contains "非法角色列出合法值" "$(cat "$WORKDIR/fail-bad-role.log")" "lighthouse、node"
assert_true "$([ "$rc_no_role" -ne 0 ] && echo 1 || echo 0)" "缺 MESHLAN_ROLE 以非零码退出（实际 $rc_no_role）"
assert_true "$([ "$rc_bad_port" -ne 0 ] && echo 1 || echo 0)" "非法端口以非零码退出（实际 $rc_bad_port）"

init_vol="${PROJECT}-initonly"
docker volume rm -f "$init_vol" >/dev/null 2>&1 || true
set +e
# 必须复刻 compose 给的运行时权限：入口会对 meshlan/nebula 打 file capability，
# 而文件能力只有在 bounding set 里也有 NET_ADMIN 时才允许 exec（#7 能力矩阵第 I 行：
# 有文件能力、bounding set 无 NET_ADMIN -> "exec ... operation not permitted"）。
# 少了这两行，容器会在 exec 那一步以 1 退出，看起来像"INIT_ONLY 坏了"，其实是脚本没给够权限。
docker run --rm \
  --cap-add NET_ADMIN \
  --device /dev/net/tun \
  -e MESHLAN_ROLE=lighthouse \
  -e MESHLAN_PUBLIC_ENDPOINT="$LH_PUBLIC_ENDPOINT" \
  -e MESHLAN_INIT_ONLY=1 \
  -v "$init_vol:/var/lib/meshlan" \
  "$IMAGE" >"$WORKDIR/init-only.log" 2>&1
rc_init_only=$?
set -e
assert_eq "MESHLAN_INIT_ONLY=1 正常退出（只初始化，不启动服务）" "$rc_init_only" "0"
if [ "$rc_init_only" != "0" ]; then
  fail "INIT_ONLY 失败原因" "容器输出：$(head -c 1200 "$WORKDIR/init-only.log")"
fi
init_state="$(docker run --rm -v "$init_vol:/var/lib/meshlan" --entrypoint /bin/sh "$IMAGE" -c 'test -f /var/lib/meshlan/server-state.json && echo present || echo absent')"
assert_eq "INIT_ONLY 模式确实写下了状态文件" "$init_state" "present"
docker volume rm -f "$init_vol" >/dev/null 2>&1 || true

section "7. Node 角色起得来（未配对）"

if compose --profile node up -d node >"$WORKDIR/up-node.log" 2>&1; then
  pass "node 容器已启动（首次初始化）"
else
  fail "node 启动失败" "见 $WORKDIR/up-node.log"
fi

if wait_healthy node; then
  pass "node 健康转绿（未配对时 Nebula 本就不启动，探针只要求 JSON）"
else
  fail "node 在 ${READY_TIMEOUT}s 内没有转 healthy"
fi

node_health0="$(probe "https://127.0.0.1:$NODE_CTRL_PORT/v1/node/health")"
assert_eq "未配对时 enrolled=false" "$(printf '%s' "$node_health0" | jq -r '.enrolled' 2>/dev/null || echo missing)" "false"

node_creds="$(compose exec -T node sh -c 'cat /var/lib/meshlan/node/first-credentials.txt' 2>/dev/null || true)"
NODE_HASH="$(printf '%s' "$node_creds" | sed -n 's/^子节点哈希: //p' | head -n 1)"
assert_contains "从 Node 状态根取到 MLNODE1 哈希" "$NODE_HASH" "MLNODE1."

assert_contains "Node 用同一卷内的子目录（node/node-state.json）" \
  "$(compose exec -T node sh -c 'ls /var/lib/meshlan/node/node-state.json 2>/dev/null || true')" "node-state.json"

section "8. Node 真配对（本票的核心结论点）"

admin_session="$(curl -kfsS --max-time 10 -X POST \
  -H "X-MeshLAN-Admin-Token: $LH_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' -d '{}' \
  "https://127.0.0.1:$LH_HTTP_PORT/v1/admin/session" 2>/dev/null || true)"
LH_SESSION="$(printf '%s' "$admin_session" | jq -r '.sessionToken // empty' 2>/dev/null || true)"
assert_matches "用管理令牌换来管理会话（纯 curl，不需要点管理台页面）" "$LH_SESSION" '^[A-Za-z0-9_-]{16,}'

add_resp_file="$WORKDIR/add-node.json"
# 注意：不要在这里写 `|| echo "000"`——curl 失败时 -w 已经会打出 "000"，
# 两者叠加会得到 "000000"（第二次污染运行里就是这么显示的），断言就永远不可能对。
add_code="$(curl -ksS --max-time 40 -o "$add_resp_file" -w '%{http_code}' -X POST \
  -H "X-MeshLAN-Admin-Session: $LH_SESSION" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg e "$PAIR_HOST" --arg h "$NODE_HASH" --arg n "acceptance-node" '{endpoint:$e, hash:$h, name:$n}')" \
  "https://127.0.0.1:$LH_HTTP_PORT/v1/admin/nodes" 2>/dev/null)" || add_code="000"
add_body="$(cat "$add_resp_file" 2>/dev/null || true)"
assert_eq "POST /v1/admin/nodes 返回 201（主控真的连上了 Node）" "$add_code" "201"
if [ "$add_code" != "201" ]; then
  fail "加节点失败" "响应体：${add_body:0:600}（常见原因：主控到 ${PAIR_HOST}:${NODE_CTRL_PORT} 不通）"
fi

NODE_ID="$(printf '%s' "$add_body" | jq -r '.node.id // empty' 2>/dev/null || true)"
NODE_ADDR="$(printf '%s' "$add_body" | jq -r '.node.address // empty' 2>/dev/null || true)"
# allocateAddress 返回的是带前缀的 CIDR（10.77.0.2/24），不是裸 IP：它要原样签进 Nebula 证书。
# 这里断言"在网段内的 IPv4/CIDR"，而不是脚本自己能想到的裸地址形状。
assert_matches "主控分配了 Node 的虚拟地址（网段内的 IPv4/CIDR）" "$NODE_ADDR" '^10\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$'
assert_matches "主控记录了 Node 的公开端点（端口来自 Node 的 /v1/node/info）" \
  "$(printf '%s' "$add_body" | jq -r '.node.publicEndpoint // empty' 2>/dev/null || true)" ":$NODE_NEBULA_PORT"

wait_node_enrolled() {
  deadline=$((SECONDS + PAIR_TIMEOUT))
  body=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    body="$(curl -kfsS --max-time 10 "https://127.0.0.1:$NODE_CTRL_PORT/v1/node/health" 2>/dev/null || true)"
    if printf '%s' "$body" | jq -e '.enrolled == true and .nebulaRunning == true' >/dev/null 2>&1; then
      printf '%s' "$body"; return 0
    fi
    sleep 3
  done
  printf '%s' "$body"
  return 1
}

if node_health1="$(wait_node_enrolled)"; then
  pass "Node 侧 /v1/node/health 的 enrolled=true 且 nebulaRunning=true"
else
  fail "Node 在 ${PAIR_TIMEOUT}s 内没有转成 enrolled 且 nebulaRunning=true" "实际：${node_health1:-无响应}"
fi

wait_overview() {
  deadline=$((SECONDS + PAIR_TIMEOUT))
  body=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    body="$(curl -kfsS --max-time 10 -H "X-MeshLAN-Admin-Session: $LH_SESSION" \
      "https://127.0.0.1:$LH_HTTP_PORT/v1/admin/overview" 2>/dev/null || true)"
    if printf '%s' "$body" | jq -e --arg id "$NODE_ID" '.nodes[] | select(.id == $id) | (.online == true and .nebulaRunning == true)' >/dev/null 2>&1; then
      printf '%s' "$body"; return 0
    fi
    sleep 3
  done
  printf '%s' "$body"
  return 1
}

if overview="$(wait_overview)"; then
  pass "主控状态里该节点 Online=true 且 NebulaRunning=true（15s 轮询写回）"
  assert_eq "主控自己容器内的 Nebula 也在跑（配对靠的是真进程，不是假绿）" \
    "$(printf '%s' "$overview" | jq -r '.server.nebulaRunning' 2>/dev/null || echo missing)" "true"
else
  fail "主控状态在 ${PAIR_TIMEOUT}s 内没有把该节点标成 Online/NebulaRunning" \
       "实际：$(printf '%s' "${overview:-}" | jq -c --arg id "$NODE_ID" '.nodes[]? | select(.id == $id)' 2>/dev/null || echo 无)"
fi

pubkey="$(compose exec -T lighthouse sh -c 'nebula-cert keygen -out-key /tmp/hb.key -out-pub /tmp/hb.pub >/dev/null 2>&1 && cat /tmp/hb.pub; rm -f /tmp/hb.key /tmp/hb.pub' 2>/dev/null || true)"
assert_contains "用真 nebula-cert 生成了一次性设备公钥（心跳要真公钥）" "$pubkey" "NEBULA"

pair_payload="$(printf '%s' "$LH_PAIR_HASH" | sed 's/^MLN1\.//' | jq -R 'gsub("-";"+")|gsub("_";"/")|@base64d|fromjson' 2>/dev/null || true)"
pair_id="$(printf '%s' "$pair_payload" | jq -r '.i // empty' 2>/dev/null || true)"
pair_secret="$(printf '%s' "$pair_payload" | jq -r '.s // empty' 2>/dev/null || true)"
assert_matches "解析出配对哈希里的 enrollment id" "$pair_id" '^[A-Za-z0-9_-]{8,}$'

pair_resp="$(curl -kfsS --max-time 30 -X POST \
  -H "Authorization: MeshLAN $pair_secret" \
  -H "X-MeshLAN-Enrollment: $pair_id" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg n "acceptance-device" --arg k "$pubkey" '{version:2, name:$n, publicKeyPem:$k}')" \
  "https://127.0.0.1:$LH_HTTP_PORT/v1/pair" 2>/dev/null || true)"
device_token="$(printf '%s' "$pair_resp" | jq -r '.deviceToken // empty' 2>/dev/null || true)"
assert_matches "用 MLN1 配对哈希换到设备令牌（配对流程本身可用）" "$device_token" '^[A-Za-z0-9_-]{16,}'

hb_resp="$(curl -kfsS --max-time 20 -X POST \
  -H "Authorization: MeshLAN-Device acceptance-device:$device_token" \
  -H 'Content-Type: application/json' \
  -d '{"name":"acceptance-device","bytesReceived":0,"bytesSent":0,"serviceRunning":false,"clientVersion":"acceptance"}' \
  "https://127.0.0.1:$LH_HTTP_PORT/v1/heartbeat" 2>/dev/null || true)"
assert_eq "心跳被接受（设备凭据有效）" "$(printf '%s' "$hb_resp" | jq -r '.ok // "missing"' 2>/dev/null || echo missing)" "true"
assert_true "$(printf '%s' "$hb_resp" | jq -e --arg id "$NODE_ID" '.lighthouses // [] | any(.id == $id)' >/dev/null 2>&1 && echo 1 || echo 0)" \
  "客户端心跳响应里的 lighthouse 列表包含该 Node" \
  "实际列表：$(printf '%s' "$hb_resp" | jq -c '.lighthouses // []' 2>/dev/null | head -c 500)"

section "9. 收尾"

if [ "$FAIL" -eq 0 ]; then
  if compose --profile node down -v --remove-orphans >/dev/null 2>&1; then
    pass "自清理：测试栈与命名卷已删除，宿主不留残骸"
  else
    fail "自清理失败" "请手工执行：docker compose -p $PROJECT -f $BASE_COMPOSE -f $OVERRIDE_COMPOSE --profile node down -v"
  fi
  leftovers="$(docker ps -a --format '{{.Names}}' | grep -E "^$PROJECT-" || true)"
  assert_eq "没有残留的验收容器" "$leftovers" ""
else
  info "有失败项，按 KEEP_ON_FAIL=$KEEP_ON_FAIL 决定是否保留现场"
fi

section "汇总"

printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
for row in ${RESULTS[@]+"${RESULTS[@]}"}; do
  case "$row" in
    PASS\|*) printf '  %s[PASS]%s %s\n' "$c_green" "$c_reset" "${row#PASS|}" ;;
    FAIL\|*) printf '  %s[FAIL]%s %s\n' "$c_red" "$c_reset" "${row#FAIL|}" ;;
  esac
done

cat <<'CLOSING'

可失败性（#8 的测试口径：每条断言的「通过」都要能指出哪条决策被违背时它会变红）

  构建成功                  <- 构建上下文白名单漏了 cmd/meshlan/admin，或断言写成依赖退出码
  最终层无密钥材料          <- 构建期把状态文件/私钥带进镜像（#7 密钥边界被违背）
  端口 1:1                  <- compose 改成端口翻译映射（Node 宣称的端点会被主控原样取用）
  stop_grace_period 30s     <- 宽限期被调小，或入口没 exec（PID 1 被 shell 吞掉信号）
  健康转绿                  <- 探针指向需要认证的端点，或没检查 Content-Type（假绿/恒红）
  0600 + uid 10001          <- 入口没走 root -> chown -> setpriv
  PID 1 = meshlan           <- 入口引入信号代理或常驻 shell
  CA 指纹读得到（64 位十六进制）<- 状态文件里没有 httpsCaFingerprint；这时下面两条"不变"必须判红，
                               而不是拿两个相同的错误值假装相等（首版就是这么假绿的）
  CA 指纹跨 recreate 不变   <- 同上，且 --force-recreate 被误当成「重建 PKI」
  历史库非空                <- 状态根没落到卷，或半截落盘
  缺地址 fail-fast          <- 入口开始猜 localhost 或探测出口地址
  非法角色 fail-fast        <- 角色校验被放宽成一个沉默的错误部署
  INIT_ONLY 正常退出        <- 入口在只初始化模式下继续启动服务；
                               也可能是本脚本没给够权限（入口要 setcap，bounding set 缺
                               NET_ADMIN 时打 cap 的二进制 exec 会被拒，见 #7 能力矩阵第 I 行）
  Node 起得来               <- Node 与 Lighthouse 共用状态目录（身份互相污染）
  POST /v1/admin/nodes 201  <- 主控到 Node 的 18090 不通（host.docker.internal 没配）、
                               pin 校验被关掉，或 Node 已 enrolled
  enrolled/nebulaRunning    <- enroll 处理器没写 node.crt/ca.crt/node.yml，或没拉起 Nebula
  主控 Online/NebulaRunning <- 15s 轮询器没工作，或状态没写回
  客户端列表含该 Node       <- meshNodeEndpoints 的 Online && NebulaRunning 门槛被改松

不在本脚本断言范围内的东西（别把它们读成「已验证」）
  - 停机的退出码：只打印，不断言（ADR-0001；容器 init 受 SIGNAL_UNKILLABLE 保护）。
  - Nebula 数据面是否真的成隧道：nebulaRunning 是进程级判据，两台容器之间的
    UDP 4242/14242 有没有打通，本脚本不证。
  - arm64 实跑、跨主机 Node、CI 集成。
CLOSING

if [ "$FAIL" -gt 0 ]; then
  echo
  echo "结论：验收未通过（$FAIL 项失败）。票保持 open，不要把这一段说成跑通。"
  exit 1
fi

echo
echo "结论：验收通过。把上面整段输出原样贴进票里（含实测退出码与耗时），不要美化。"
exit 0
