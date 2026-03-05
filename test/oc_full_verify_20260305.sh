#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

REMOTE_HOST="${REMOTE_HOST:-wm_20@192.168.31.107}"
REMOTE_PORT="${REMOTE_PORT:-2223}"
OC_USER="${OC_USER:-}"
OC_PASS="${OC_PASS:-}"
REMOTE_TMP_DIR="${REMOTE_TMP_DIR:-/root/.openclaw/test-tmp}"

echo "[local] run full verify against ${REMOTE_HOST}:${REMOTE_PORT}"

ssh -T -p "$REMOTE_PORT" "$REMOTE_HOST" 'sudo -n bash -s' <<'REMOTE_SCRIPT'
set -euo pipefail
TMP_DIR="/root/.openclaw/test-tmp"
mkdir -p "$TMP_DIR"

echo "=== A. 依赖审计（镜像内） ==="
req_bins=(bash node npm pnpm git curl jq tar gzip)
missing=0
for b in "${req_bins[@]}"; do
  if command -v "$b" >/dev/null 2>&1; then
    echo "dep_${b}=ok ($(command -v "$b"))"
  else
    echo "dep_${b}=missing"
    missing=1
  fi
done

echo "=== B. OpenClaw 路径合规 ==="
paths=(
  /root/.openclaw
  /root/.openclaw/logs
  /root/.openclaw/cache/openclaw
  /root/.openclaw/locks
  /root/.openclaw/openclaw-source
  /root/.openclaw/openclaw-source/openclaw.mjs
  /root/.openclaw/openclaw.json
  /usr/local/bin/openclaw-gateway-watchdog.sh
  /usr/local/bin/start-services.sh
)
for p in "${paths[@]}"; do
  if [ -e "$p" ]; then
    echo "path_ok=$p"
  else
    echo "path_missing=$p"
    missing=1
  fi
done

echo "=== C. 旧持久化目录启动验证（存在 openclaw-source） ==="
pkill -f openclaw-gateway-watchdog.sh >/dev/null 2>&1 || true
sleep 1
nohup bash /usr/local/bin/openclaw-gateway-watchdog.sh >/dev/null 2>&1 &
for i in $(seq 1 40); do
  code=$(curl -s -o "$TMP_DIR/oc_h.out" -w '%{http_code}' http://127.0.0.1:18789/health || true)
  if [ "$code" = "200" ]; then
    echo "old_persist_health_ok_try=$i"
    break
  fi
  sleep 2
  if [ "$i" = "40" ]; then
    echo "old_persist_health_fail_code=$code"
    tail -n 100 /root/.openclaw/logs/gateway-watchdog.log || true
    missing=1
  fi
done

echo "=== D. 新持久化目录启动模拟（source 缺失后自动补全） ==="
TS=$(date +%s)
SRC=/root/.openclaw/openclaw-source
BAK=/root/.openclaw/openclaw-source.bak.$TS
WKS=/root/.openclaw/openclaw
SEED_TEST_DIR=/root/.openclaw/openclaw-source.seed-test.$TS
mkdir -p /root/.openclaw /root/.openclaw/logs /root/.openclaw/cache/openclaw /root/.openclaw/locks /root/.openclaw/home
NPM_ROOT=$(npm root -g 2>/dev/null || true)
PKG_DIR="$NPM_ROOT/openclaw"
if [ -d "$PKG_DIR" ] && [ -f "$PKG_DIR/openclaw.mjs" ]; then
  mkdir -p "$SEED_TEST_DIR"
  cp -f "$PKG_DIR/openclaw.mjs" "$SEED_TEST_DIR/openclaw.mjs" >/dev/null 2>&1 || true
  if [ -f "$SEED_TEST_DIR/openclaw.mjs" ] || [ -f "$PKG_DIR/openclaw.mjs" ]; then
    echo "seed_from_global_pkg=ok"
  else
    echo "seed_from_global_pkg=missing_after_copy"
  fi
else
  echo "seed_from_global_pkg=missing"
fi

pkill -f openclaw-gateway-watchdog.sh >/dev/null 2>&1 || true
sleep 1
nohup bash /usr/local/bin/openclaw-gateway-watchdog.sh >/dev/null 2>&1 &
for i in $(seq 1 40); do
  code=$(curl -s -o "$TMP_DIR/oc_h2.out" -w '%{http_code}' http://127.0.0.1:18789/health || true)
  if [ "$code" = "200" ]; then
    echo "new_persist_health_ok_try=$i"
    break
  fi
  sleep 2
  if [ "$i" = "40" ]; then
    echo "new_persist_health_fail_code=$code"
    tail -n 100 /root/.openclaw/logs/gateway-watchdog.log || true
    missing=1
  fi
done

if [ -f /root/.openclaw/openclaw-source/openclaw.mjs ]; then
  echo "source_recovered=ok"
else
  echo "source_recovered=missing"
  missing=1
fi

rm -rf "$SEED_TEST_DIR" >/dev/null 2>&1 || true
pkill -f openclaw-gateway-watchdog.sh >/dev/null 2>&1 || true
sleep 1
nohup bash /usr/local/bin/openclaw-gateway-watchdog.sh >/dev/null 2>&1 &
echo "restore_old_persist=ok"

echo "=== E. Web/API 基础可用性 ==="
code_web=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/ || true)
code_health=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18789/health || true)
echo "web_code=$code_web"
echo "health_code=$code_health"

if [ "$missing" = "1" ]; then
  echo "verify_result=FAIL"
  exit 2
fi

echo "verify_result=PASS"
REMOTE_SCRIPT

if [[ -n "$OC_USER" && -n "$OC_PASS" ]]; then
  echo "[local] 尝试执行安装/更新/重启 API 联验（带登录）"
  COOKIE_JAR="$LOG_DIR/oc_cookie_20260305.txt"
  rm -f "$COOKIE_JAR"
  curl -sS -c "$COOKIE_JAR" -H 'content-type: application/json' \
    -d "{\"username\":\"$OC_USER\",\"password\":\"$OC_PASS\"}" \
    "http://127.0.0.1:3000/api/login" | sed 's/^/[login] /'
  curl -sS -b "$COOKIE_JAR" "http://127.0.0.1:3000/api/openclaw" | sed 's/^/[status] /'
  curl -sS -b "$COOKIE_JAR" -X POST "http://127.0.0.1:3000/api/openclaw/start" | sed 's/^/[restart] /'
  curl -sS -b "$COOKIE_JAR" "http://127.0.0.1:3000/api/openclaw/gateway/logs?lines=80" | sed 's/^/[gwlog] /'
else
  echo "[local] 跳过安装/更新/重启按钮 API 联验（未提供 OC_USER/OC_PASS）"
fi
