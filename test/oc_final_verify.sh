#!/usr/bin/env bash
set -euo pipefail

echo "STEP1 control-ui build"
cd /root/.openclaw/openclaw-source
if [ -f dist/control-ui/index.html ]; then
  echo "control_ui_before=1"
else
  echo "control_ui_before=0"
fi
pnpm ui:build >/tmp/oc_ui_build_final.log 2>&1 || npm run ui:build >/tmp/oc_ui_build_final.log 2>&1 || true
if [ ! -f dist/control-ui/index.html ] && [ -d control-ui ] && [ -f control-ui/package.json ]; then
  cd control-ui
  (pnpm install --prefer-offline --no-frozen-lockfile || npm install --no-audit --no-fund) >/tmp/oc_ui_sub_install_final.log 2>&1 || true
  (pnpm build || npm run build) >/tmp/oc_ui_sub_build_final.log 2>&1 || true
  cd /root/.openclaw/openclaw-source
  if [ -f control-ui/dist/index.html ]; then
    mkdir -p dist/control-ui
    cp -a control-ui/dist/. dist/control-ui/
  fi
fi
if [ -f dist/control-ui/index.html ]; then
  echo "control_ui_after=1"
else
  echo "control_ui_after=0"
fi

echo "STEP2 restart watchdog"
pkill -f '[o]penclaw-gateway-watchdog.sh' >/dev/null 2>&1 || true
nohup bash /usr/local/bin/openclaw-gateway-watchdog.sh >> /root/.openclaw/logs/gateway-watchdog.log 2>&1 &
sleep 2
health_code="000"
for i in $(seq 1 20); do
  health_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:18789/health || true)
  echo "health_try_${i}=${health_code}"
  [ "$health_code" = "200" ] && break
  sleep 2
done

echo "STEP3 /api/openclaw"
SECRET=$(jq -r '.webAuth.secret // empty' /root/.openclaw/docker-config.json 2>/dev/null || true)
COOKIE=$(node -e "const crypto=require('crypto');const s=process.argv[1]||'';const b=x=>Buffer.from(x).toString('base64').replace(/=/g,'').replace(/\\+/g,'-').replace(/\\//g,'_');const p=b(JSON.stringify({u:'admin',exp:Date.now()+3600*1000}));const g=b(crypto.createHmac('sha256',s).update(p).digest());process.stdout.write(p+'.'+g);" "$SECRET")
API_JSON=$(curl -sS -H "Cookie: oc_session=$COOKIE" 'http://127.0.0.1:3000/api/openclaw?force=1')
echo "$API_JSON" | jq -c '{installed,version,latestVersion,hasUpdate,gatewayRunning,gatewayProcessRunning,gatewayHealthCode,gatewayWatchdogRunning,operationState,operationProgress}'
api_running=$(echo "$API_JSON" | jq -r '.gatewayRunning // false')
api_health=$(echo "$API_JSON" | jq -r '.gatewayHealthCode // 0')
if [ "$health_code" = "200" ] && [ "$api_running" = "true" ] && [ "$api_health" = "200" ]; then
  echo "consistency_ok=1"
elif [ "$health_code" != "200" ] && [ "$api_running" = "false" ]; then
  echo "consistency_ok=1"
else
  echo "consistency_ok=0 health=${health_code} api_running=${api_running} api_health=${api_health}"
fi

echo "STEP4 gateway-link"
curl -sS -H "Cookie: oc_session=$COOKIE" 'http://127.0.0.1:3000/api/openclaw/gateway-link' | jq -c .

echo "STEP5 dependency audit quick"
for c in node npm pnpm git curl jq bash; do
  if command -v "$c" >/dev/null 2>&1; then
    echo "dep_${c}=ok"
  else
    echo "dep_${c}=missing"
  fi
done

echo "STEP6 watchdog tail"
tail -n 40 /root/.openclaw/logs/gateway-watchdog.log || true
