#!/bin/bash
#
# OpenClaw Gateway Watchdog v2 (source-build mode)
#

set -u

LOG_DIR="/root/.openclaw/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/gateway-watchdog.log"

CHECK_INTERVAL=30
POLL_INTERVAL=5
STARTUP_TIMEOUT=900
MAX_RETRIES=3
BACKOFF_WAIT=300
PORT=18789
MAX_LOG_LINES=5000

HOME="${HOME:-/root}"
export HOME
export DISPLAY=:99

SOURCE_ROOT="/workspace/project/openclaw"
GATEWAY_CMD="node --experimental-sqlite /workspace/project/openclaw/openclaw.mjs gateway run --force"
GATEWAY_LOG="/workspace/tmp/openclaw-gateway.log"

LOCK_DIR="/tmp/openclaw-gateway-watchdog.lock"
LOCK_PID_FILE="$LOCK_DIR/pid"

CONFIG_FILE="/root/.openclaw/openclaw.json"
BACKUP_DIR="/root/.openclaw/config-backups"
BACKUP_INDEX_FILE="/root/.openclaw/config-backups/.last_hash"
LAST_GOOD_BACKUP_FILE="/root/.openclaw/config-backups/.last_good"
MAX_BACKUPS=30

CONSECUTIVE_FAILURES=0
LAST_PID=""

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

config_hash() {
  local file="$1"
  [ -f "$file" ] || return 1
  sha256sum "$file" 2>/dev/null | awk '{print $1}'
}

trim_backups() {
  [ -d "$BACKUP_DIR" ] || return 0
  local files
  files=$(ls -1t "$BACKUP_DIR"/openclaw-*.json 2>/dev/null || true)
  local count=0
  local file
  for file in $files; do
    count=$((count + 1))
    if [ "$count" -gt "$MAX_BACKUPS" ]; then
      rm -f "$file" 2>/dev/null || true
    fi
  done
}

backup_config_if_changed() {
  mkdir -p "$BACKUP_DIR"
  [ -f "$CONFIG_FILE" ] || return 0

  local cur_hash prev_hash backup_file
  cur_hash=$(config_hash "$CONFIG_FILE")
  [ -n "$cur_hash" ] || return 0

  prev_hash=""
  if [ -f "$BACKUP_INDEX_FILE" ]; then
    prev_hash=$(cat "$BACKUP_INDEX_FILE" 2>/dev/null || true)
  fi

  if [ "$cur_hash" = "$prev_hash" ]; then
    return 0
  fi

  backup_file="$BACKUP_DIR/openclaw-$(date '+%Y%m%d-%H%M%S').json"
  if cp "$CONFIG_FILE" "$backup_file" 2>/dev/null; then
    echo "$cur_hash" > "$BACKUP_INDEX_FILE"
    echo "$backup_file" > "$LAST_GOOD_BACKUP_FILE"
    log "Config changed after successful start, backup created: $backup_file"
    trim_backups
  fi
}

is_invalid_config_failure() {
  [ -f "$GATEWAY_LOG" ] || return 1
  tail -n 120 "$GATEWAY_LOG" 2>/dev/null | grep -Eiq 'Unrecognized key|Invalid config|schema|validation|parse|配置无效|unexpected token|doctor --fix'
}

restore_previous_backup() {
  mkdir -p "$BACKUP_DIR"
  local backup_file=""

  if [ -f "$LAST_GOOD_BACKUP_FILE" ]; then
    backup_file=$(cat "$LAST_GOOD_BACKUP_FILE" 2>/dev/null || true)
  fi

  if [ -z "$backup_file" ] || [ ! -f "$backup_file" ]; then
    backup_file=$(ls -1t "$BACKUP_DIR"/openclaw-*.json 2>/dev/null | head -1 || true)
  fi

  if [ -z "$backup_file" ] || [ ! -f "$backup_file" ]; then
    log "No config backup found for rollback"
    return 1
  fi

  if [ -f "$CONFIG_FILE" ]; then
    cp "$CONFIG_FILE" "$CONFIG_FILE.before-auto-rollback.$(date '+%Y%m%d-%H%M%S').bak" 2>/dev/null || true
  fi

  if cp "$backup_file" "$CONFIG_FILE" 2>/dev/null; then
    local hash
    hash=$(config_hash "$CONFIG_FILE" || true)
    [ -n "$hash" ] && echo "$hash" > "$BACKUP_INDEX_FILE"
    log "Config rollback applied from backup: $backup_file"
    return 0
  fi

  log "Failed to restore config backup: $backup_file"
  return 1
}

get_gateway_pid() {
  pgrep -x "openclaw-gatewa" 2>/dev/null | head -1 && return
  pgrep -f "openclaw.mjs gateway" 2>/dev/null | head -1 && return
  local pid
  for pid in $(pgrep -x "openclaw" 2>/dev/null); do
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

is_port_listening() {
  ss -tlnp 2>/dev/null | grep -q ":${PORT} "
}

kill_gateway() {
  local pid
  pid=$(get_gateway_pid)
  [[ -z "$pid" && -n "$LAST_PID" ]] && kill -0 "$LAST_PID" 2>/dev/null && pid=$LAST_PID
  if [[ -n "$pid" ]]; then
    log "Killing gateway (PID $pid)"
    kill -TERM "$pid" 2>/dev/null || true
    pkill -TERM -P "$pid" 2>/dev/null || true
    local waited=0
    while [[ $waited -lt 5 ]] && kill -0 "$pid" 2>/dev/null; do
      sleep 1
      ((waited++))
    done
  fi
  pkill -9 -x "openclaw-gatewa" 2>/dev/null || true
  pkill -9 -x "openclaw" 2>/dev/null || true
  pkill -9 -f "openclaw.mjs gateway" 2>/dev/null || true
  [[ -n "$LAST_PID" ]] && kill -9 "$LAST_PID" 2>/dev/null || true
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

    sleep "$POLL_INTERVAL"
    ((elapsed += POLL_INTERVAL))

    if [[ $((elapsed - last_log)) -ge 60 ]]; then
      log "Startup in progress... ${elapsed}s/${timeout}s"
      last_log=$elapsed
    fi
  done

  return 1
}

start_once() {
  if [ ! -f "$SOURCE_ROOT/openclaw.mjs" ]; then
    log "Cannot start gateway: source entry not found at $SOURCE_ROOT/openclaw.mjs"
    return 2
  fi

  : > "$GATEWAY_LOG"
  nohup $GATEWAY_CMD > "$GATEWAY_LOG" 2>&1 &
  LAST_PID=$!
  log "Gateway process launched (PID $LAST_PID), polling every ${POLL_INTERVAL}s (timeout ${STARTUP_TIMEOUT}s)..."

  if wait_for_ready "$STARTUP_TIMEOUT"; then
    local actual_pid
    actual_pid=$(get_gateway_pid)
    log "Gateway started successfully (port $PORT listening, PID ${actual_pid:-$LAST_PID})"
    return 0
  fi

  log "ERROR: Gateway failed to start within ${STARTUP_TIMEOUT}s"
  if [[ -f "$GATEWAY_LOG" ]]; then
    local tail_log
    tail_log=$(tail -5 "$GATEWAY_LOG" 2>/dev/null | tr '\n' ' ')
    [[ -n "$tail_log" ]] && log "  Last output: $tail_log"
  fi
  return 1
}

start_gateway() {
  if is_gateway_process_alive; then
    kill_gateway
  fi

  log "Starting gateway..."
  if start_once; then
    CONSECUTIVE_FAILURES=0
    backup_config_if_changed
    return 0
  fi

  if is_invalid_config_failure; then
    log "Detected invalid config signature from startup failure, trying automatic rollback..."
    if restore_previous_backup; then
      kill_gateway
      if start_once; then
        log "Gateway recovered after automatic config rollback"
        CONSECUTIVE_FAILURES=0
        backup_config_if_changed
        return 0
      fi
      log "Gateway still failed after rollback attempt"
    fi
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
    lines=$(wc -l < "$LOG_FILE")
    if [[ $lines -gt $MAX_LOG_LINES ]]; then
      tail -n "$((MAX_LOG_LINES / 2))" "$LOG_FILE" > "${LOG_FILE}.tmp"
      mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
  fi
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_PID_FILE"
    return 0
  fi

  local old_pid=""
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

mkdir -p "$BACKUP_DIR"

log "Watchdog v2 started (poll=${POLL_INTERVAL}s, timeout=${STARTUP_TIMEOUT}s, port=$PORT)"

while true; do
  if [ ! -f "$SOURCE_ROOT/openclaw.mjs" ]; then
    log "OpenClaw source entry missing at $SOURCE_ROOT/openclaw.mjs, watchdog idle"
    sleep "$CHECK_INTERVAL"
    continue
  fi

  if ! is_gateway_process_alive; then
    log "Gateway is DOWN — restarting"
    handle_restart
  elif ! is_port_listening; then
    local uptime
    uptime=$(ps -o etimes= -p "$(get_gateway_pid)" 2>/dev/null | tr -d ' ')
    uptime=${uptime:-0}
    if [[ $uptime -ge $STARTUP_TIMEOUT ]]; then
      log "Gateway stuck — alive for ${uptime}s but port $PORT not listening. Force restarting..."
      handle_restart
    else
      log "Gateway starting up (${uptime}s/${STARTUP_TIMEOUT}s)..."
    fi
  fi

  trim_log
  sleep "$CHECK_INTERVAL"
done
