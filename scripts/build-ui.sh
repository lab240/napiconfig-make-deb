#!/usr/bin/env bash
# Runs inside node:22 container.
# Mounts: /src = napi-ui (ro), /out = output dir.
# Env: VITE_REVISION, HOST_UID, HOST_GID.
set -euo pipefail

mkdir -p /build
tar -C /src -cf - \
    --exclude=node_modules --exclude=dist --exclude=.git --exclude=coverage \
    --exclude=.env --exclude=.env.local . | tar -C /build -xf -
cd /build

# Husky hooks need .git; not used here.
export HUSKY=0
npm ci --no-audit --no-fund

export VITE_BASE_URL=/api
export VITE_REVISION
npm run build

tar -C dist -cf /out/napi-ui-dist.tar .
chown "${HOST_UID}:${HOST_GID}" /out/napi-ui-dist.tar
echo "== built napi-ui dist ($(du -sh dist | cut -f1))"
