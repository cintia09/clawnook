#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
TS="$(date +%Y%m%d-%H%M%S)"
LOCAL_LOG="$LOG_DIR/${TS}-api_update_check.log"
REMOTE_HOST="${REMOTE_HOST:-wm_20@192.168.31.107}"
REMOTE_PORT="${REMOTE_PORT:-2223}"
REMOTE_HELPER="${REMOTE_HELPER:-/root/.openclaw/test-tmp/oc_api_update_check.remote.sh}"

{
	echo "[test] remote_host=$REMOTE_HOST remote_port=$REMOTE_PORT"
	echo "[test] remote_helper=$REMOTE_HELPER"
	ssh -T -p "$REMOTE_PORT" "$REMOTE_HOST" "mkdir -p '$(dirname "$REMOTE_HELPER")'"
	scp -P "$REMOTE_PORT" "$SCRIPT_DIR/oc_api_update_check.remote.sh" "$REMOTE_HOST:$REMOTE_HELPER"
	ssh -T -p "$REMOTE_PORT" "$REMOTE_HOST" "chmod +x '$REMOTE_HELPER' && sudo -n bash '$REMOTE_HELPER'"
} >"$LOCAL_LOG" 2>&1

echo "[test] log=$LOCAL_LOG"
