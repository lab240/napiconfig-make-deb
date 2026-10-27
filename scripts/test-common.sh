# Sourced by the test scripts after dx() is defined.

INFLUX_KEY_FPR=24C975CBA61A024EE1B631787C3D57159FC2F927

# Newest built package, as seen inside the container (out/ is mounted at /pkgs).
DEB=/pkgs/$(basename "$(ls -t "$HERE"/out/napiconfig_*_arm64.deb | head -1)")

# napiconfig depends on influxdb2 (InfluxData repo) and telegraf-light (repo.napilab.ru).
add_repos() {
    dx "set -e
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gpg >/dev/null
        curl -fsSL https://repos.influxdata.com/influxdata-archive.key | gpg --dearmor > /tmp/influx.gpg 2>/dev/null
        gpg --show-keys --with-colons /tmp/influx.gpg 2>/dev/null | grep -q '^fpr:::::::::$INFLUX_KEY_FPR:'
        install -D -m 644 /tmp/influx.gpg /etc/apt/keyrings/influxdata-archive.gpg
        echo 'deb [signed-by=/etc/apt/keyrings/influxdata-archive.gpg] https://repos.influxdata.com/debian stable main' \
            > /etc/apt/sources.list.d/influxdata.list
        curl -fsSL https://repo.napilab.ru/napilab.gpg | gpg --dearmor > /usr/share/keyrings/napilab.gpg 2>/dev/null
        echo 'deb [arch=arm64 signed-by=/usr/share/keyrings/napilab.gpg] https://repo.napilab.ru stable main' \
            > /etc/apt/sources.list.d/napilab.list
        apt-get update -qq"
}
