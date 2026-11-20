#!/usr/bin/env bash
set -euo pipefail

if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker daemon is not reachable" >&2
    exit 1
fi
if ! command -v leash >/dev/null 2>&1; then
    echo "ERROR: leash CLI not found; install it from https://github.com/strongdm/leash" >&2
    exit 1
fi

lsm=$(docker run --rm --privileged --pid=host alpine:3.20 sh -lc \
    'mount -t securityfs securityfs /sys/kernel/security 2>/dev/null || true; cat /sys/kernel/security/lsm 2>/dev/null' \
    2>/dev/null | tr -d '\r')

normalized=$(printf '%s' "$lsm" | tr ',' '\n' | tr -d ' ')
if ! printf '%s\n' "$normalized" | grep -qx 'bpf'; then
    cat >&2 <<EOF
ERROR: BPF LSM is not active in the Docker host kernel.
  active LSMs: ${lsm:-unknown}

Leash's kernel enforcement requires 'bpf' in /sys/kernel/security/lsm.
  - OrbStack on macOS: supported by Leash; use OrbStack as the Docker engine.
  - Linux: boot with lsm=...,bpf on a kernel with CONFIG_BPF_LSM=y.
  - Rancher Desktop / Docker Desktop: their Linux VMs do not activate bpf by
    default. This setup refuses to run in proxy-only mode because it would not
    enforce non-HTTP egress.
EOF
    exit 1
fi

ipv6=$(docker run --rm --network bridge alpine:3.20 sh -lc \
    'ip -6 route show default 2>/dev/null | head -1' 2>/dev/null || true)
if [ -n "$ipv6" ]; then
    echo "ERROR: Docker's default bridge has an IPv6 default route: $ipv6" >&2
    echo "Leash's v1 connect hook only evaluates IPv4; disable IPv6 on the Docker host." >&2
    exit 1
fi

echo "OK: Docker reachable; bpf LSM active (${lsm}); no IPv6 default route on the default bridge."
