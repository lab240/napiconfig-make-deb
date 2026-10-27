#!/usr/bin/env bash
# Check that napiconfig (napi-api) network settings win over the Armbian netplan defaults.
#   ./scripts/test-netplan.sh trixie networkd|nm
# Needs image napi-sysd:<release> and an Armbian build tree (ARMBIAN_DIR).
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
RELEASE=${1:-trixie}
STACK=${2:-networkd}
ARMBIAN_DIR=${ARMBIAN_DIR:-/home/dmn/qwa-armbian-build}
NAME=napi-netplan-$RELEASE-$STACK

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
    -v "$HERE/out:/pkgs:ro" -v "$ARMBIAN_DIR/extensions/network:/ext:ro" \
    "napi-sysd:$RELEASE" >/dev/null
trap 'docker rm -f "$NAME" >/dev/null' EXIT
dx() { docker exec "$NAME" bash -c "$*"; }
until dx 'systemctl is-system-running 2>/dev/null | grep -qE "running|degraded"'; do sleep 1; done
. "$HERE/scripts/test-common.sh"
add_repos

pkgs="netplan.io iproute2 udev"
[ "$STACK" = nm ] && pkgs="$pkgs network-manager"
dx "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $pkgs >/dev/null 2>&1"
# The image as Armbian builds it, plus a test NIC e* named like the board one.
dx "rm -f /etc/netplan/*; cp /ext/config-$STACK/netplan/* /etc/netplan/; chmod 600 /etc/netplan/*
    systemctl start systemd-udevd; udevadm control --reload && echo udev-ok
    ip link add eth9 type veth peer name veth9p && ip link set eth9 up && ip link set veth9p up"
if [ "$STACK" = nm ]; then
    dx 'systemctl enable --now NetworkManager >/dev/null 2>&1; systemctl is-active NetworkManager'
else
    dx 'systemctl enable --now systemd-networkd >/dev/null 2>&1; systemctl is-active systemd-networkd'
fi

echo "== install napiconfig ($RELEASE, stack $STACK)"
dx "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $DEB 2>&1 | grep netplan-takeover || true"
dx 'grep NETWORK_RENDERER /etc/napi-api/napi-api.env; ls /etc/netplan /var/lib/napi-api/netplan-backup'

echo "== static address for eth9 via API"
for _ in $(seq 30); do
    dx 'curl -s -o /dev/null http://127.0.0.1:8000/api/v1/login' && break
    sleep 1
done
TOKEN=$(dx "curl -s -X POST http://127.0.0.1:8000/api/v1/login -d 'username=admin&password=admin'" \
    | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
dx "curl -s -o /dev/null -w 'PATCH eth9 -> %{http_code}\n' -X PATCH -H 'Authorization: Bearer $TOKEN' \
    -H 'Content-Type: application/json' http://127.0.0.1:8000/api/v1/network/eth9 \
    -d '{\"dhcp4\": false, \"addresses\": [\"192.168.77.50/24\"]}'"
dx 'cat /etc/netplan/01-network.yaml'
dx 'journalctl -u napi-api --no-pager -p warning | grep -iE "netplan|error" | tail -5' || true

echo "== who owns eth9"
dx 'netplan generate 2>/dev/null; ls /run/systemd/network/ 2>/dev/null | grep -v "^$" || true'
if [ "$STACK" = networkd ]; then
    dx 'first=$(for f in $(ls /run/systemd/network/*.network | sort); do
            n=$(sed -n "s/^Name=//p" $f); case eth9 in $n) echo $f; break;; esac; done)
        echo "first matching .network: $first"; grep -E "Address|DHCP" $first || true'
    dx 'networkctl reload 2>/dev/null; sleep 2; ip -4 addr show eth9 | grep inet || echo "no IPv4 on eth9"'
else
    dx 'ls /run/NetworkManager/system-connections/; sleep 3; nmcli -t -f DEVICE,STATE,CONNECTION dev | grep eth9; ip -4 addr show eth9 | grep inet || echo "no IPv4 on eth9"'
fi

echo "== purge"
dx 'DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq napi-api >/dev/null; ls /etc/netplan'
