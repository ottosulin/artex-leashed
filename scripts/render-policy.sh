#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TARGET_IMAGE=${TARGET_IMAGE:-artex-leashed:local}

if [ ! -f "$ROOT/config/allowlist.txt" ]; then
    echo "config/allowlist.txt is missing; copy config/allowlist.txt.example and add your domains" >&2
    exit 1
fi

if ! docker image inspect "$TARGET_IMAGE" >/dev/null 2>&1; then
    echo "image $TARGET_IMAGE not found; run ./scripts/build.sh first" >&2
    exit 1
fi

resolv=$(docker run --rm --network bridge --entrypoint cat "$TARGET_IMAGE" /etc/resolv.conf)

dns_ips=$(printf '%s\n' "$resolv" | awk '$1 == "nameserver" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $2 }' | sort -u)
if [ -z "$dns_ips" ]; then
    echo "could not detect an IPv4 Docker DNS resolver from:" >&2
    printf '%s\n' "$resolv" >&2
    exit 1
fi

args=(--allowlist "$ROOT/config/allowlist.txt" --output "$ROOT/policy/generated.cedar")
while IFS= read -r ip; do
    if [ -n "$ip" ]; then
        args+=(--dns "$ip")
    fi
done <<<"$dns_ips"

python3 "$ROOT/scripts/render_policy.py" "${args[@]}"
