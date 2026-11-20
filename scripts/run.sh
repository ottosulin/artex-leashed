#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

if [ ! -f .env ]; then
    cp .env.example .env
    pw=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
    python3 - "$ROOT/.env" "$pw" <<'PY'
import re
import sys

path, password = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
text = re.sub(r"^POSTGRES_PASSWORD=.*$", "POSTGRES_PASSWORD=" + password, text, flags=re.MULTILINE)
open(path, "w", encoding="utf-8").write(text)
PY
    echo "[run] created .env with a random POSTGRES_PASSWORD" >&2
fi

chmod 600 .env 2>/dev/null || true

set -a
# shellcheck disable=SC1091
. ./.env
set +a

if [ -z "${POSTGRES_PASSWORD:-}" ]; then
    echo "POSTGRES_PASSWORD is empty in .env" >&2
    exit 1
fi

if ! command -v leash >/dev/null 2>&1; then
    echo "leash CLI not found; install it from https://github.com/strongdm/leash" >&2
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not reachable" >&2
    exit 1
fi

TARGET_IMAGE=${TARGET_IMAGE:-artex-leashed:local}
LEASH_IMAGE=${LEASH_IMAGE:-public.ecr.aws/s5i7k8t3/strongdm/leash:latest}
LEASH_LISTEN=${LEASH_LISTEN:-127.0.0.1:18080}
export TARGET_IMAGE

if ! docker image inspect "$TARGET_IMAGE" >/dev/null 2>&1; then
    echo "image $TARGET_IMAGE not found; run ./scripts/build.sh first" >&2
    exit 1
fi

if [ "${SKIP_HOST_CHECK:-0}" != "1" ]; then
    "$ROOT/scripts/check-host.sh"
fi

"$ROOT/scripts/render-policy.sh"

"$ROOT/scripts/stop.sh" >/dev/null 2>&1 || true
rm -rf "$ROOT/.runtime/leash-share" "$ROOT/.runtime/leash-work" "$ROOT/.runtime/leash-cfg" "$ROOT/.runtime/leash-log" "$ROOT/.runtime/leash-workspace"
docker volume create artex-leashed-pgdata >/dev/null
mkdir -p data keys .runtime/leash-share .runtime/leash-work .runtime/leash-cfg .runtime/leash-log .runtime/leash-workspace
chmod 0700 keys 2>/dev/null || true

export LEASH_SHARE_DIR="$ROOT/.runtime/leash-share"
export LEASH_WORK_DIR="$ROOT/.runtime/leash-work"
export LEASH_CFG_DIR="$ROOT/.runtime/leash-cfg"
export LEASH_LOG_DIR="$ROOT/.runtime/leash-log"
export LEASH_WORKSPACE_DIR="$ROOT/.runtime/leash-workspace"

env_args=(-e POSTGRES_PASSWORD)
for key in \
    ANTHROPIC_API_KEY \
    OPENAI_API_KEY \
    ARTEX_LLM_PROVIDER \
    ARTEX_LLM_MODEL \
    ARTEX_LLM_BASE_URL \
    ARTEX_LLM_PROXY \
    DROP_NET_RAW; do
    if [ -n "${!key:-}" ]; then
        env_args+=(-e "$key")
    fi
done
if [ -z "${ARTEX_UPDATE_CHECK:-}" ]; then
    env_args+=(-e ARTEX_UPDATE_CHECK=0)
else
    env_args+=(-e ARTEX_UPDATE_CHECK)
fi

cd "$ROOT/.runtime"
export TARGET_CONTAINER=${TARGET_CONTAINER:-artex-leashed}
export LEASH_CONTAINER=${LEASH_CONTAINER:-artex-leashed-manager}
exec leash -I \
    --image "$TARGET_IMAGE" \
    --leash-image "$LEASH_IMAGE" \
    --policy "$ROOT/policy/generated.cedar" \
    --listen "$LEASH_LISTEN" \
    -p 127.0.0.1:8787:8787 \
    -p 127.0.0.1:8788:8788 \
    -v "$ROOT/data:/app/data" \
    -v "$ROOT/keys:/app/keys" \
    -v "artex-leashed-pgdata:/app/pgdata" \
    "${env_args[@]}" \
    -- /app/artex-entrypoint.sh -addr :8787 -proxy :8788
