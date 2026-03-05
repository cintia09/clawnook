#!/usr/bin/env bash
set -euo pipefail

echo '== process =='
ps -eo pid,cmd | grep -E '[n]ode server.js|[n]ode /opt/openclaw-web/server.js' || true

echo '== verify index: oc-log removed =='
if grep -q 'id="oc-log"' /opt/openclaw-web/public/index.html; then
  echo 'oc_log_present=yes'
else
  echo 'oc_log_present=no'
fi

echo '== verify app button rule =='
grep -n 'repairBtn\.disabled = installBusy \|\| repairBusy;' /opt/openclaw-web/public/app.js || true

echo '== verify server gateway status check =='
grep -n 'ss -ltn 2>/dev/null | grep -q "[:.]18789' /opt/openclaw-web/server.js || true

echo '== api checks (auth) =='
SECRET=$(jq -r '.webAuth.secret // empty' /root/.openclaw/docker-config.json)
COOKIE=$(node -e 'const crypto=require("crypto");const s=process.argv[1]||"";const b=x=>Buffer.from(x).toString("base64").replace(/=/g,"").replace(/\+/g,"-").replace(/\//g,"_");const p=b(JSON.stringify({u:"admin",exp:Date.now()+3600*1000}));const g=b(crypto.createHmac("sha256",s).update(p).digest());process.stdout.write(p+"."+g);' "$SECRET")
curl -sS -H "Cookie: oc_session=$COOKIE" http://127.0.0.1:3000/api/openclaw?force=1 | jq '{installed,gatewayRunning,installTaskRunning,repairTaskRunning,gatewayRestartRunning,operationState}'
curl -sS -H "Cookie: oc_session=$COOKIE" http://127.0.0.1:3000/api/status | jq '{gateway,gatewayWatchdog,caddy,terminal}'
