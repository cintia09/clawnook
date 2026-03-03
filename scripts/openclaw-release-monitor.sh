#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_REPO="${OPENCLAW_REPO:-openclaw/openclaw}"
SSH_HOST="${SSH_HOST:-wm_20@192.168.31.107}"
SSH_PORT="${SSH_PORT:-2223}"
STATE_FILE="${STATE_FILE:-./.release-monitor-state.json}"
INTERVAL_SEC="${INTERVAL_SEC:-300}"
MODE="once"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Usage:
  bash scripts/openclaw-release-monitor.sh --once
  bash scripts/openclaw-release-monitor.sh --watch --interval 300

Env:
  OPENCLAW_REPO   default: openclaw/openclaw
  SSH_HOST        default: wm_20@192.168.31.107
  SSH_PORT        default: 2223
  STATE_FILE      default: ./.release-monitor-state.json
  INTERVAL_SEC    default: 300
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --once) MODE="once" ;;
    --watch) MODE="watch" ;;
    --interval)
      shift
      INTERVAL_SEC="${1:-300}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

log() { echo "[$(date '+%F %T')] $*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }
}

need_cmd curl
need_cmd jq
need_cmd ssh
need_cmd scp

read_state_tag() {
  if [ -f "$STATE_FILE" ]; then
    jq -r '.lastTag // ""' "$STATE_FILE" 2>/dev/null || true
  fi
}

write_state_tag() {
  local tag="$1"
  mkdir -p "$(dirname "$STATE_FILE")"
  jq -n --arg t "$tag" --arg at "$(date -Iseconds)" '{lastTag:$t,updatedAt:$at}' > "$STATE_FILE"
}

latest_release_tag() {
  local api="https://api.github.com/repos/$OPENCLAW_REPO/releases/latest"
  curl -fsSL "$api" | jq -r '.tag_name // ""'
}

run_remote_update_test() {
  local tag="$1"
  local remote_script="/tmp/openclaw-remote-update-and-test.sh"
  local local_script="$SCRIPT_DIR/openclaw-remote-update-and-test.sh"
  local remote_run_cmd

  if [[ "$SSH_HOST" == root@* ]] || [[ "$SSH_HOST" == "root" ]]; then
    remote_run_cmd="chmod +x $remote_script && OPENCLAW_REPO='$OPENCLAW_REPO' TARGET_TAG='$tag' bash $remote_script"
  else
    remote_run_cmd="chmod +x $remote_script && sudo -n OPENCLAW_REPO='$OPENCLAW_REPO' TARGET_TAG='$tag' bash $remote_script"
  fi

  log "upload remote script to $SSH_HOST:$remote_script"
  scp -P "$SSH_PORT" "$local_script" "$SSH_HOST:$remote_script" >/dev/null

  log "execute remote update+test for tag=$tag"
  ssh -p "$SSH_PORT" "$SSH_HOST" "$remote_run_cmd"
}

check_once() {
  local latest processed
  latest="$(latest_release_tag)"
  if [ -z "$latest" ]; then
    log "cannot fetch latest release tag"
    return 1
  fi

  processed="$(read_state_tag || true)"
  log "latest=$latest processed=${processed:-none}"

  if [ "$latest" = "$processed" ]; then
    log "no new release, skip"
    return 0
  fi

  if run_remote_update_test "$latest"; then
    write_state_tag "$latest"
    log "release $latest processed successfully"
    return 0
  fi

  log "release $latest processing failed"
  return 1
}

if [ "$MODE" = "once" ]; then
  check_once
  exit $?
fi

log "watch mode started: repo=$OPENCLAW_REPO host=$SSH_HOST interval=${INTERVAL_SEC}s"
while true; do
  if ! check_once; then
    log "check failed, keep watching"
  fi
  sleep "$INTERVAL_SEC"
done
