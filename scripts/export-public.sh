#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DEST=${1:-"$ROOT/dist/public"}

if [ -e "$DEST" ]; then
    echo "refusing to overwrite $DEST; remove it first" >&2
    exit 1
fi

mkdir -p "$DEST/config" "$DEST/docker" "$DEST/docs" "$DEST/lima" "$DEST/policy" "$DEST/scripts/tests"

cp "$ROOT/README.md" "$ROOT/Dockerfile" "$ROOT/Makefile" "$ROOT/LICENSE" "$ROOT/.dockerignore" \
    "$ROOT/.gitignore" "$ROOT/.env.example" "$ROOT/pyrightconfig.json" "$DEST/"
cp "$ROOT/config/allowlist.txt.example" "$DEST/config/"
cp "$ROOT/docker/artex-entrypoint.sh" "$DEST/docker/"
cp "$ROOT/docs/lima-qa.md" "$DEST/docs/"
cp "$ROOT/lima/leash-qa.yaml" "$DEST/lima/"
cp "$ROOT/policy/.gitkeep" "$DEST/policy/"
cp "$ROOT/scripts/"*.py "$ROOT/scripts/"*.sh "$DEST/scripts/"
cp "$ROOT/scripts/tests/"*.py "$DEST/scripts/tests/"

chmod +x "$DEST"/scripts/*.sh "$DEST"/docker/*.sh "$DEST"/scripts/render_policy.py

forbidden_domain="super""metrics"
local_path="/Users""/"
internal_tool="smit""ty"
failed=0

for pattern in "$forbidden_domain" "$local_path" "$internal_tool"; do
    if grep -RInF -- "$pattern" "$DEST"; then
        echo "refusing public export: found forbidden string: $pattern" >&2
        failed=1
    fi
done

if [ "$failed" -ne 0 ]; then
    rm -rf "$DEST"
    exit 1
fi

echo "public export written to $DEST"
