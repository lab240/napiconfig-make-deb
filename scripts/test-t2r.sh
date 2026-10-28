#!/usr/bin/env bash
# Modbus Gate (dev): napi-api -> mbus-gw-t2r settings -> service -> a Modbus
# TCP request through the gateway to an RTU slave on a virtual serial line.
#   ./scripts/test-t2r.sh noble
# Needs out/mbus-gw-t2r_*_arm64.deb (with mbus-gw-t2r.service) next to napiconfig.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
RELEASE=${1:-noble}
NAME=napi-t2r-$RELEASE

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
    -v "$HERE/out:/pkgs:ro" -v "$HERE/scripts:/scripts:ro" "napi-sysd:$RELEASE" >/dev/null
trap 'docker rm -f "$NAME" >/dev/null' EXIT

dx() { docker exec "$NAME" bash -c "$*"; }

until dx 'systemctl is-system-running 2>/dev/null | grep -qE "running|degraded"'; do sleep 1; done
. "$HERE/scripts/test-common.sh"
T2R_DEB=/pkgs/$(basename "$(ls -t "$HERE"/out/mbus-gw-t2r_*_arm64.deb | head -1)")
PY=/opt/napiconfig/python/bin/python3

echo "== install $DEB $T2R_DEB"
add_repos
dx "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $DEB $T2R_DEB socat >/dev/null 2>&1"
dx 'systemctl is-enabled mbus-gw-t2r; systemctl is-active mbus-gw-t2r || true'

# Virtual RS-485 line: the gateway opens /dev/ttyUSB7, the RTU slave /dev/ttyRTU1.
dx 'systemd-run -q --unit=vline socat pty,raw,echo=0,link=/dev/ttyUSB7 pty,raw,echo=0,link=/dev/ttyRTU1; sleep 1'
dx "systemd-run -q --unit=rtu-slave $PY /scripts/rtu-slave.py /dev/ttyRTU1"

# A running mbusd that owns /dev/ttyS1 and TCP 502 (conflict check).
dx 'mkdir -p /etc/mbusd && printf "device = /dev/ttyS1\naddress = 0.0.0.0\nport = 502\n" > /etc/mbusd/mbusd.conf
    printf "[Service]\nExecStart=/bin/sleep infinity\n[Install]\nWantedBy=multi-user.target\n" > /etc/systemd/system/mbusd.service
    systemctl daemon-reload && systemctl enable -q --now mbusd'

sleep 5
TOKEN=$(dx "curl -sk -X POST https://127.0.0.1/api/v1/login -d 'username=admin&password=admin'" |
    python3 -I -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
api() { # method path [json]
    dx "curl -sk -X $1 -o /tmp/r -w '%{http_code}' -H 'Authorization: Bearer $TOKEN' \
        -H 'Content-Type: application/json' ${3:+-d '$3'} https://127.0.0.1/api/v1/$2; echo; cat /tmp/r; echo"
}

echo "== read packaged sample settings"
api GET modbus-gw-t2r/config
echo "== serial ports"
api GET modbus-gw-t2r/serial-ports

LINE='{"device":"/dev/ttyUSB7","desc":"virtual line","speed":19200,"parity":"E"}'
echo "== conflict: TCP 502 of mbusd -> 409"
api PUT modbus-gw-t2r/config "{\"serials\":[$LINE],\"listeners\":[{\"port\":502,\"target\":\"/dev/ttyUSB7\"}]}" | head -2
echo "== conflict: /dev/ttyS1 of mbusd -> 409"
api PUT modbus-gw-t2r/config '{"serials":[{"device":"/dev/ttyS1"}],"listeners":[]}' | head -2
echo "== listener to an undefined line -> 422"
api PUT modbus-gw-t2r/config "{\"serials\":[$LINE],\"listeners\":[{\"port\":5502,\"target\":\"/dev/ttyUSB9\"}]}" | head -1

echo "== save: one line, two TCP ports, trace"
api PUT modbus-gw-t2r/config "{\"serials\":[$LINE],\"listeners\":[{\"port\":5502,\"target\":\"/dev/ttyUSB7\"},{\"port\":5503,\"target\":\"/dev/ttyUSB7\"}],\"trace\":true}" | head -1
dx 'cat /etc/mbus-gw-t2r/modbus-t2r_settings.conf /etc/default/mbus-gw-t2r'

echo "== start (as the UI does: start + enable)"
api POST 'system/services/mbus-gw-t2r.service/start?use_system_bus=true' | head -1
api POST 'system/services/mbus-gw-t2r.service/enable?use_system_bus=true' | head -1
sleep 2
dx 'systemctl is-active mbus-gw-t2r; systemctl is-enabled mbus-gw-t2r'
dx 'journalctl -u mbus-gw-t2r -b --no-pager -o cat | grep -E "DEVREADY|LSNRRDY|-E-|-F-" || journalctl -u mbus-gw-t2r -b --no-pager -o cat | tail -20'

echo "== Modbus TCP read through the gateway (both ports)"
dx "$PY /scripts/rtu-slave.py --client 5502; $PY /scripts/rtu-slave.py --client 5503" || true

echo "== Modbus Tests: through the gateway, and the line it holds"
api POST modbus-test/read '{"mode":"tcp","host":"127.0.0.1","port":5502,"function":3,"address":10,"count":4}'
api POST modbus-test/read '{"mode":"rtu","device":"/dev/ttyUSB7","speed":19200,"parity":"E"}' | grep -o '"error_kind":"[a-z]*"'
api POST modbus-test/read '{"mode":"tcp","host":"127.0.0.1","port":5509}' | grep -o '"error_kind":"[a-z]*"'
api POST modbus-test/read '{"mode":"tcp","port":5502,"address":150,"count":2}' | grep -oE '"error_kind":"[a-z]*"|"error":"[^"]*"'
api POST modbus-test/read '{"mode":"tcp","port":5502,"function":6}' | head -1

echo "== change speed while running -> restart"
PID1=$(dx 'systemctl show -p MainPID --value mbus-gw-t2r')
api PUT modbus-gw-t2r/config "{\"serials\":[{\"device\":\"/dev/ttyUSB7\",\"speed\":9600}],\"listeners\":[{\"port\":5502,\"target\":\"/dev/ttyUSB7\"}]}" | head -1
sleep 2
PID2=$(dx 'systemctl show -p MainPID --value mbus-gw-t2r')
[ "$PID1" != "$PID2" ] && echo "restarted ($PID1 -> $PID2)" || echo "NOT restarted"
dx "systemctl is-active mbus-gw-t2r; grep -c trace /etc/default/mbus-gw-t2r || true; $PY /scripts/rtu-slave.py --client 5502"

echo "== stop (as the UI does: stop + disable)"
api POST 'system/services/mbus-gw-t2r.service/stop?use_system_bus=true' | head -1
api POST 'system/services/mbus-gw-t2r.service/disable?use_system_bus=true' | head -1
dx 'for i in $(seq 1 120); do case $(systemctl is-active mbus-gw-t2r) in active|deactivating) ;; *) break ;; esac; sleep 1; done; echo "stopped after ~${i}s: $(systemctl is-active mbus-gw-t2r)"; systemctl show -p Result -p ExecMainStatus mbus-gw-t2r; journalctl -u mbus-gw-t2r -b --no-pager -o cat | tail -5'

echo "== Modbus Tests: RTU directly on a line (a pty nobody holds)"
dx "systemd-run -q --unit=rtu-slave2 $PY /scripts/rtu-slave.py --pty /dev/ttyUSB8; sleep 1"
api POST modbus-test/read '{"mode":"rtu","device":"/dev/ttyUSB8","speed":9600,"function":4,"address":0,"count":3}'
api POST modbus-test/read '{"mode":"rtu","device":"/dev/ttyUSB8","address":120,"count":1}' | grep -o '"error_kind":"[a-z]*"'
api POST modbus-test/read '{"mode":"rtu","device":"/dev/ttyUSB8","unit_id":7,"timeout_ms":300}' | grep -oE '"error_kind":"[a-z]*"|"elapsed_ms":[0-9.]*'

echo "== purge mbus-gw-t2r"
dx 'DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq mbus-gw-t2r >/dev/null 2>&1; systemctl is-active mbus-gw-t2r || true; ls /etc/default/mbus-gw-t2r 2>&1 | tail -1'
api GET modbus-gw-t2r/config | head -1
dx "curl -sk -H 'Authorization: Bearer $TOKEN' https://127.0.0.1/api/v1/modbus-gw-t2r/config | grep -o '\"installed\":[a-z]*'"
echo OK
