#!/usr/bin/env bash
# Regenerate requirements.in / requirements.lock from napi-api pyproject.toml.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
API_SRC=$(realpath "${API_SRC:-$HERE/../napi-api}")

python3 -I -c '
import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
print("\n".join(d["tool"]["hatch"]["envs"]["default"]["dependencies"]))
' "$API_SRC/pyproject.toml" > "$HERE/requirements.in"

uv pip compile -q "$HERE/requirements.in" \
    --python-version 3.12 --python-platform aarch64-unknown-linux-gnu \
    --generate-hashes --custom-compile-command "./scripts/lock.sh" \
    -o "$HERE/requirements.lock"
echo "updated $HERE/requirements.lock"
