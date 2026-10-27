#!/usr/bin/env bash
# Build the napiconfig .deb (napi-api + napi-ui, own Python) for arm64.
#
#   ./build.sh
#
# Env:
#   API_SRC, UI_SRC   source repos (default: ../napi-api, ../napi-ui)
#   OUT_DIR           output dir (default: ./out)
#   PKG_REV           Debian revision (default: 1)
#   MAINTAINER        Maintainer field
#   SKIP_UI_BUILD=1   reuse $OUT_DIR/napi-ui-dist.tar
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
API_SRC=$(realpath "${API_SRC:-$HERE/../napi-api}")
UI_SRC=$(realpath "${UI_SRC:-$HERE/../napi-ui}")
OUT_DIR=${OUT_DIR:-$HERE/out}
PKG_REV=${PKG_REV:-1}
MAINTAINER=${MAINTAINER:-NapiLab <info@napilab.ru>}
NODE_IMAGE=${NODE_IMAGE:-node:22-bookworm-slim}
BUILD_IMAGE=${BUILD_IMAGE:-debian:bookworm}

API_VER=$(sed -n "s/^__version__ = '\(.*\)'/\1/p" "$API_SRC/app/__about__.py")
UI_VER=$(sed -n 's/^  "version": "\(.*\)",/\1/p' "$UI_SRC/package.json")
UI_REV=$(git -C "$UI_SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)
[ -n "$API_VER" ] && [ -n "$UI_VER" ] || { echo "Cannot read versions" >&2; exit 1; }
PKG_VERSION=${API_VER}+ui${UI_VER}-${PKG_REV}

mkdir -p "$OUT_DIR"
OUT_DIR=$(realpath "$OUT_DIR")
IDS=(-e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)")

echo "napiconfig $PKG_VERSION: napi-api $API_VER ($(git -C "$API_SRC" rev-parse --short HEAD 2>/dev/null)), napi-ui $UI_VER ($UI_REV)"

if [ "${SKIP_UI_BUILD:-0}" != 1 ] || [ ! -f "$OUT_DIR/napi-ui-dist.tar" ]; then
    docker run --rm "${IDS[@]}" -e VITE_REVISION="$UI_REV" \
        -v "$UI_SRC:/src:ro" -v "$HERE/scripts:/scripts:ro" -v "$OUT_DIR:/out" \
        -v napi-deb-npm:/root/.npm \
        "$NODE_IMAGE" bash /scripts/build-ui.sh
fi

docker run --rm "${IDS[@]}" \
    -e PKG_VERSION="$PKG_VERSION" -e API_VERSION="$API_VER" -e UI_VERSION="$UI_VER" \
    -e MAINTAINER="$MAINTAINER" \
    -v "$API_SRC:/src:ro" -v "$HERE:/deb:ro" -v "$OUT_DIR:/out" \
    -v napi-deb-pip:/root/.cache/pip -v napi-deb-pbs:/root/.cache/pbs \
    "$BUILD_IMAGE" bash /deb/scripts/build-napiconfig.sh

ls -l "$OUT_DIR/napiconfig_${PKG_VERSION}_arm64.deb"
