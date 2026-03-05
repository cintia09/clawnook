#!/usr/bin/env bash
set -euo pipefail
SECRET=$(jq -r '.webAuth.secret // empty' /root/.openclaw/docker-config.json)
COOKIE=$(node -e 'const crypto=require("crypto");const s=process.argv[1]||"";const b=x=>Buffer.from(x).toString("base64").replace(/=/g,"").replace(/\+/g,"-").replace(/\//g,"_");const p=b(JSON.stringify({u:"admin",exp:Date.now()+3600*1000}));const g=b(crypto.createHmac("sha256",s).update(p).digest());process.stdout.write(p+"."+g);' "$SECRET")
for i in $(seq 1 80); do
  st=$(curl -sS -H "Cookie: oc_session=$COOKIE" http://127.0.0.1:3000/api/openclaw?force=1 | jq -r '.operationState.type // "idle"')
  echo "op_state=$st"
  if [ "$st" = "idle" ]; then
    exit 0
  fi
  sleep 3
done
exit 1
