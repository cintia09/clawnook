set -e
pkill -f '[o]penclaw-gateway-watchdog.sh' >/dev/null 2>&1 || true
nohup bash /usr/local/bin/openclaw-gateway-watchdog.sh >> /root/.openclaw/logs/gateway-watchdog.log 2>&1 &
sleep 2
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:18789/health || true)
  echo "health_try_$i=$code"
  if [ "$code" = "200" ]; then
    break
  fi
  sleep 2
done
echo '---watchdog---'
tail -n 45 /root/.openclaw/logs/gateway-watchdog.log || true
echo '---runtime---'
tail -n 35 /workspace/tmp/openclaw-gateway.log || true
