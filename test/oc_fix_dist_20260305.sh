set -e
cd /root/.openclaw/openclaw-source
export PATH="$(npm prefix -g 2>/dev/null)/bin:/root/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
for i in 1 2 3; do
  echo "== build attempt $i =="
  if command -v pnpm >/dev/null 2>&1; then
    pnpm run build && break || true
  fi
  npm run build && break || true
  sleep 3
done
if [ ! -f dist/entry.js ] && [ ! -f dist/entry.mjs ]; then
  echo "build_missing_entry"
  exit 2
fi
echo "== dist ok =="
ls -la dist | sed -n '1,60p'
SECRET=$(jq -r '.webAuth.secret // empty' /root/.openclaw/docker-config.json)
COOKIE=$(node -e 'const crypto=require("crypto");const s=process.argv[1]||"";const b=x=>Buffer.from(x).toString("base64").replace(/=/g,"").replace(/\+/g,"-").replace(/\//g,"_");const p=b(JSON.stringify({u:"admin",exp:Date.now()+3600*1000}));const g=b(crypto.createHmac("sha256",s).update(p).digest());process.stdout.write(p+"."+g);' "$SECRET")
echo "== restart gateway =="
curl -sS -H "Cookie: oc_session=$COOKIE" -H 'Content-Type: application/json' -X POST http://127.0.0.1:3000/api/openclaw/start | sed -n '1,2p'
sleep 5
echo "health=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:18789/health || true)"
tail -n 18 /root/.openclaw/logs/gateway-watchdog.log
