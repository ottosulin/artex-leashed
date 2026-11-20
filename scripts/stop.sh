#!/usr/bin/env bash
set -euo pipefail

docker rm -f artex-leashed artex-leashed-manager >/dev/null 2>&1 || true
docker ps -a --filter 'name=artex-leashed' --format '{{.Names}}' | while IFS= read -r name; do
    [ -n "$name" ] && docker rm -f "$name" >/dev/null
done
echo "stopped artex-leashed containers; volumes and data were kept"
