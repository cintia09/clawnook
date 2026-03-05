#!/usr/bin/env bash
set -euo pipefail

echo '== phase1: build control-ui in container source =='
SRC='/root/.openclaw/openclaw-source'
if [ ! -d "$SRC" ]; then
  echo "source_missing:$SRC"
else
  cd "$SRC"
  if [ -f dist/control-ui/index.html ]; then
    echo 'control_ui_exists=1'
  else
    echo 'control_ui_exists=0 -> building...'
    if command -v pnpm >/dev/null 2>&1; then
      pnpm ui:build >/tmp/oc_ui_build.log 2>&1 || npm run ui:build >>/tmp/oc_ui_build.log 2>&1 || true
    else
      npm run ui:build >/tmp/oc_ui_build.log 2>&1 || true
    fi
    if [ ! -f dist/control-ui/index.html ] && [ -d control-ui ] && [ -f control-ui/package.json ]; then
      cd control-ui
      (pnpm install --prefer-offline --no-frozen-lockfile || npm install --no-audit --no-fund) >/tmp/oc_ui_sub_install.log 2>&1 || true
      (pnpm build || npm run build) >/tmp/oc_ui_sub_build.log 2>&1 || true
      cd "$SRC"
      if [ -f control-ui/dist/index.html ]; then
        mkdir -p dist/control-ui
        cp -a control-ui/dist/. dist/control-ui/
      fi
    fi
    if [ -f dist/control-ui/index.html ]; then
      echo 'control_ui_build_ok=1'
    else
      echo 'control_ui_build_ok=0'
      tail -n 80 /tmp/oc_ui_build.log 2>/dev/null || true
      tail -n 80 /tmp/oc_ui_sub_build.log 2>/dev/null || true
    fi
  fi
fi

echo '== phase2: restart watchdog and wait health =='
pkill -f '[o]penclaw-gateway-watchdog.sh' >/dev/null 2>&1 || true
nohup bash /usr/local/bin/openclaw-gateway-watchdog.sh >> /root/.openclaw/logs/gateway-watchdog.log 2>&1 &
sleep 2
health_code='000'
for i in $(seq 1 20); do
  health_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:18789/health || true)
  echo "health_try_${i}=${health_code}"
  [ "$health_code" = '200' ] && break
  sleep 2
done

echo '== phase3: verify /api/openclaw and consistency =='
SECRET=$(jq -r '.webAuth.secret // empty' /root/.openclaw/docker-config.json 2>/dev/null || true)
COOKIE=$(node -e "const crypto=require('crypto');const s=process.argv[1]||'';const b=x=>Buffer.from(x).toString('base64').replace(/=/g,'').replace(/\\+/g,'-').replace(/\\//g,'_');const p=b(JSON.stringify({u:'admin',exp:Date.now()+3600*1000}));const g=b(crypto.createHmac('sha256',s).update(p).digest());process.stdout.write(p+'.'+g);" "$SECRET")
API_JSON=$(curl -sS -H "Cookie: oc_session=$COOKIE" 'http://127.0.0.1:3000/api/openclaw?force=1')
echo "$API_JSON" | jq -c '{installed,version,latestVersion,hasUpdate,gatewayRunning,gatewayProcessRunning,gatewayHealthCode,gatewayWatchdogRunning,operationState,operationProgress}'
API_GATEWAY_RUNNING=$(echo "$API_JSON" | jq -r '.gatewayRunning // false')
API_HEALTH_CODE=$(echo "$API_JSON" | jq -r '.gatewayHealthCode // 0')

if [ "$health_code" = '200' ] && [ "$API_GATEWAY_RUNNING" = 'true' ] && [ "$API_HEALTH_CODE" = '200' ]; then
  echo 'consistency_ok=1 (health=200 and api gatewayRunning=true)'
elif [ "$health_code" != '200' ] && [ "$API_GATEWAY_RUNNING" = 'false' ]; then
  echo 'consistency_ok=1 (health!=200 and api gatewayRunning=false)'
else
  echo "consistency_ok=0 health=${health_code} apiRunning=${API_GATEWAY_RUNNING} apiHealth=${API_HEALTH_CODE}"
fi

echo '== phase4: gateway-link endpoint =='
LINK_JSON=$(curl -sS -H "Cookie: oc_session=$COOKIE" 'http://127.0.0.1:3000/api/openclaw/gateway-link')
echo "$LINK_JSON" | jq -c .

echo '== phase5: watchdog tail =='
tail -n 60 /root/.openclaw/logs/gateway-watchdog.log || true
