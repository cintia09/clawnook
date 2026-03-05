#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_REPO="${OPENCLAW_REPO:-openclaw/openclaw}"
TARGET_TAG="${TARGET_TAG:-}"
API_BASE="${API_BASE:-http://127.0.0.1:3000}"
TASK_TIMEOUT_SEC="${TASK_TIMEOUT_SEC:-2400}"
TASK_POLL_SEC="${TASK_POLL_SEC:-5}"
GATEWAY_READY_TIMEOUT_SEC="${GATEWAY_READY_TIMEOUT_SEC:-180}"
MAX_FIX_ATTEMPTS="${MAX_FIX_ATTEMPTS:-2}"

STATE_DIR="/root/.openclaw/release-monitor"
mkdir -p "$STATE_DIR"

log() { echo "[$(date '+%F %T')] $*"; }
fail() { log "ERROR: $*"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

need_cmd curl
need_cmd jq
need_cmd node

sign_cookie() {
  local secret
  secret="$(jq -r '.webAuth.secret // ""' /root/.openclaw/docker-config.json 2>/dev/null || true)"
  [ -n "$secret" ] || return 1
  node - "$secret" <<'NODE'
const crypto = require('crypto');
const secret = process.argv[2] || '';
const b64u = (s) => Buffer.from(s).toString('base64').replace(/=/g,'').replace(/\+/g,'-').replace(/\//g,'_');
const payload = b64u(JSON.stringify({u:'admin', exp: Date.now() + 2*60*60*1000}));
const sig = b64u(crypto.createHmac('sha256', secret).update(payload).digest());
process.stdout.write(`${payload}.${sig}`);
NODE
}

api_authed() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local cookie
  cookie="$(sign_cookie)" || return 2
  if [ -n "$body" ]; then
    curl -fsS -H "Cookie: oc_session=$cookie" -H "Content-Type: application/json" -X "$method" "$API_BASE$path" -d "$body"
  else
    curl -fsS -H "Cookie: oc_session=$cookie" -X "$method" "$API_BASE$path"
  fi
}

restart_web_if_needed() {
  if curl -fsS --max-time 3 "$API_BASE/" >/dev/null 2>&1; then
    return 0
  fi
  log "web panel unreachable, restarting /opt/openclaw-web/server.js"
  local pid
  pid="$(ps -eo pid,args | awk '$2=="node" && $3=="/opt/openclaw-web/server.js" {print $1; exit}')"
  if [ -n "${pid:-}" ]; then
    kill -9 "$pid" >/dev/null 2>&1 || true
  fi
  nohup node /opt/openclaw-web/server.js >/root/.openclaw/logs/web-panel.log 2>&1 < /dev/null &
  sleep 2
  curl -fsS --max-time 5 "$API_BASE/" >/dev/null 2>&1 || fail "web panel restart failed"
}

ensure_watchdog() {
  pgrep -f "[o]penclaw-gateway-watchdog.sh" >/dev/null 2>&1 && return 0
  log "watchdog not running, starting..."
  nohup bash /usr/local/bin/openclaw-gateway-watchdog.sh >/root/.openclaw/logs/gateway-watchdog.log 2>&1 < /dev/null &
  sleep 1
  pgrep -f "[o]penclaw-gateway-watchdog.sh" >/dev/null 2>&1 || fail "watchdog start failed"
}

gateway_health_code() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:18789/health || true
}

wait_gateway_ready() {
  local waited=0
  while [ "$waited" -lt "$GATEWAY_READY_TIMEOUT_SEC" ]; do
    local code
    code="$(gateway_health_code)"
    if [ "$code" = "200" ] || [ "$code" = "401" ] || [ "$code" = "403" ]; then
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}

poll_install_task() {
  local task_id="$1"
  local waited=0
  while [ "$waited" -lt "$TASK_TIMEOUT_SEC" ]; do
    local json status
    json="$(api_authed GET "/api/openclaw/install/$task_id")" || return 2
    status="$(echo "$json" | jq -r '.status // ""')"
    if [ "$status" = "success" ]; then
      return 0
    fi
    if [ "$status" = "failed" ]; then
      echo "$json" | jq -r '.log // ""' | tail -n 120 >&2 || true
      return 1
    fi
    sleep "$TASK_POLL_SEC"
    waited=$((waited + TASK_POLL_SEC))
  done
  return 3
}

run_upgrade() {
  restart_web_if_needed
  ensure_watchdog

  local st installed endpoint resp task_id
  st="$(api_authed GET '/api/openclaw')" || fail "cannot read /api/openclaw"
  installed="$(echo "$st" | jq -r '.installed // false')"

  if [ "$installed" = "true" ]; then
    endpoint="/api/openclaw/update"
  else
    endpoint="/api/openclaw/install"
  fi

  log "trigger upgrade endpoint: $endpoint (target=$TARGET_TAG repo=$OPENCLAW_REPO)"
  resp="$(api_authed POST "$endpoint")" || fail "trigger $endpoint failed"
  task_id="$(echo "$resp" | jq -r '.taskId // ""')"
  [ -n "$task_id" ] || fail "no taskId from $endpoint"

  log "polling task: $task_id"
  if ! poll_install_task "$task_id"; then
    fail "install/update task failed or timeout"
  fi

  log "request gateway restart"
  api_authed POST '/api/openclaw/start' >/dev/null || fail "gateway restart api failed"

  if ! wait_gateway_ready; then
    fail "gateway not ready after restart"
  fi
}

regression_check() {
  restart_web_if_needed
  ensure_watchdog

  local st health
  st="$(api_authed GET '/api/openclaw')" || return 1

  echo "$st" | jq -e '.installed != null and .gatewayRunning != null and .installTaskRunning != null and .repairTaskRunning != null and .gatewayRestartRunning != null' >/dev/null
  api_authed GET '/api/openclaw/config/backups' | jq -e '.success == true and (.backups | type == "array")' >/dev/null

  pgrep -f "[o]penclaw-gateway-watchdog.sh" >/dev/null 2>&1 || return 1

  health="$(gateway_health_code)"
  [ "$health" = "200" ] || [ "$health" = "401" ] || [ "$health" = "403" ] || return 1

  return 0
}

auto_fix_once() {
  log "auto-fix: restart web + watchdog + trigger gateway start"

  local web_pid
  web_pid="$(ps -eo pid,args | awk '$2=="node" && $3=="/opt/openclaw-web/server.js" {print $1; exit}')"
  if [ -n "${web_pid:-}" ]; then
    kill -9 "$web_pid" >/dev/null 2>&1 || true
  fi
  nohup node /opt/openclaw-web/server.js >/root/.openclaw/logs/web-panel.log 2>&1 < /dev/null &

  pkill -f "[o]penclaw-gateway-watchdog.sh" >/dev/null 2>&1 || true
  nohup bash /usr/local/bin/openclaw-gateway-watchdog.sh >/root/.openclaw/logs/gateway-watchdog.log 2>&1 < /dev/null &

  sleep 2
  api_authed POST '/api/openclaw/start' >/dev/null 2>&1 || true
  sleep 3
}

main() {
  log "remote update+test start: repo=$OPENCLAW_REPO tag=${TARGET_TAG:-latest}"

  run_upgrade

  if regression_check; then
    log "regression check passed"
    jq -n --arg repo "$OPENCLAW_REPO" --arg tag "$TARGET_TAG" --arg at "$(date -Iseconds)" '{repo:$repo,tag:$tag,updatedAt:$at,status:"success"}' > "$STATE_DIR/last-success.json"
    exit 0
  fi

  local attempt=1
  while [ "$attempt" -le "$MAX_FIX_ATTEMPTS" ]; do
    log "regression failed, auto-fix attempt $attempt/$MAX_FIX_ATTEMPTS"
    auto_fix_once
    if regression_check; then
      log "regression passed after auto-fix"
      jq -n --arg repo "$OPENCLAW_REPO" --arg tag "$TARGET_TAG" --arg at "$(date -Iseconds)" '{repo:$repo,tag:$tag,updatedAt:$at,status:"success-after-fix"}' > "$STATE_DIR/last-success.json"
      exit 0
    fi
    attempt=$((attempt + 1))
  done

  fail "regression still failing after auto-fix attempts"
}

main "$@"
