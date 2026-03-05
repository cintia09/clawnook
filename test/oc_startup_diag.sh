#!/usr/bin/env bash
set -euo pipefail
printf "=== host ===\n"
whoami
hostname
date "+%F %T %Z"

printf "\n=== openclaw process ===\n"
ps -eo pid,lstart,cmd | grep -E "[o]penclaw\.mjs|[o]penclaw.*gateway|[o]penclaw-gateway-watchdog|[n]ode /opt/openclaw-web/server\.js|[c]addy run" || true

printf "\n=== health ===\n"
code1=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 4 http://127.0.0.1:18789/health || true)
code2=$(curl -k -sS -o /dev/null -w "%{http_code}" --max-time 4 https://127.0.0.1/gateway/health || true)
printf "direct_gateway_health=%s\n" "$code1"
printf "caddy_gateway_health=%s\n" "$code2"

printf "\n=== latest gateway logs (tail 120) ===\n"
tail -n 120 /workspace/tmp/openclaw-gateway.log 2>/dev/null || true

printf "\n=== latest watchdog logs (tail 180) ===\n"
tail -n 180 /root/.openclaw/logs/gateway-watchdog.log 2>/dev/null || true

printf "\n=== startup duration estimate (watchdog) ===\n"
python3 - <<'PY'
import re,datetime,sys
p='/root/.openclaw/logs/gateway-watchdog.log'
try:
    lines=open(p,'r',encoding='utf-8',errors='ignore').read().splitlines()
except Exception as e:
    print('watchdog_log_unreadable',e)
    sys.exit(0)
pat_ts=re.compile(r'^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]')
start_idx=[]
ready_idx=[]
for i,l in enumerate(lines):
    s=l.lower()
    if ('starting gateway' in s) or ('gateway is down — restarting' in s) or ('gateway is down - restarting' in s) or ('restarting' in s and 'gateway' in s):
        start_idx.append(i)
    if ('gateway is healthy' in s) or ('health ok' in s) or ('gateway recovered' in s) or ('gateway is up' in s):
        ready_idx.append(i)
if not start_idx:
    print('no_start_event_found')
    sys.exit(0)
si=start_idx[-1]
ri=next((x for x in ready_idx if x>=si),None)
print('latest_start_line=',lines[si][:220])
if ri is None:
    print('latest_start_has_no_ready_event_yet')
    sys.exit(0)
print('matched_ready_line=',lines[ri][:220])
def ts(i):
    m=pat_ts.search(lines[i])
    return datetime.datetime.strptime(m.group(1),'%Y-%m-%d %H:%M:%S') if m else None
st,rt=ts(si),ts(ri)
if st and rt:
    print('startup_seconds=',int((rt-st).total_seconds()))
else:
    print('startup_seconds=unknown_no_timestamp')
PY
