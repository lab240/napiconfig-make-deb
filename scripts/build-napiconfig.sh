#!/usr/bin/env bash
# Runs inside debian:bookworm (oldest supported glibc: native modules built
# here work on bookworm, trixie and noble).
# Mounts: /src = napi-api (ro), /deb = napiconfig-make-deb (ro), /out = output dir with napi-ui-dist.tar.
# Env: ARCH (arm64|amd64), PKG_VERSION, API_VERSION, UI_VERSION, MAINTAINER, HOST_UID, HOST_GID.
#
# The container runs natively (arm64 here). For another ARCH nothing of the
# target runs: wheels are fetched for the target platform (all deps ship
# binary wheels), and .pyc files are the same on every CPU.
set -euo pipefail

# python-build-standalone: relocatable CPython, does not depend on the distro Python.
PBS_RELEASE=20261009
PBS_PYTHON=3.12.15
declare -A PBS_SHA256=(
    [aarch64]=2e1ba0e7f22e01c534caebf7f09e7820322bc0d055271d3434af671e8400f96f
    [x86_64]=ffa8f85f1b56e88b687f08d743d817015524b86a9365fd921243132b80f1a36d
)
pbs_file() { echo "cpython-${PBS_PYTHON}+${PBS_RELEASE}-$1-unknown-linux-gnu-install_only_stripped.tar.gz"; }
pbs_url() { echo "https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}/$(pbs_file "$1")"; }

ARCH=${ARCH:-arm64}
case "$ARCH" in
    arm64) CPU=aarch64 ;;
    amd64) CPU=x86_64 ;;
    *) echo "unsupported ARCH=$ARCH" >&2; exit 1 ;;
esac
HOST_CPU=$(uname -m)
# strip for the target CPU (the native one is the same package).
STRIP=${CPU}-linux-gnu-strip

PREFIX=/opt/napiconfig
PY=$PREFIX/python/bin/python3
STAGE=/tmp/stage

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends gcc libc6-dev ca-certificates curl \
    "binutils-${CPU//_/-}-linux-gnu" >/dev/null

echo "== napiconfig ${PKG_VERSION} ${ARCH}: napi-api ${API_VERSION}, napi-ui ${UI_VERSION}, python ${PBS_PYTHON}"

# Build in the final path: scripts and .pyc files keep correct paths.
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
mkdir -p /root/.cache/pbs
# Unpacks python-build-standalone for a CPU into $2/python.
fetch_pbs() {
    local f; f=/root/.cache/pbs/$(pbs_file "$1")
    if ! echo "${PBS_SHA256[$1]}  $f" | sha256sum -c --quiet >/dev/null 2>&1; then
        curl -fsSL -o "$f" "$(pbs_url "$1")"
        echo "${PBS_SHA256[$1]}  $f" | sha256sum -c --quiet
    fi
    mkdir -p "$2"
    tar -C "$2" -xzf "$f"
}
fetch_pbs "$CPU" "$PREFIX"   # → $PREFIX/python

PIP_ARGS=(-q --disable-pip-version-check --no-warn-script-location --require-hashes -r /deb/requirements.lock)
if [ "$CPU" = "$HOST_CPU" ]; then
    TOOL_PY=$PY
    "$PY" -m pip install --prefer-binary "${PIP_ARGS[@]}"
else
    # Same Python version for the host installs the target wheels.
    rm -rf /tmp/host-python
    fetch_pbs "$HOST_CPU" /tmp/host-python
    TOOL_PY=/tmp/host-python/python/bin/python3
    PYV=${PBS_PYTHON%.*}   # 3.12
    SITE=$PREFIX/python/lib/python$PYV/site-packages
    "$TOOL_PY" -m pip install "${PIP_ARGS[@]}" --upgrade --target "$SITE" \
        --only-binary=:all: --implementation cp --python-version "$PYV" \
        --abi "cp${PYV/./}" --abi abi3 --abi none \
        $(for v in 17 24 28 31 34 36; do echo --platform manylinux_2_${v}_${CPU}; done) \
        --platform manylinux2014_${CPU} --platform manylinux2010_${CPU} --platform linux_${CPU}
fi

tar -C /src -cf - \
    --exclude='__pycache__' --exclude='*.pyc' \
    --exclude='app/.env' --exclude='app/.env.dev' --exclude='app/data' --exclude='*.db' \
    app | tar -C "$PREFIX" -xf -

# The device never installs packages here; drop what a service does not need:
# pip, tests, tcl/tk, headers. bin/python3.12 is linked statically,
# libpython3.12.so is only for embedding.
"$TOOL_PY" - "$PREFIX/python" <<'EOF2'
import pathlib, shutil, sys
root = pathlib.Path(sys.argv[1])
lib = root / 'lib' / ('python%d.%d' % sys.version_info[:2])
site = lib / 'site-packages'
drop = [*site.glob('pip'), *site.glob('pip-*.dist-info'), *site.glob('*/tests')]
drop += [lib / d for d in ('test', 'idlelib', 'tkinter', 'turtledemo', 'ensurepip', 'lib2to3')]
drop += [*lib.glob('config-*'), *root.glob('lib/tcl*'), *root.glob('lib/tk*'),
         *root.glob('lib/itcl*'), *root.glob('lib/thread*'), *root.glob('lib/pkgconfig'),
         root / 'include', root / 'share']
drop += [*root.glob('lib/libtcl*'), *root.glob('lib/libtk*'), site / 'include', site / 'bin']
drop += [*root.glob('bin/pip*'), *root.glob('bin/idle*'), *root.glob('bin/2to3*'),
         *root.glob('bin/python*-config'), *root.glob('lib/libpython*'),
         *lib.glob('lib-dynload/_tkinter*')]
drop += list(root.rglob('__pycache__'))
for p in drop:
    if p.is_dir() and not p.is_symlink():
        shutil.rmtree(p)
    elif p.exists() or p.is_symlink():
        p.unlink()
EOF2

# Some wheels (dbus_fast for x86_64) carry debug info: ~25 MB.
find "$PREFIX/python/lib" -name '*.so*' -type f -exec "$STRIP" --strip-debug {} +

# App dir is read-only on the device; ship bytecode.
"$TOOL_PY" -m compileall -q -j0 "$PREFIX/app" "$PREFIX/python/lib" >/dev/null 2>&1 || true

# Every native module must be for the target CPU.
"$TOOL_PY" - "$PREFIX" "$CPU" <<'EOF2'
import pathlib, struct, sys
want = {'aarch64': 183, 'x86_64': 62}[sys.argv[2]]
bad = []
for p in pathlib.Path(sys.argv[1]).rglob('*.so*'):
    if p.is_file() and not p.is_symlink():
        h = p.read_bytes()[:20]
        if h[:4] == b'\x7fELF' and struct.unpack('<H', h[18:20])[0] != want:
            bad.append(str(p))
if bad:
    sys.exit('wrong CPU: ' + ', '.join(bad))
EOF2

# Smoke test: the app imports (native build only; test other CPUs on the target).
[ "$CPU" != "$HOST_CPU" ] || (cd /tmp && printf 'KEY_API_SECRET=build-check\nENVIRONMENT=production\nDATABASE_URI=sqlite:////tmp/check.db\n' > "$PREFIX/app/.env" \
    && PYTHONPATH="$PREFIX" "$PY" -c 'import app.main, ssl, sqlite3, ctypes, dbus_fast, psutil, bcrypt, yaml, influxdb_client; print("import ok,", ssl.OPENSSL_VERSION)' \
    && rm -f "$PREFIX/app/.env" /tmp/check.db)

# Stage the package tree.
rm -rf "$STAGE"
mkdir -p "$STAGE/opt" "$STAGE/usr/share/napiconfig/html"
cp -a /deb/pkg/napiconfig/root/. "$STAGE/"
cp -a "$PREFIX" "$STAGE/opt/"
ln -s /etc/napi-api/napi-api.env "$STAGE$PREFIX/app/.env"
tar -C "$STAGE/usr/share/napiconfig/html" -xf /out/napi-ui-dist.tar
{
    echo "napiconfig: napi-api ${API_VERSION}, napi-ui ${UI_VERSION} (Igor Kha, MIT)"
    echo "Python ${PBS_PYTHON}: python-build-standalone ${PBS_RELEASE}, $(pbs_url "$CPU")"
    echo "MIB modules in /usr/share/napiconfig/mibs: see /usr/share/napiconfig/mibs/README"
    echo "Packaging: https://github.com/lab240"
} | install -D -m 644 /dev/stdin "$STAGE/usr/share/doc/napiconfig/copyright"

chmod -R u+rwX,go+rX,go-w "$STAGE"
mkdir -p "$STAGE/DEBIAN"
cp -a /deb/pkg/napiconfig/DEBIAN/postinst /deb/pkg/napiconfig/DEBIAN/prerm \
      /deb/pkg/napiconfig/DEBIAN/postrm "$STAGE/DEBIAN/"
echo /etc/nginx/sites-available/napi.conf > "$STAGE/DEBIAN/conffiles"
SIZE=$(du -sk --exclude=DEBIAN "$STAGE" | cut -f1)
sed -e "s|@VERSION@|${PKG_VERSION}|" \
    -e "s|@MAINTAINER@|${MAINTAINER}|" \
    -e "s|@API_VERSION@|${API_VERSION}|" \
    -e "s|@UI_VERSION@|${UI_VERSION}|" \
    -e "s|@PYTHON_VERSION@|${PBS_PYTHON}|" \
    -e "s|@ARCH@|${ARCH}|g" \
    -e "s|@SIZE@|${SIZE}|" \
    /deb/pkg/napiconfig/DEBIAN/control.in > "$STAGE/DEBIAN/control"
(cd "$STAGE" && find . -path ./DEBIAN -prune -o -type f -printf '%P\0' \
    | xargs -0 md5sum > DEBIAN/md5sums)

DEB="/out/napiconfig_${PKG_VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group -Zxz --build "$STAGE" "$DEB" >/dev/null
chown "${HOST_UID}:${HOST_GID}" "$DEB"
echo "== built $DEB ($(du -h "$DEB" | cut -f1), installed ${SIZE} KiB)"
