#!/usr/bin/env bash
set -euo pipefail
COOKIE=$(node - <<'NODE'
const fs=require('fs'); const crypto=require('crypto');
const cfg=JSON.parse(fs.readFileSync('/root/.openclaw/docker-config.json','utf8'));
const secret=cfg?.webAuth?.secret||'';
const b64u=(s)=>Buffer.from(s).toString('base64').replace(/=/g,'').replace(/\+/g,'-').replace(/\//g,'_');
const payload=b64u(JSON.stringify({u:'admin',exp:Date.now()+2*60*60*1000}));
const sig=b64u(crypto.createHmac('sha256', secret).update(payload).digest());
process.stdout.write(`${payload}.${sig}`);
NODE
)
api(){ curl -sS -H "Cookie: oc_session=$COOKIE" "$@"; }

echo '--- trigger update ---'
resp=$(api -X POST http://127.0.0.1:3000/api/openclaw/update)
echo "$resp" | jq '{success,taskId,error,reused}'
task_id=$(echo "$resp" | jq -r '.taskId // empty')
if [ -z "$task_id" ]; then
  exit 0
fi

echo '--- update task log snapshot ---'
for i in 1 2 3 4 5; do
  t=$(api "http://127.0.0.1:3000/api/openclaw/install/${task_id}")
  st=$(echo "$t" | jq -r '.status // ""')
  seq=$(echo "$t" | jq -r '.seq // 0')
  echo "poll=$i status=$st seq=$seq"
  echo "$t" | jq -r '.delta // .log // ""' | tail -n 25
  if [ "$st" = "success" ] || [ "$st" = "failed" ]; then
    break
  fi
  sleep 3
done

echo '--- status after update trigger ---'
api http://127.0.0.1:3000/api/openclaw | jq '{installed,version,operationState,operationProgress}'
