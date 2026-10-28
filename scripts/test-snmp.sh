#!/usr/bin/env bash
# SNMP Tests: napi-api -> a real snmpd (net-snmp) in the same container:
# Get / Walk by MIB names, v1 and v2c, errors, a MIB uploaded on the MIBs page.
#   ./scripts/test-snmp.sh noble
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
RELEASE=${1:-noble}
NAME=napi-snmp-$RELEASE

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
    -v "$HERE/out:/pkgs:ro" "napi-sysd:$RELEASE" >/dev/null
[ -n "${KEEP:-}" ] || trap 'docker rm -f "$NAME" >/dev/null' EXIT

dx() { docker exec "$NAME" bash -c "$*"; }

until dx 'systemctl is-system-running 2>/dev/null | grep -qE "running|degraded"'; do sleep 1; done
. "$HERE/scripts/test-common.sh"

echo "== install $DEB snmpd"
add_repos
dx "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $DEB snmpd >/dev/null 2>&1"
dx 'printf "agentAddress udp:161\nrocommunity public default\nsysLocation rack 3\n" > /etc/snmp/snmpd.conf
    systemctl restart snmpd'

login() { dx "curl -sk -X POST https://127.0.0.1/api/v1/login -d 'username=admin&password=admin'"; }
until login | grep -q access_token; do sleep 1; done
TOKEN=$(login | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
api() { # method path [json]
    dx "curl -sk -X $1 -o /tmp/r -w '%{http_code}' -H 'Authorization: Bearer $TOKEN' \
        -H 'Content-Type: application/json' ${3:+-d '$3'} https://127.0.0.1/api/v1/$2; echo; cat /tmp/r; echo"
}
show() { # summary of a query result
    python3 -I -c '
import json, sys
lines = sys.stdin.read().splitlines()
r = json.loads(lines[1])
print(lines[0], "ok" if r["ok"] else "FAIL", r.get("error_kind") or "", r.get("error") or "",
      "{}ms rows={} req={}".format(r["elapsed_ms"], len(r["rows"]), r["requests"]))
for row in r["rows"][:int(sys.argv[1])]:
    print("   ", row["name"] or row["oid"], row["type"], "=", row["value"])' "${1:-4}"
}

echo "== Get by names (v2c), a scalar gets .0"
api POST snmp-test/query '{"host":"127.0.0.1","oids":["sysDescr","sysUpTime","sysLocation","sysObjectID"]}' | show
echo "== Walk ifTable (GetBulk)"
api POST snmp-test/query '{"host":"127.0.0.1","operation":"walk","oids":["IF-MIB::ifTable"]}' | show 6
echo "== Walk system, v1 (GetNext)"
api POST snmp-test/query '{"host":"127.0.0.1","version":"1","operation":"walk","oids":["system"]}' | show 2
echo "== Walk hrStorageDescr, max 3 rows"
api POST snmp-test/query '{"host":"127.0.0.1","operation":"walk","oids":["hrStorageDescr"],"max_rows":3}' | show 3
echo "== wrong community -> timeout"
api POST snmp-test/query '{"host":"127.0.0.1","community":"nope","oids":["sysDescr"],"timeout_ms":500,"retries":0}' | show
echo "== closed port -> connection"
api POST snmp-test/query '{"host":"127.0.0.1","port":1161,"oids":["sysDescr"],"timeout_ms":500}' | show
echo "== v1 noSuchName"
api POST snmp-test/query '{"host":"127.0.0.1","version":"1","oids":[".1.3.6.1.2.1.1.99.0"]}' | show
echo "== unknown name -> resolve"
api POST snmp-test/query '{"host":"127.0.0.1","oids":["napiTestCounter"]}' | show
echo "== Set is not there, v3 is not there -> 422"
api POST snmp-test/query '{"host":"127.0.0.1","operation":"set","oids":["sysName"]}' | head -1
api POST snmp-test/query '{"host":"127.0.0.1","version":"3","oids":["sysName"]}' | head -1

echo "== upload a device MIB on the MIBs page, its names work at once"
docker exec -i "$NAME" sh -c 'cat > /tmp/NAPI-TEST-MIB.txt' <<'MIB'
NAPI-TEST-MIB DEFINITIONS ::= BEGIN
IMPORTS MODULE-IDENTITY, OBJECT-TYPE, Counter32, enterprises FROM SNMPv2-SMI;
napiTest MODULE-IDENTITY
    LAST-UPDATED "202610280000Z" ORGANIZATION "NapiLab" CONTACT-INFO "-"
    DESCRIPTION "Test." ::= { enterprises 99999 }
napiTestCounter OBJECT-TYPE
    SYNTAX Counter32 UNITS "frames" MAX-ACCESS read-only STATUS current
    DESCRIPTION "A counter." ::= { napiTest 1 }
END
MIB
dx "curl -sk -o /dev/null -w '%{http_code}\n' -H 'Authorization: Bearer $TOKEN' -F file=@/tmp/NAPI-TEST-MIB.txt https://127.0.0.1/api/v1/snmp/mibs/"
api GET 'snmp-test/mib-search?q=napiTest' | python3 -I -c 'import json,sys; l=sys.stdin.read().splitlines(); r=json.loads(l[1]); print(l[0], [(o["name"], o["oid"]) for o in r["objects"]], "modules:", r["modules"])'
api POST snmp-test/query '{"host":"127.0.0.1","oids":["napiTestCounter"]}' | show
echo OK
