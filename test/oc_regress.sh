#!/usr/bin/env bash
set -euo pipefail
BASE='http://127.0.0.1'
json(){ curl -fsS "$1"; }
field(){ jq -r "$1"; }

echo '== baseline =='
B=$(json "$BASE/api/openclaw?force=1")
echo "$B" | jq '{installed,version,latestVersion,hasUpdate,gatewayRunning,installTaskRunning,gatewayRestartRunning}'

echo '== start trigger =='
S=$(curl -fsS -X POST "$BASE/api/openclaw/start")
echo "$S" | jq .
for i in $(seq 1 15); do
  O=$(json "$BASE/api/openclaw?force=1")
  printf 'start_poll_%02d restart=%s running=%s\n' "$i" "$(echo "$O"|field '.gatewayRestartRunning')" "$(echo "$O"|field '.gatewayRunning')"
  sleep 1
done

echo '== install trigger =='
T=$(curl -fsS -X POST "$BASE/api/openclaw/install" | jq -r '.taskId')
echo "task=$T"
for i in $(seq 1 50); do
  O=$(json "$BASE/api/openclaw?force=1")
  st=$(curl -fsS "$BASE/api/openclaw/install/$T" | jq -r '.status')
  printf 'install_poll_%02d status=%s installRun=%s restartRun=%s running=%s\n' "$i" "$st" "$(echo "$O"|field '.installTaskRunning')" "$(echo "$O"|field '.gatewayRestartRunning')" "$(echo "$O"|field '.gatewayRunning')"
  [[ "$st" == "completed" || "$st" == "failed" ]] && break
  sleep 2
done

echo '== final =='
F=$(json "$BASE/api/openclaw?force=1")
echo "$F" | jq '{installed,version,latestVersion,hasUpdate,gatewayRunning,installTaskRunning,gatewayRestartRunning}'
