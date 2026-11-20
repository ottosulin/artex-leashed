#!/usr/bin/env python3
"""Render a deny-by-default Leash Cedar policy from a domain allowlist.

The allowlist is the operator-facing source of truth. This script validates it
strictly and emits a Cedar file that Leash loads at startup. It also permits the
Docker resolver IPs on port 53 and loopback, which the governed container needs
for DNS and for its embedded PostgreSQL / recording proxy.
"""

from __future__ import annotations

import argparse
import ipaddress
import re
import sys
from collections.abc import Iterable, Sequence
from pathlib import Path

LABEL_RE = re.compile(r"^(?!-)[a-z0-9-]{1,63}(?<!-)$")
DEFAULT_DNS_IPS = ("127.0.0.11", "127.0.0.53")


class PolicyError(ValueError):
    pass


def _cedar_string(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def _parse_port(raw: str, line_no: int) -> int:
    if not raw.isdigit():
        raise PolicyError(f"line {line_no}: port must be a number, got {raw!r}")
    port = int(raw)
    if not 1 <= port <= 65535:
        raise PolicyError(f"line {line_no}: port must be 1-65535, got {port}")
    return port


def parse_entry(raw: str, line_no: int) -> tuple[str, int | None]:
    text = raw.strip()
    if not text:
        return "", None
    if text.startswith("#"):
        return "", None
    if any(ch.isspace() for ch in text):
        raise PolicyError(f"line {line_no}: whitespace is not allowed inside an entry")
    if text == "*":
        raise PolicyError(
            f"line {line_no}: '*' would disable the egress boundary; list explicit hosts"
        )
    for token in ("://", "/", "@", "?", "#"):
        if token in text:
            raise PolicyError(
                f"line {line_no}: {token!r} is not allowed; use host or host:port only"
            )

    if text.count(":") > 1:
        raise PolicyError(f"line {line_no}: IPv6 literals are not supported by Leash v1")

    host_part = text
    port: int | None = None
    if ":" in text:
        host_part, port_raw = text.rsplit(":", 1)
        port = _parse_port(port_raw, line_no)

    host_part = host_part.lower()
    if host_part.endswith("."):
        raise PolicyError(f"line {line_no}: trailing dots are not supported")
    if host_part.startswith("*."):
        base = host_part[2:]
        wildcard = True
    else:
        base = host_part
        wildcard = False

    if "*" in base:
        raise PolicyError(
            f"line {line_no}: wildcards are only allowed as a single leading '*.'"
        )
    if not base or ".." in base:
        raise PolicyError(f"line {line_no}: invalid hostname {host_part!r}")
    labels = base.split(".")
    if len(labels) < 2:
        raise PolicyError(
            f"line {line_no}: {host_part!r} must contain at least two labels"
        )
    for label in labels:
        if not LABEL_RE.match(label):
            raise PolicyError(f"line {line_no}: invalid DNS label {label!r}")
    if len(base) > 253:
        raise PolicyError(f"line {line_no}: hostname exceeds 253 characters")

    normalized = f"{'*.' if wildcard else ''}{base}"
    return normalized, port


def parse_allowlist(text: str) -> list[tuple[str, int | None]]:
    entries: list[tuple[str, int | None]] = []
    seen: set[tuple[str, int | None]] = set()
    for line_no, raw in enumerate(text.splitlines(), start=1):
        host, port = parse_entry(raw, line_no)
        if not host:
            continue
        key = (host, port)
        if key not in seen:
            seen.add(key)
            entries.append(key)
    entries.sort(key=lambda item: (item[0], item[1] or 0))
    return entries


def validate_dns_ips(values: Iterable[str]) -> list[str]:
    ips: list[str] = []
    seen: set[str] = set()
    for raw in values:
        value = raw.strip()
        if not value:
            continue
        try:
            ip = ipaddress.IPv4Address(value)
        except ipaddress.AddressValueError as exc:
            raise PolicyError(f"invalid DNS resolver IPv4 address {value!r}") from exc
        normalized = str(ip)
        if normalized not in seen:
            seen.add(normalized)
            ips.append(normalized)
    return ips


def render(
    allowlist_text: str,
    dns_ips: Sequence[str] = (),
    *,
    include_localhost: bool = True,
) -> str:
    entries = parse_allowlist(allowlist_text)
    if not entries:
        raise PolicyError(
            "the allowlist is empty; refusing to render a policy that would deny all egress"
        )

    resolved_dns = validate_dns_ips([*DEFAULT_DNS_IPS, *dns_ips])

    hosts: list[str] = []
    if include_localhost:
        hosts.append('Host::"127.0.0.1"')
    for ip in resolved_dns:
        hosts.append(f'Host::"{ip}:53"')
    for host, port in entries:
        value = host if port is None else f"{host}:{port}"
        hosts.append(f'Host::"{_cedar_string(value)}"')

    wildcard_count = sum(1 for host, _ in entries if host.startswith("*."))
    rendered_hosts = ",\n      ".join(hosts)
    policy = f"""// Generated by scripts/render_policy.py from config/allowlist.txt.
// Do not edit by hand; edit the allowlist and re-run the renderer.
//
// Network posture: deny by default. This policy grants filesystem/process access
// Artex needs to run and permits network egress only to loopback, the Docker DNS
// resolvers, and the allowlisted hosts.
//
// Allowlist entries: {len(entries)} ({wildcard_count} wildcard, HTTP(S)-only)
// DNS resolvers: {", ".join(resolved_dns)}

permit (principal, action in [Action::"FileOpen", Action::"FileOpenReadOnly", Action::"FileOpenReadWrite"], resource)
when {{ resource in [ Dir::"/" ] }};

permit (principal, action == Action::"ProcessExec", resource)
when {{ resource in [ Dir::"/" ] }};

permit (principal, action == Action::"NetworkConnect", resource)
when {{
  resource in [
      {rendered_hosts}
  ]
}};
"""
    return policy


def write_policy(output: Path, policy: str) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(policy, encoding="utf-8")
    output.chmod(0o644)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--allowlist", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--dns",
        action="append",
        default=[],
        metavar="IP",
        help="IPv4 resolver address to permit on port 53 (repeatable)",
    )
    parser.add_argument(
        "--no-localhost",
        action="store_true",
        help="do not permit 127.0.0.1 (the default setup needs it for PostgreSQL)",
    )
    args = parser.parse_args(argv)

    try:
        allowlist_text = args.allowlist.read_text(encoding="utf-8")
        policy = render(
            allowlist_text,
            args.dns,
            include_localhost=not args.no_localhost,
        )
        write_policy(args.output, policy)
    except PolicyError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except OSError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    entries = parse_allowlist(allowlist_text)
    wildcard_count = sum(1 for host, _ in entries if host.startswith("*."))
    print(
        f"rendered {len(entries)} allowlist entries ({wildcard_count} wildcard) "
        f"and {len(validate_dns_ips([*DEFAULT_DNS_IPS, *args.dns]))} DNS resolver(s) "
        f"to {args.output}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
