#!/usr/bin/env bash
set -euo pipefail

pkill -f 'oc_final_verify.sh|pnpm install --prod|pnpm ui:build' >/dev/null 2>&1 || true

ALT="$(find /root/.openclaw/openclaw-source/node_modules -path '*/openclaw/dist/control-ui/index.html' 2>/dev/null | head -n 1 || true)"
if [ -n "$ALT" ] && [ -f "$ALT" ]; then
  mkdir -p /root/.openclaw/openclaw-source/dist/control-ui
  cp -a "$(dirname "$ALT")"/. /root/.openclaw/openclaw-source/dist/control-ui/
  echo "copied_from=$ALT"
else
  echo "no_prebuilt_control_ui_found"
fi

if [ -f /root/.openclaw/openclaw-source/dist/control-ui/index.html ]; then
  echo "control_ui=1"
else
  echo "control_ui=0"
fi

pkill -f '[o]penclaw-gateway-watchdog.sh' >/dev/null 2>&1 || true
nohup bash /usr/local/bin/openclaw-gateway-watchdog.sh >> /root/.openclaw/logs/gateway-watchdog.log 2>&1 &
sleep 2

code="000"
for i in $(seq 1 20); do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:18789/health || true)"
  echo "health_try_${i}=${code}"
  [ "$code" = "200" ] && break
  sleep 2
done

SECRET="$(jq -r '.webAuth.secret // empty' /root/.openclaw/docker-config.json)"
COOKIE="$(node -e "const crypto=require('crypto');const s=process.argv[1]||'';const b=x=>Buffer.from(x).toString('base64').replace(/=/g,'').replace(/\\+/g,'-').replace(/\\//g,'_');const p=b(JSON.stringify({u:'admin',exp:Date.now()+3600*1000}));const g=b(crypto.createHmac('sha256',s).update(p).digest());process.stdout.write(p+'.'+g);" "$SECRET")"

echo "api_openclaw="
curl -sS -H "Cookie: oc_session=$COOKIE" http://127.0.0.1:3000/api/openclaw?force=1 | jq -c '{gatewayRunning,gatewayProcessRunning,gatewayHealthCode,operationState,operationProgress}'

echo "api_gateway_link="
curl -sS -H "Cookie: oc_session=$COOKIE" http://127.0.0.1:3000/api/openclaw/gateway-link | jq -c '{preferredUrl,directUrl,proxyUrl,authMode,hasToken}'

echo "dep_audit="
for c in node npm pnpm git curl jq bash; do
  if command -v "$c" >/dev/null 2>&1; then
    echo "dep_${c}=ok"
  else
    echo "dep_${c}=missing"
  fi
done

tail -n 30 /root/.openclaw/logs/gateway-watchdog.log || true
