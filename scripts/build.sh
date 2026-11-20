#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
fi

ARTEX_REPO=${ARTEX_REPO:-https://github.com/BaaRai/ARTEX.git}
ARTEX_REF=${ARTEX_REF:-ab40834567475c449bb34f84a9aa50a6587cb471}
ARTEX_BASE_IMAGE=${ARTEX_BASE_IMAGE:-artex-base:local}
TARGET_IMAGE=${TARGET_IMAGE:-artex-leashed:local}
LEASH_IMAGE=${LEASH_IMAGE:-public.ecr.aws/s5i7k8t3/strongdm/leash:latest}

if [ -n "${ARTEX_SRC:-}" ]; then
    SRC=$ARTEX_SRC
    if [ ! -f "$SRC/Dockerfile" ]; then
        echo "ARTEX_SRC=$SRC does not contain the Artex Dockerfile" >&2
        exit 1
    fi
else
    SRC="$ROOT/.artex-src"
    if [ ! -d "$SRC/.git" ]; then
        git clone --filter=blob:none "$ARTEX_REPO" "$SRC"
    fi
    if ! git -C "$SRC" fetch --depth 1 origin "$ARTEX_REF"; then
        git -C "$SRC" fetch origin
    fi
    git -C "$SRC" checkout --detach --force "$ARTEX_REF"
fi

echo "[build] Artex source: $SRC"
echo "[build] Artex ref:    $ARTEX_REF"
echo "[build] base image:   $ARTEX_BASE_IMAGE"
docker build --pull \
    --build-arg "ARTEX_VERSION=$ARTEX_REF" \
    -t "$ARTEX_BASE_IMAGE" \
    "$SRC"

echo "[build] overlay image: $TARGET_IMAGE"
docker build \
    --build-arg "LEASH_IMAGE=$LEASH_IMAGE" \
    --build-arg "ARTEX_BASE_IMAGE=$ARTEX_BASE_IMAGE" \
    -t "$TARGET_IMAGE" \
    -f "$ROOT/Dockerfile" \
    "$ROOT"

docker image inspect --format 'image={{.Id}} cmd={{json .Config.Cmd}}' "$TARGET_IMAGE"
