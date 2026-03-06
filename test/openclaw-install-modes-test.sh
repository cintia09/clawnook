#!/usr/bin/env bash
set -euo pipefail

API_BASE="${API_BASE:-http://127.0.0.1:3000}"
TASK_TIMEOUT_SEC="${TASK_TIMEOUT_SEC:-3600}"
TASK_POLL_SEC="${TASK_POLL_SEC:-5}"
GATEWAY_READY_TIMEOUT_SEC="${GATEWAY_READY_TIMEOUT_SEC:-180}"
WEB_READY_TIMEOUT_SEC="${WEB_READY_TIMEOUT_SEC:-180}"
INSTALL_MODES="${INSTALL_MODES:-release,npm,source}"

log() { echo "[$(date '+%F %T')] $*"; }
fail() { log "ERROR: $*"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

need_cmd curl
need_cmd jq
need_cmd node

sign_cookie() {
  local secret users_json
  secret="$(jq -r '.webAuth.secret // ""' /root/.openclaw/docker-config.json 2>/dev/null || true)"
  users_json="$(jq -c '.webAuth.users // {}' /root/.openclaw/docker-config.json 2>/dev/null || true)"
  [ -n "$secret" ] || return 1
  [ -n "$users_json" ] || users_json='{}'
  node - "$secret" "$users_json" <<'NODE'
const crypto = require('crypto');
const secret = process.argv[2] || '';
const users = JSON.parse(process.argv[3] || '{}');
const userNames = Object.keys(users || {});
const loginUser = userNames.includes('admin') ? 'admin' : (userNames[0] || 'admin');
const b64u = (s) => Buffer.from(s).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
const payload = b64u(JSON.stringify({ u: loginUser, exp: Date.now() + 2 * 60 * 60 * 1000 }));
const sig = b64u(crypto.createHmac('sha256', secret).update(payload).digest());
process.stdout.write(`${payload}.${sig}`);
NODE
}

COOKIE="$(sign_cookie)" || fail "cannot build auth cookie"

api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  if [ -n "$body" ]; then
    curl --noproxy '*' -fsS -H "Cookie: oc_session=$COOKIE" -H "Content-Type: application/json" -X "$method" "$API_BASE$path" -d "$body"
  else
    curl --noproxy '*' -fsS -H "Cookie: oc_session=$COOKIE" -X "$method" "$API_BASE$path"
  fi
}

get_web_pid() {
  pgrep -f "node .*server\\.js" 2>/dev/null | head -1 || true
}

web_api_health_code() {
  curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --max-time 3 -H "Cookie: oc_session=$COOKIE" "$API_BASE/api/openclaw" || true
}

wait_web_ready() {
  local waited=0
  while [ "$waited" -lt "$WEB_READY_TIMEOUT_SEC" ]; do
    local code
    code="$(web_api_health_code)"
    if [ "$code" = "200" ]; then
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

gateway_health_code() {
  curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:18789/health || true
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

wait_watchdog_ready() {
  local waited=0
  while [ "$waited" -lt "$GATEWAY_READY_TIMEOUT_SEC" ]; do
    if pgrep -f "[o]penclaw-gateway-watchdog.sh" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

poll_task_with_web_stability() {
  local task_id="$1"
  local mode="$2"
  local web_pid_before="$3"
  local waited=0
  while [ "$waited" -lt "$TASK_TIMEOUT_SEC" ]; do
    local json status web_pid_now
    json="$(api GET "/api/openclaw/install/$task_id")"
    status="$(echo "$json" | jq -r '.status // ""')"
    web_pid_now="$(get_web_pid)"
    if [ -n "$web_pid_before" ] && [ -n "$web_pid_now" ] && [ "$web_pid_now" != "$web_pid_before" ] && [ "$status" = "running" ]; then
      fail "mode=$mode task running期间 web 进程发生重启 (before=$web_pid_before now=$web_pid_now)"
    fi
    if [ "$status" = "success" ]; then
      echo "$json"
      return 0
    fi
    if [ "$status" = "failed" ]; then
      echo "$json" | jq -r '.log // ""' | tail -n 120 >&2 || true
      fail "mode=$mode task failed"
    fi
    sleep "$TASK_POLL_SEC"
    waited=$((waited + TASK_POLL_SEC))
  done
  fail "mode=$mode task timeout after ${TASK_TIMEOUT_SEC}s"
}

trigger_mode() {
  local mode="$1"
  local st installed endpoint web_pid_before resp task_id final_json start_resp start_ok

  st="$(api GET '/api/openclaw')"
  installed="$(echo "$st" | jq -r '.installed // false')"
  endpoint="/api/openclaw/update"
  if [ "$installed" != "true" ]; then
    endpoint="/api/openclaw/install"
  fi

  web_pid_before="$(get_web_pid)"
  [ -n "$web_pid_before" ] || fail "mode=$mode web panel pid not found"

  log "mode=$mode trigger endpoint=$endpoint"
  resp="$(api POST "$endpoint" "{\"mode\":\"$mode\"}")"
  task_id="$(echo "$resp" | jq -r '.taskId // ""')"
  [ -n "$task_id" ] || fail "mode=$mode missing taskId response=$resp"

  final_json="$(poll_task_with_web_stability "$task_id" "$mode" "$web_pid_before")"
  local final_log
  final_log="$(echo "$final_json" | jq -r '.log // ""')"
  if ! grep -Fq "[openclaw] install mode: ${mode}" <<<"$final_log"; then
    fail "mode=$mode task log missing install mode marker"
  fi

  start_resp="$(api POST '/api/openclaw/start')"
  start_ok="$(echo "$start_resp" | jq -r '.success // false')"
  [ "$start_ok" = "true" ] || fail "mode=$mode restart api failed: $start_resp"

  if ! wait_watchdog_ready; then
    fail "mode=$mode watchdog not ready after restart trigger"
  fi

  if ! wait_gateway_ready; then
    fail "mode=$mode gateway not ready after restart"
  fi

  pgrep -f "[o]penclaw-gateway-watchdog.sh" >/dev/null 2>&1 || fail "mode=$mode watchdog not running"
  log "mode=$mode passed"
}

main() {
  local raw mode
  if ! wait_web_ready; then
    fail "web api not ready within ${WEB_READY_TIMEOUT_SEC}s"
  fi
  IFS=',' read -r -a raw <<<"$INSTALL_MODES"
  [ "${#raw[@]}" -gt 0 ] || fail "INSTALL_MODES empty"

  for mode in "${raw[@]}"; do
    mode="$(echo "$mode" | xargs)"
    [ -n "$mode" ] || continue
    case "$mode" in
      auto|release|npm|source) ;;
      *) fail "unsupported mode: $mode" ;;
    esac
    trigger_mode "$mode"
  done

  log "all modes passed: $INSTALL_MODES"
}

main "$@"
