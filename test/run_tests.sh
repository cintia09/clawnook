#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

timestamp="$(date +%Y%m%d-%H%M%S)"

run_with_log() {
  local name="$1"
  local cmd="$2"
  local log_file="$LOG_DIR/${timestamp}-${name}.log"
  echo "[test] running: $name"
  set +e
  bash -lc "$cmd" >"$log_file" 2>&1
  local rc=$?
  set -e
  echo "[test] done: $name (rc=$rc) log=$log_file"
  return $rc
}

cd "$SCRIPT_DIR"

overall=0
run_with_log "full_verify" "chmod +x ./oc_full_verify_20260305.sh && ./oc_full_verify_20260305.sh" || overall=1
run_with_log "api_update_check" "chmod +x ./oc_api_update_check.sh ./oc_api_update_check.remote.sh && ./oc_api_update_check.sh" || overall=1

latest_summary="$LOG_DIR/${timestamp}-summary.txt"
{
  echo "timestamp=$timestamp"
  echo "overall_rc=$overall"
  echo "logs_dir=$LOG_DIR"
  ls -1 "$LOG_DIR" | sed -n "1,200p"
} > "$latest_summary"

echo "[test] summary: $latest_summary"
exit $overall
