#!/usr/bin/env bash
set -euo pipefail
SECRET=$(jq -r '.webAuth.secret // empty' /root/.openclaw/docker-config.json)
COOKIE=$(node -e 'const crypto=require("crypto");const s=process.argv[1]||"";const b=x=>Buffer.from(x).toString("base64").replace(/=/g,"").replace(/\+/g,"-").replace(/\//g,"_");const p=b(JSON.stringify({u:"admin",exp:Date.now()+3600*1000}));const g=b(crypto.createHmac("sha256",s).update(p).digest());process.stdout.write(p+"."+g);' "$SECRET")
MARK="[t11-marker] $(date +%s)"
echo "$MARK" >> /root/.openclaw/logs/gateway-watchdog.log
rm -rf /workspace/tmp
curl -fsS -H "Cookie: oc_session=$COOKIE" -X POST http://127.0.0.1:3000/api/openclaw/start >/tmp/t11_start.json
for i in $(seq 1 40); do
  if [ -f /workspace/tmp/openclaw-gateway.log ] || [ -f /root/.openclaw/logs/gateway.log ]; then
    break
  fi
  sleep 2
done
echo "runtime_exists=$([ -f /workspace/tmp/openclaw-gateway.log ] && echo yes || echo no)"
echo "legacy_exists=$([ -f /root/.openclaw/logs/gateway.log ] && echo yes || echo no)"
awk -v m="$MARK" 'f{print} $0~m{f=1}' /root/.openclaw/logs/gateway-watchdog.log | tail -n 80 >/tmp/t11_watchdog_after.log || true
if grep -q 'No such file or directory' /tmp/t11_watchdog_after.log; then
  echo "missing_path_error=yes"
else
  echo "missing_path_error=no"
fi
