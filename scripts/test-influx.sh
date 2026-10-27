#!/usr/bin/env bash
# InfluxDB link test: napiconfig with influxdb2 (InfluxData repo) and
# telegraf-light (repo.napilab.ru) in a systemd container.
#   ./scripts/test-influx.sh noble
# Needs image napi-sysd:<release> (see test-install.sh).
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
RELEASE=${1:-noble}
NAME=napi-influx-$RELEASE

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
    -v "$HERE/out:/pkgs:ro" "napi-sysd:$RELEASE" >/dev/null
trap 'docker rm -f "$NAME" >/dev/null' EXIT

dx() { docker exec "$NAME" bash -c "$*"; }
fail() { echo "FAIL: $*"; exit 1; }
auth_count() { dx '. /root/influxdb-credentials; curl -s -H "Authorization: Token $INFLUXDB_TOKEN" http://127.0.0.1:8086/api/v2/authorizations | grep -o "\"description\"" | wc -l'; }
# HTTP status of an empty write / a query with a token
write_code() { dx "curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Authorization: Token $1' 'http://127.0.0.1:8086/api/v2/write?org=napi&bucket=sensors' --data-binary ''"; }
read_code() { dx "curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Authorization: Token $1' -H 'Content-Type: application/vnd.flux' 'http://127.0.0.1:8086/api/v2/query?org=napi' --data 'from(bucket: \"sensors\") |> range(start: -1m) |> limit(n: 1)'"; }
env_value() { dx "sed -n \"s/^$2=['\\\"]\\?\\([^'\\\"]*\\)['\\\"]\\?\$/\\1/p\" $1"; }

until dx 'systemctl is-system-running 2>/dev/null | grep -qE "running|degraded"'; do sleep 1; done

. "$HERE/scripts/test-common.sh"
echo "== repos"
add_repos

echo "== install $DEB (pulls influxdb2, telegraf-light)"
dx "mkdir -p /etc/telegraf/telegraf.d && printf '[[inputs.cpu]]\n' > /etc/telegraf/telegraf.d/cpu.conf"
dx "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $DEB 2>&1 | grep -E 'influx-link|napiconfig:' || true"
dx 'systemctl is-active influxdb; telegraf --version'
dx 'stat -c "%a %U:%G %n" /root/influxdb-credentials /etc/default/telegraf /root/.influxdbv2/configs'
dx 'systemctl is-enabled napi-influx-link'

T_TOKEN=$(env_value /etc/default/telegraf INFLUX_TOKEN)
A_TOKEN=$(env_value /etc/napi-api/napi-api.env INFLUXDB_TOKEN)
[ -n "$T_TOKEN" ] && [ -n "$A_TOKEN" ] || fail "tokens not written"
[ "$T_TOKEN" != "$A_TOKEN" ] || fail "same token for telegraf and napi-api"
echo "telegraf token: write $(write_code "$T_TOKEN") read $(read_code "$T_TOKEN")"
echo "napi-api token: write $(write_code "$A_TOKEN") read $(read_code "$A_TOKEN")"
[ "$(write_code "$T_TOKEN")" = 204 ] && [ "$(read_code "$T_TOKEN")" != 200 ] || fail "telegraf token scope"
[ "$(read_code "$A_TOKEN")" = 200 ] && [ "$(write_code "$A_TOKEN")" != 204 ] || fail "napi-api token scope"
dx 'grep -E "^INFLUXDB_(URL|ORG|BUCKET)=" /etc/napi-api/napi-api.env'

echo "== data flow"
sleep 25
dx 'systemctl is-active telegraf'
TOKEN=$(dx "curl -s -X POST http://127.0.0.1:8000/api/v1/login -d 'username=admin&password=admin'" |
    python3 -I -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
dx "curl -s -H 'Authorization: Bearer $TOKEN' http://127.0.0.1:8000/api/v1/influxdb/data/measurements"; echo
dx "curl -s -H 'Authorization: Bearer $TOKEN' http://127.0.0.1:8000/api/v1/influxdb/data/measurements" | grep -q cpu ||
    fail "napi-api does not see cpu"

echo "== idempotent"
N=$(auth_count)
dx /usr/lib/napiconfig/influx-link --no-api-restart
[ "$(auth_count)" = "$N" ] || fail "new tokens on rerun"
echo "authorizations: $N"

echo "== lost telegraf token (apt replaced telegraf), restart of the unit"
dx 'sed -i "/^INFLUX_TOKEN=/d" /etc/default/telegraf && systemctl restart telegraf || true'
dx 'systemctl restart napi-influx-link && journalctl -u napi-influx-link -n 3 --no-pager -o cat'
sleep 3
dx 'systemctl is-active telegraf'
[ "$(write_code "$(env_value /etc/default/telegraf INFLUX_TOKEN)")" = 204 ] || fail "telegraf token not restored"

echo "== boot without telegraf token"
dx 'sed -i "/^INFLUX_TOKEN=/d" /etc/default/telegraf'
T0=$(dx 'date "+%F %T"')
docker restart "$NAME" >/dev/null
until dx 'systemctl is-system-running 2>/dev/null | grep -qE "running|degraded"'; do sleep 1; done
dx 'systemctl is-active telegraf'
[ "$(write_code "$(env_value /etc/default/telegraf INFLUX_TOKEN)")" = 204 ] || fail "token not created at boot"
# Containers share the host boot id: filter by time.
dx "journalctl -u telegraf --since '$T0' -o cat --no-pager | grep 'E!'" && fail "telegraf errors after boot"

echo "OK"
