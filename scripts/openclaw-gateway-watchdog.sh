#!/bin/bash
set -u

LOG_DIR="/root/.openclaw/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/gateway-watchdog.log"
GATEWAY_LOG="$LOG_DIR/gateway.log"

CHECK_INTERVAL=30
POLL_INTERVAL=5
STARTUP_TIMEOUT=180
MAX_RETRIES=3
BACKOFF_WAIT=300
PORT=18789
MAX_LOG_LINES=5000

LOCK_DIR="/tmp/openclaw-gateway-watchdog.lock"
LOCK_PID_FILE="$LOCK_DIR/pid"

CONSECUTIVE_FAILURES=0
LAST_PID=""

HOME="${HOME:-/root}"
export HOME
export DISPLAY=:99

if [[ ":$PATH:" != *":/root/.npm-global/bin:"* ]]; then
  export PATH="$PATH:/root/.npm-global/bin"
fi
if [[ ":$PATH:" != *":/usr/local/bin:"* ]]; then
  export PATH="$PATH:/usr/local/bin"
fi

OPENCLAW_BIN=""
OPENCLAW_CMD_BASE=""
OPENCLAW_RUNTIME_JS="/opt/openclaw-runtime/node_modules/openclaw/openclaw.mjs"

resolve_openclaw_bin() {
  if command -v node >/dev/null 2>&1 && [[ -f "$OPENCLAW_RUNTIME_JS" ]]; then
    OPENCLAW_BIN="$OPENCLAW_RUNTIME_JS"
    OPENCLAW_CMD_BASE="node $OPENCLAW_RUNTIME_JS"
    return 0
  fi

  if command -v openclaw >/dev/null 2>&1; then
    OPENCLAW_BIN="$(command -v openclaw)"
    OPENCLAW_CMD_BASE="$OPENCLAW_BIN"
    return 0
  fi
  if [[ -x "/root/.npm-global/bin/openclaw" ]]; then
    OPENCLAW_BIN="/root/.npm-global/bin/openclaw"
    OPENCLAW_CMD_BASE="$OPENCLAW_BIN"
    return 0
  fi
  if [[ -x "/usr/local/bin/openclaw" ]]; then
    OPENCLAW_BIN="/usr/local/bin/openclaw"
    OPENCLAW_CMD_BASE="$OPENCLAW_BIN"
    return 0
  fi
  OPENCLAW_BIN=""
  OPENCLAW_CMD_BASE=""
  return 1
}

GATEWAY_CMD=""

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

get_gateway_pids() {
  {
    pgrep -f "[o]penclaw-gateway$" 2>/dev/null || true
    pgrep -f "[o]penclaw gateway run" 2>/dev/null || true
  } | sort -u
}

get_gateway_pid() {
  local pid
  pid=$(get_gateway_pids | head -1)
  if [[ -n "$pid" ]]; then
    echo "$pid"
    return
  fi

  for pid in $(pgrep -x "openclaw" 2>/dev/null || true); do
    [[ "$(cat /proc/$pid/comm 2>/dev/null)" == "bash" ]] && continue
    echo "$pid"
    return
  done
}

is_gateway_process_alive() {
  if [[ -n "$LAST_PID" ]] && kill -0 "$LAST_PID" 2>/dev/null; then
    return 0
  fi
  [[ -n "$(get_gateway_pid)" ]]
}

is_gateway_pid_blocked_d_state() {
  local pid state
  pid=$(get_gateway_pid)
  [[ -z "$pid" ]] && return 1
  state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')
  [[ "$state" == D* ]]
}

is_port_listening() {
  if command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | grep -q ":${PORT} "
    if [[ $? -eq 0 ]]; then
      return 0
    fi
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | grep -q ":${PORT} "
    if [[ $? -eq 0 ]]; then
      return 0
    fi
  fi

  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
      return 0
    fi
  fi

  if command -v curl >/dev/null 2>&1; then
    curl -fsS --connect-timeout 2 --max-time 3 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 && return 0
  fi

  return 1
}

dedupe_gateway_processes() {
  local pids keep
  pids=$(get_gateway_pids)
  [[ -z "$pids" ]] && return 0

  keep=$(echo "$pids" | tail -1)
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    if [[ "$pid" != "$keep" ]]; then
      kill -9 "$pid" 2>/dev/null || true
      log "Killed duplicate gateway process PID=$pid, keep PID=$keep"
    fi
  done <<< "$pids"
}

kill_gateway() {
  local pid waited
  pid=$(get_gateway_pid)
  if [[ -z "$pid" && -n "$LAST_PID" ]] && kill -0 "$LAST_PID" 2>/dev/null; then
    pid="$LAST_PID"
  fi

  if [[ -n "$pid" ]]; then
    log "Killing gateway (PID $pid)"
    kill -TERM "$pid" 2>/dev/null || true
    pkill -TERM -P "$pid" 2>/dev/null || true
    waited=0
    while [[ $waited -lt 5 ]] && kill -0 "$pid" 2>/dev/null; do
      sleep 1
      waited=$((waited + 1))
    done
  fi

  pkill -9 -x "openclaw-gatewa" 2>/dev/null || true
  pkill -9 -x "openclaw" 2>/dev/null || true
  pkill -9 -f "[o]penclaw gateway run" 2>/dev/null || true
  pkill -9 -f "[o]penclaw-gateway$" 2>/dev/null || true
  if [[ -n "$LAST_PID" ]]; then
    kill -9 "$LAST_PID" 2>/dev/null || true
  fi
  LAST_PID=""
  sleep 2
}

wait_for_ready() {
  local timeout=$1
  local elapsed=0
  local last_log=0

  while [[ $elapsed -lt $timeout ]]; do
    if is_port_listening; then
      return 0
    fi

    if ! is_gateway_process_alive; then
      log "Gateway process exited during startup (after ${elapsed}s)"
      return 1
    fi

    if is_gateway_pid_blocked_d_state; then
      log "Gateway process entered D-state during startup (after ${elapsed}s)"
      return 1
    fi

    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))

    if [[ $((elapsed - last_log)) -ge 60 ]]; then
      log "Startup in progress... ${elapsed}s/${timeout}s"
      last_log=$elapsed
    fi
  done

  return 1
}

start_gateway() {
  if ! resolve_openclaw_bin; then
    log "Cannot start gateway: openclaw CLI not found"
    return 1
  fi
  GATEWAY_CMD="$OPENCLAW_CMD_BASE gateway run --allow-unconfigured --force"

  if is_gateway_process_alive; then
    kill_gateway
  fi

  log "Starting gateway..."
  : > "$GATEWAY_LOG"

  nohup bash -lc "$GATEWAY_CMD" > "$GATEWAY_LOG" 2>&1 &
  LAST_PID=$!

  log "Gateway process launched (PID $LAST_PID), polling every ${POLL_INTERVAL}s (timeout ${STARTUP_TIMEOUT}s)..."

  if wait_for_ready "$STARTUP_TIMEOUT"; then
    local actual_pid
    actual_pid=$(get_gateway_pid)
    log "Gateway started successfully (port $PORT listening, PID ${actual_pid:-$LAST_PID})"
    CONSECUTIVE_FAILURES=0
    return 0
  fi

  log "ERROR: Gateway failed to start within ${STARTUP_TIMEOUT}s"
  if [[ -f "$GATEWAY_LOG" ]]; then
    local tail_log
    tail_log=$(tail -5 "$GATEWAY_LOG" 2>/dev/null | tr '\n' ' ')
    [[ -n "$tail_log" ]] && log "  Last output: $tail_log"
  fi
  CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
  kill_gateway
  return 1
}

handle_restart() {
  if [[ $CONSECUTIVE_FAILURES -ge $MAX_RETRIES ]]; then
    log "ALERT: ${CONSECUTIVE_FAILURES} consecutive failures — backing off ${BACKOFF_WAIT}s before retry"
    sleep "$BACKOFF_WAIT"
    CONSECUTIVE_FAILURES=0
  fi

  start_gateway
}

trim_log() {
  if [[ -f "$LOG_FILE" ]]; then
    local lines
    lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [[ "$lines" -gt "$MAX_LOG_LINES" ]]; then
      tail -n "$((MAX_LOG_LINES / 2))" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
  fi
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_PID_FILE"
    return 0
  fi

  local old_pid
  old_pid=""
  if [[ -f "$LOCK_PID_FILE" ]]; then
    old_pid=$(cat "$LOCK_PID_FILE" 2>/dev/null || true)
  fi

  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
    local cmdline
    cmdline=$(ps -o args= -p "$old_pid" 2>/dev/null || true)
    if echo "$cmdline" | grep -q "openclaw-gateway-watchdog.sh"; then
      log "Another watchdog instance detected (pid=$old_pid), exiting"
      return 1
    fi
  fi

  log "Detected stale watchdog lock, cleaning up"
  rm -rf "$LOCK_DIR" >/dev/null 2>&1 || true
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_PID_FILE"
    return 0
  fi

  log "Failed to acquire watchdog lock, exiting"
  return 1
}

if ! acquire_lock; then
  exit 0
fi
trap 'rm -rf "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT

log "Watchdog v2 started (check=${CHECK_INTERVAL}s, poll=${POLL_INTERVAL}s, timeout=${STARTUP_TIMEOUT}s, port=$PORT)"

while true; do
  if ! resolve_openclaw_bin; then
    log "openclaw CLI not found, watchdog idle"
    sleep "$CHECK_INTERVAL"
    continue
  fi

  dedupe_gateway_processes

  if ! is_gateway_process_alive; then
    log "Gateway is DOWN — restarting"
    handle_restart
  elif ! is_port_listening; then
    pid=$(get_gateway_pid)
    [[ -z "$pid" ]] && pid="$LAST_PID"
    uptime=0
    if [[ -n "$pid" ]]; then
      uptime=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
      uptime=${uptime:-0}
    fi

    if is_gateway_pid_blocked_d_state; then
      log "Gateway stuck in D-state (uptime ${uptime}s), force restarting..."
      handle_restart
    elif [[ "$uptime" -ge "$STARTUP_TIMEOUT" ]]; then
      log "Gateway stuck — alive for ${uptime}s but port $PORT not listening. Force restarting..."
      handle_restart
    else
      log "Gateway starting up (${uptime}s/${STARTUP_TIMEOUT}s)..."
    fi
  fi

  trim_log
  sleep "$CHECK_INTERVAL"
done
