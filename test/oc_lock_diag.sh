#!/usr/bin/env bash
set -euo pipefail
LOCK_DIR="/root/.openclaw/locks"
SECRET=$(jq -r '.webAuth.secret // empty' /root/.openclaw/docker-config.json)
COOKIE=$(node -e 'const crypto=require("crypto");const s=process.argv[1]||"";const b=x=>Buffer.from(x).toString("base64").replace(/=/g,"").replace(/\+/g,"-").replace(/\//g,"_");const p=b(JSON.stringify({u:"admin",exp:Date.now()+3600*1000}));const g=b(crypto.createHmac("sha256",s).update(p).digest());process.stdout.write(p+"."+g);' "$SECRET")
echo '== api/openclaw =='
curl -sS -H "Cookie: oc_session=$COOKIE" http://127.0.0.1:3000/api/openclaw?force=1 | jq '{installed,version,gatewayRunning,installTaskRunning,repairTaskRunning,gatewayRestartRunning,operationState}'
echo '== operation lock files =='
ls -l "$LOCK_DIR"/operation.lock "$LOCK_DIR"/install.lock "$LOCK_DIR"/config-repair.lock 2>/dev/null || true
echo '== install logs tail =='
for f in "$LOCK_DIR"/openclaw-install-*.json; do
  [ -f "$f" ] || continue
  echo "-- $f"
  tail -n 12 "$f" || true
done
