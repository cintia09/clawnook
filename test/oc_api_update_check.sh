#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE_HOST="${REMOTE_HOST:-wm_20@192.168.31.107}"
REMOTE_PORT="${REMOTE_PORT:-2223}"
REMOTE_HELPER="${REMOTE_HELPER:-/tmp/oc_api_update_check.remote.sh}"

scp -P "$REMOTE_PORT" "$SCRIPT_DIR/oc_api_update_check.remote.sh" "$REMOTE_HOST:$REMOTE_HELPER" >/dev/null
ssh -T -p "$REMOTE_PORT" "$REMOTE_HOST" "chmod +x '$REMOTE_HELPER' && sudo -n bash '$REMOTE_HELPER'"
