#!/usr/bin/env bash
# Runs inside debian:bookworm (oldest supported glibc: native modules built
# here work on bookworm, trixie and noble).
# Mounts: /src = napi-api (ro), /deb = napiconfig-make-deb (ro), /out = output dir with napi-ui-dist.tar.
# Env: PKG_VERSION, API_VERSION, UI_VERSION, MAINTAINER, HOST_UID, HOST_GID.
set -euo pipefail

# python-build-standalone: relocatable CPython, does not depend on the distro Python.
PBS_RELEASE=20261009
PBS_PYTHON=3.12.15
PBS_SHA256=2e1ba0e7f22e01c534caebf7f09e7820322bc0d055271d3434af671e8400f96f
PBS_FILE=cpython-${PBS_PYTHON}+${PBS_RELEASE}-aarch64-unknown-linux-gnu-install_only_stripped.tar.gz
PBS_URL=https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}/${PBS_FILE}

PREFIX=/opt/napiconfig
PY=$PREFIX/python/bin/python3
STAGE=/tmp/stage

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends gcc libc6-dev ca-certificates curl >/dev/null

echo "== napiconfig ${PKG_VERSION}: napi-api ${API_VERSION}, napi-ui ${UI_VERSION}, python ${PBS_PYTHON}"

# Build in the final path: scripts and .pyc files keep correct paths.
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
mkdir -p /root/.cache/pbs
if ! echo "$PBS_SHA256  /root/.cache/pbs/$PBS_FILE" | sha256sum -c --quiet 2>/dev/null; then
    curl -fsSL -o "/root/.cache/pbs/$PBS_FILE" "$PBS_URL"
    echo "$PBS_SHA256  /root/.cache/pbs/$PBS_FILE" | sha256sum -c --quiet
fi
tar -C "$PREFIX" -xzf "/root/.cache/pbs/$PBS_FILE"   # → $PREFIX/python

"$PY" -m pip install -q --disable-pip-version-check --no-warn-script-location \
    --require-hashes --prefer-binary -r /deb/requirements.lock

tar -C /src -cf - \
    --exclude='__pycache__' --exclude='*.pyc' \
    --exclude='app/.env' --exclude='app/.env.dev' --exclude='app/data' --exclude='*.db' \
    app | tar -C "$PREFIX" -xf -

# The device never installs packages here; drop what a service does not need:
# pip, tests, tcl/tk, headers. bin/python3.12 is linked statically,
# libpython3.12.so is only for embedding.
"$PY" - <<'EOF2'
import pathlib, shutil, sys
root = pathlib.Path(sys.prefix)
lib = root / 'lib' / ('python%d.%d' % sys.version_info[:2])
site = lib / 'site-packages'
drop = [*site.glob('pip'), *site.glob('pip-*.dist-info'), *site.glob('*/tests')]
drop += [lib / d for d in ('test', 'idlelib', 'tkinter', 'turtledemo', 'ensurepip', 'lib2to3')]
drop += [*lib.glob('config-*'), *root.glob('lib/tcl*'), *root.glob('lib/tk*'),
         *root.glob('lib/itcl*'), *root.glob('lib/thread*'), *root.glob('lib/pkgconfig'),
         root / 'include', root / 'share']
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

# App dir is read-only on the device; ship bytecode.
"$PY" -m compileall -q -j0 "$PREFIX/app" "$PREFIX/python/lib" >/dev/null 2>&1 || true

# Smoke test: the app imports.
(cd /tmp && printf 'KEY_API_SECRET=build-check\nENVIRONMENT=production\nDATABASE_URI=sqlite:////tmp/check.db\n' > "$PREFIX/app/.env" \
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
    echo "Python ${PBS_PYTHON}: python-build-standalone ${PBS_RELEASE}, ${PBS_URL}"
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
    -e "s|@SIZE@|${SIZE}|" \
    /deb/pkg/napiconfig/DEBIAN/control.in > "$STAGE/DEBIAN/control"
(cd "$STAGE" && find . -path ./DEBIAN -prune -o -type f -printf '%P\0' \
    | xargs -0 md5sum > DEBIAN/md5sums)

DEB="/out/napiconfig_${PKG_VERSION}_arm64.deb"
dpkg-deb --root-owner-group -Zxz --build "$STAGE" "$DEB" >/dev/null
chown "${HOST_UID}:${HOST_GID}" "$DEB"
echo "== built $DEB ($(du -h "$DEB" | cut -f1), installed ${SIZE} KiB)"
