#!/usr/bin/env bash
set -euo pipefail
TMP_DIR="${TMP_DIR:-/root/.openclaw/test-tmp}"
mkdir -p "$TMP_DIR"
SRC=/root/.openclaw/openclaw-source
PKG_DIST=$(find /root/.openclaw/openclaw-source/node_modules -type d -path '*/node_modules/openclaw/dist' | head -n 1 || true)
if [[ -z "$PKG_DIST" ]]; then
  echo "pkg_dist_not_found"
  exit 2
fi
echo "pkg_dist=$PKG_DIST"
mkdir -p "$SRC/dist"
cp -a "$PKG_DIST"/. "$SRC/dist"/
if [[ ! -f "$SRC/dist/entry.js" && ! -f "$SRC/dist/entry.mjs" ]]; then
  echo "entry_missing_after_copy"
  exit 3
fi
if [[ ! -f "$SRC/dist/control-ui/index.html" ]]; then
  echo "control_ui_missing_after_copy"
  exit 4
fi
echo "dist_sync_ok"
pkill -f openclaw-gateway-watchdog.sh || true
sleep 1
nohup bash /usr/local/bin/openclaw-gateway-watchdog.sh >/dev/null 2>&1 &
for i in $(seq 1 40); do
  code=$(curl -s -o "$TMP_DIR/oc_health.out" -w '%{http_code}' http://127.0.0.1:18789/health || true)
  if [[ "$code" == "200" ]]; then
    echo "health_ok_try=$i"
    cat "$TMP_DIR/oc_health.out"
    exit 0
  fi
  sleep 3
done
echo "health_failed"
tail -n 120 /root/.openclaw/logs/gateway-watchdog.log || true
exit 5
