#!/usr/bin/env bash
# Install the built napiconfig package into a systemd container and check it.
#   ./scripts/test-install.sh trixie
# Needs image napi-sysd:<release>: the release base image with systemd, dbus and curl.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
RELEASE=${1:-trixie}
NAME=napi-test-$RELEASE

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
    -v "$HERE/out:/pkgs:ro" "napi-sysd:$RELEASE" >/dev/null
trap 'docker rm -f "$NAME" >/dev/null' EXIT

dx() { docker exec "$NAME" bash -c "$*"; }

until dx 'systemctl is-system-running 2>/dev/null | grep -qE "running|degraded"'; do sleep 1; done
. "$HERE/scripts/test-common.sh"

echo "== install $DEB"
add_repos
dx "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $DEB 2>&1 | grep -E 'napiconfig:|influx-link' || true"

echo "== services"
sleep 5
dx 'systemctl is-active napi-api napi-cert nginx influxdb telegraf; systemctl is-enabled napi-api napi-cert napi-ttyd napi-influx-link'
dx '/opt/napiconfig/python/bin/python3 --version; ls /etc/nginx/napi.d; dpkg -l | grep -E "^ii  (influxdb2|telegraf-light) " | cut -c1-60'
dx 'nginx -t 2>&1'
dx 'ls -l /etc/nginx/cert.pem /etc/nginx/key.pem /etc/nginx/ttyd_tokens.map /etc/napi-api/napi-api.env /var/lib/napi-api'
dx 'grep -c "^KEY_API_SECRET=.\+" /etc/napi-api/napi-api.env'

echo "== http"
dx 'curl -s -o /dev/null -w "http / -> %{http_code} %{redirect_url}\n" http://127.0.0.1/'
dx 'curl -sk -o /dev/null -w "https / -> %{http_code}\n" https://127.0.0.1/'
dx 'curl -sk -o /dev/null -w "https /assets/* -> %{http_code}\n" https://127.0.0.1$(curl -sk https://127.0.0.1/ | grep -o "/assets/[^\"]*\.js" | head -1)'
dx 'curl -sk -o /dev/null -w "https /tty/ no token -> %{http_code}\n" https://127.0.0.1/tty/'
dx 'curl -sk -o /dev/null -w "https /api/v1/system/modules no auth -> %{http_code}\n" https://127.0.0.1/api/v1/system/modules'

echo "== login admin/admin"
TOKEN=$(dx "curl -sk -X POST https://127.0.0.1/api/v1/login -d 'username=admin&password=admin' \
" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))' || true)
if [ -z "$TOKEN" ]; then
    dx "curl -sk -X POST https://127.0.0.1/api/v1/login -d 'username=admin&password=admin'"; echo
    echo "login FAILED"
else
    echo "login ok"
    for p in system/modules system/services/list system/time system_stats/all network/interfaces; do
        dx "curl -sk -o /dev/null -w '/api/v1/$p -> %{http_code}\n' -H 'Authorization: Bearer $TOKEN' https://127.0.0.1/api/v1/$p"
    done
fi

if dx 'apt-cache policy ttyd 2>/dev/null | grep -q "Candidate: [0-9]"'; then
    echo "== web terminal (ttyd)"
    dx 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ttyd >/dev/null && systemctl restart napi-ttyd && sleep 2 && systemctl is-active napi-ttyd'
    TT=$(dx "grep -Eom1 '^[0-9a-f]{32}' /etc/nginx/ttyd_tokens.map")
    dx "curl -sk -o /dev/null -w '/tty/?token=valid -> %{http_code}\n' 'https://127.0.0.1/tty/?token=$TT'"
    dx "curl -sk -o /dev/null -w '/tty/?token=bad -> %{http_code}\n' 'https://127.0.0.1/tty/?token=bad'"
    dx "curl -sk -o /dev/null -w '/tty/token with cookie -> %{http_code}\n' -b 'napi_tty=$TT' https://127.0.0.1/tty/token"
    dx "curl -sk -o /dev/null -w '/tty/ws upgrade with cookie -> %{http_code}\n' -b 'napi_tty=$TT' -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Sec-WebSocket-Protocol: tty' --max-time 3 --http1.1 https://127.0.0.1/tty/ws" || true
fi

echo "== napi-api journal (warnings and errors)"
dx 'journalctl -u napi-api --no-pager -p warning | tail -15'

echo "== reinstall, remove, purge"
dx "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --reinstall $DEB >/dev/null && systemctl is-active napi-api"
dx 'DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq napiconfig >/dev/null && ls /opt /etc/nginx/sites-enabled; ls /etc/napi-api /var/lib/napi-api 2>&1 | head -2; nginx -t 2>&1 | tail -1'
