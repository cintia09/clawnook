set -e
ROOT="/Volumes/MacData/MyData/Documents/project/openclaw-pro"
scp -P 2223 "$ROOT/web/server.js" wm_20@192.168.31.107:/tmp/server.js.new
scp -P 2223 "$ROOT/web/public/app.js" wm_20@192.168.31.107:/tmp/app.js.new
scp -P 2223 "$ROOT/scripts/openclaw-gateway-watchdog.sh" wm_20@192.168.31.107:/tmp/openclaw-gateway-watchdog.sh.new
scp -P 2223 "$ROOT/start-services.sh" wm_20@192.168.31.107:/tmp/start-services.sh.new
ssh -p 2223 wm_20@192.168.31.107 'sudo bash -lc "install -m 644 /tmp/server.js.new /opt/openclaw-web/server.js && install -m 644 /tmp/app.js.new /opt/openclaw-web/public/app.js && install -m 755 /tmp/openclaw-gateway-watchdog.sh.new /usr/local/bin/openclaw-gateway-watchdog.sh && install -m 755 /tmp/start-services.sh.new /usr/local/bin/start-services.sh && node --check /opt/openclaw-web/server.js && bash -n /usr/local/bin/openclaw-gateway-watchdog.sh && bash -n /usr/local/bin/start-services.sh"'
