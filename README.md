# Artex under Leash with a Cedar egress allowlist

Run [Artex](https://github.com/BaaRai/ARTEX) inside a [Leash](https://github.com/strongdm/leash)-governed
container whose network egress is deny-by-default and restricted to the company domains in the
live `config/allowlist.txt`, copied from the tracked
[`config/allowlist.txt.example`](config/allowlist.txt.example). The allowlist is rendered into a
Cedar policy that Leash loads at startup.

The Artex image is built from a pinned upstream commit and carries an embedded PostgreSQL, so the
only network path the agent needs is loopback plus the allowlist. There is no separate database
container to wire into Leash's network namespace.

## What is in this repository

| Path | Purpose |
| --- | --- |
| `config/allowlist.txt.example` | Tracked template using reserved `example.com` domains; copy it to the ignored local allowlist. |
| `scripts/render_policy.py` | Strict allowlist parser and Cedar policy renderer. |
| `scripts/tests/test_render_policy.py` | Offline unit tests for the renderer. |
| `Dockerfile` | Overlay that adds PostgreSQL 15 and the embedded-DB entrypoint to the pinned Artex image. |
| `LICENSE` | MIT license for this setup. |
| `docker/artex-entrypoint.sh` | Initializes/starts PostgreSQL, builds the DSN, supervises Artex, drops `NET_RAW`. |
| `scripts/build.sh` | Clones the pinned Artex commit, builds `artex-base:local`, then `artex-leashed:local`. |
| `scripts/render-policy.sh` | Detects the Docker DNS resolver and invokes the renderer. |
| `scripts/run.sh` | Preflight, policy render, `leash` launch with volumes and ports. |
| `scripts/check-host.sh` | Fails fast when the Docker host lacks active BPF LSM or has IPv6 egress. |
| `scripts/stop.sh` | Removes the Artex target/manager containers, keeps data. |
| `scripts/export-public.sh` | Copies only public-safe files to `dist/public` and scans for company-specific strings. |
| `policy/generated.cedar` | Generated policy (gitignored). |
| `docs/lima-qa.md` | Tested macOS recipe for a BPF-LSM-capable Lima VM. |
| `lima/leash-qa.yaml` | Lima VM definition used for verification. |

`config/allowlist.txt`, `.env`, `qa/`, and `.omo/` are intentionally gitignored. Use
`make public-export` to produce a public snapshot without them.

## Run securely with eBPF

This setup is only a security boundary when Leash's eBPF LSM programs attach to the kernel. That
depends on the Docker host's kernel and runtime, not on the container image. If eBPF cannot
attach, Leash's manager exits; the preflight also refuses to start. A proxy-only fallback would
filter HTTP(S) but leave SSH, databases, other ports, and raw sockets uncontrolled.

### What eBPF enforcement means here

When active, the privileged Leash manager attaches eBPF LSM programs to the governed cgroup's
`socket_connect`, `file_open`, and `bprm_check_security` hooks. The same Cedar policy is
transpiled into IPv4 network rules, file-open rules, and process-exec rules. The manager also runs
a transparent MITM proxy for HTTP(S) on ports 80 and 443. Only the manager is privileged; the
target keeps the default Docker capability set; its Artex wrapper drops `CAP_NET_RAW` before
starting PostgreSQL and Artex. The default posture is deny, and the generated policy has no
wildcard-all network permit.

### Host support matrix

| Host / engine | `bpf` in active LSM list | Use this setup? | Notes |
| --- | --- | --- | --- |
| Linux host, kernel 5.7+ with `lsm=...,bpf` | yes | recommended | rootful Docker, cgroup v2, BTF |
| OrbStack on macOS | yes (Leash-supported; verify) | supported | run `check-host.sh` first |
| Ubuntu 26.10 Lima VM from `docs/lima-qa.md` | yes | tested fallback | rootful Docker inside the VM; use `DOCKER_HOST` |
| Rancher Desktop (Alpine VM) | no | no | BPF LSM compiled but inactive (verified) |
| Docker Desktop (LinuxKit) | no | no | Leash has a degraded proxy-only mode; this setup does not use it |

"Compiled" means the kernel contains BPF LSM code. "Active" means `bpf` is in
`/sys/kernel/security/lsm`. Only the second lets Leash attach its programs.

### Host prerequisites

- Linux kernel 5.7 or newer (Leash's LSM hooks).
- Kernel config: `CONFIG_BPF_SYSCALL=y`, `CONFIG_BPF_JIT=y`, `CONFIG_BPF_LSM=y`,
  `CONFIG_DEBUG_INFO_BTF=y`, `CONFIG_CGROUPS=y`, `CONFIG_CGROUP_BPF=y`. If a flag is missing, use
  a kernel that has it; a boot parameter cannot add compiled-out code.
- Booted with `bpf` in the LSM list. This is fixed at boot; there is no sysctl.
- cgroup v2 unified: `docker info --format '{{.CgroupVersion}}'` prints `2`.
- Rootful Docker. Rootless lacks the privileges to attach BPF; the Docker info security options
  must not contain `name=rootless`.
- The daemon permits `--privileged` and `--cgroupns=host`; Leash uses both for the manager.
- `bpffs` mounted at `/sys/fs/bpf` and cgroup v2 mounted (normal on current distributions).
- No IPv6 default route in the governed network. Leash v1's connect hook evaluates IPv4 only;
  `check-host.sh` checks Docker's default bridge.
- The `leash` CLI on `PATH`, plus `git`, `python3`, and `make`. Install Leash with
  `npm install -g @strongdm/leash`, a release binary, or the macOS `leash` formula.
- The target image has `ca-certificates` / `update-ca-certificates`; the Artex image includes it.

### Check the host

```bash
./scripts/check-host.sh
docker info --format 'cgroup={{.CgroupVersion}} security={{json .SecurityOptions}}'
docker run --rm --privileged alpine:3.20 sh -lc 'test -f /sys/kernel/btf/vmlinux && echo BTF_OK || echo NO_BTF'
uname -r
```

`check-host.sh` checks Docker reachability, `bpf` in the active LSM list, and the IPv6 route. It
exits non-zero with the active list and a remedy when eBPF is unavailable. `BTF_OK` is required;
`NO_BTF` means the kernel lacks `CONFIG_DEBUG_INFO_BTF`, and Leash's CO-RE programs cannot load.
For a manual LSM check:

```bash
docker run --rm --privileged --pid=host alpine:3.20 sh -lc \
  'mount -t securityfs securityfs /sys/kernel/security 2>/dev/null || true; cat /sys/kernel/security/lsm'
```

`bpf` must appear in the comma-separated output. If `bpftool` is available, `bpftool feature probe`
should report that the `lsm` program type is available; that only proves the kernel has the code,
so still check the active list.

### Linux: activate the BPF LSM

1. Read the current active list:

   ```bash
   cat /sys/kernel/security/lsm
   ```

2. Add `bpf` to the kernel command line, preserving every existing module and its order. Example
   for an Ubuntu/Debian host whose list is `lockdown,capability,landlock,yama,apparmor`:

   ```bash
   sudoedit /etc/default/grub
   # GRUB_CMDLINE_LINUX_DEFAULT="quiet splash lsm=lockdown,capability,landlock,yama,apparmor,bpf"
   sudo update-grub
   sudo reboot
   ```

   On Fedora/RHEL, use the list that matches your host and `grubby`:

   ```bash
   sudo grubby --update-kernel=ALL --args="lsm=lockdown,capability,yama,selinux,bpf"
   sudo reboot
   ```

   On systemd-boot or another bootloader, update the equivalent kernel command line. Do not copy
   another distribution's list blindly: `lsm=` replaces the built-in order.

3. Verify:

   ```bash
   cat /sys/kernel/security/lsm | tr ',' '\n' | grep -x bpf
   ./scripts/check-host.sh
   ```

   If `bpf` is still missing, check `cat /proc/cmdline`, the bootloader entry, and the kernel
   config. A kernel without `CONFIG_BPF_LSM` or BTF cannot be fixed at runtime.

### macOS

- **OrbStack**: Leash lists OrbStack as supported. Start it, make it the Docker engine, then run
  `./scripts/check-host.sh` before building. This is the shortest supported macOS path.
- **Lima**: use [`docs/lima-qa.md`](docs/lima-qa.md) and
  [`lima/leash-qa.yaml`](lima/leash-qa.yaml). It boots an Ubuntu VM with rootful Docker and forwards
  the Docker socket and ports. Set `DOCKER_HOST` for every command:

  ```bash
  export DOCKER_HOST=unix:///tmp/leash-qa-lima/qa/sock/docker.sock
  ```

- **Rancher Desktop / Docker Desktop**: not supported for full enforcement. Rancher's VM has BPF
  LSM compiled but inactive; Docker Desktop's LinuxKit is not an enforcing target for Leash (its
  degraded developer mode is proxy-only). Do not use them for a real scope boundary.

### Do not skip the preflight

`run.sh` calls `check-host.sh` and exits if it fails. `SKIP_HOST_CHECK=1` exists for development
only. Without active eBPF, Leash either exits with
`Failed to attach lsm_connect LSM program` or runs in a degraded mode that filters HTTP(S) only.

## Quick start

Run this only after `./scripts/check-host.sh` passes on the Docker host.

```bash
[ -f .env ] || cp .env.example .env
[ -f config/allowlist.txt ] || cp config/allowlist.txt.example config/allowlist.txt
# Set POSTGRES_PASSWORD. Generate one with:
python3 -c 'import secrets; print(secrets.token_hex(24))'
# Add any LLM credentials, then review the domain list.
$EDITOR .env
$EDITOR config/allowlist.txt

./scripts/check-host.sh
./scripts/build.sh
./scripts/run.sh
```

If you copied `.env.example`, replace the `change-me-to-a-long-random-string` placeholder before
starting. `run.sh` sets `.env` to mode 0600, generates a random password only when `.env` is
missing, re-renders the policy, and starts Leash in the foreground. The first build compiles Artex
from source and takes a while; later runs reuse the images.

Open:

- Artex: <http://127.0.0.1:8787>
- Leash Control UI: <http://127.0.0.1:18080>

The one-time Artex setup token is printed in the target container log:

```bash
docker logs artex-leashed 2>&1 | grep -i "setup token"
```

## Configure egress

The tracked template is `config/allowlist.txt.example`; the live file is
`config/allowlist.txt` (gitignored). Copy it once, then edit the local file:

```bash
cp config/allowlist.txt.example config/allowlist.txt
```

One entry per line:

```
example.com
www.example.com
api.example.com:443
# *.example.com
```

Semantics:

- A bare host permits that exact host on any TCP port.
- `host:port` permits that exact host only on that port.
- `*.host` is an explicit wildcard, HTTP(S)-only, and enforced by Leash's proxy.
- Lines starting with `#` and blank lines are ignored.
- Schemes, paths, credentials, query strings, trailing dots, IPv6 literals, bare `*`, and
  single-label hosts (`*.com`) are rejected.
- Duplicates are removed and the output is sorted.

After editing:

```bash
# Optional: preview the generated policy without restarting
./scripts/render-policy.sh
# Ctrl-C the running leash, then:
./scripts/run.sh
```

`run.sh` re-renders on every start, so allowlist edits and Docker DNS changes are both picked up.

### The LLM endpoint is egress too

Artex needs to call its LLM provider. Add the provider host to the allowlist or Artex will start
but every model call will be denied. For a strict company-only boundary, point Artex at an internal
LLM gateway and allowlist only that gateway:

```
llm-gateway.internal.example.com:443
```

If you use a public provider, add its API host (for example `api.anthropic.com` or
`api.openai.com`) deliberately.

### DNS

`render-policy.sh` runs a throwaway container on Docker's default bridge, reads its
`/etc/resolv.conf`, and permits each IPv4 resolver on port 53. Without those permits, name
resolution fails inside the governed container. Docker's embedded resolvers `127.0.0.11` and
`127.0.0.53` are always included.

### Generated policy

`policy/generated.cedar` contains:

1. A filesystem/process baseline for Artex (`FileOpen*` and `ProcessExec` on `/`). The boundary in
   this setup is the network, not the filesystem; tighten this separately if you need to.
2. One `NetworkConnect` permit for `127.0.0.1`, the detected DNS resolver IPs on port 53, and every
   allowlist entry.
3. No wildcard-all network permit. Leash's default posture is deny, so anything absent is blocked.

The policy is validated by Leash at manager startup. If it does not compile, the manager exits and
`docker logs artex-leashed-manager` shows the Cedar error with a line number.

## How enforcement works

Leash starts two containers:

- **Target** (`artex-leashed`): the governed Artex image. The Leash CLI injects its
  `leash-entry` binary as PID 1; it installs Leash's MITM CA and writes the bootstrap markers. The
  CLI then runs the requested command
  (`/app/artex-entrypoint.sh -addr :8787 -proxy :8788`) in the target. PID 1 stays `leash-entry`;
  the wrapper and Artex are child processes.
- **Manager** (`artex-leashed-manager`): privileged, shares the target's network namespace, applies
  iptables/nftables redirects for TCP 80/443 to a transparent MITM proxy, drops QUIC, and enforces
  the Cedar policy through eBPF LSM. Only the manager is privileged.

Inside the target, `artex-entrypoint.sh`:

1. Drops `CAP_NET_RAW` (unless `DROP_NET_RAW=0`) so raw sockets cannot bypass the connect policy.
2. Initializes PostgreSQL in the `artex-leashed-pgdata` volume on first boot.
3. Starts PostgreSQL on `127.0.0.1:5432` only.
4. Creates the `artex` database and syncs the role password with `POSTGRES_PASSWORD`.
5. Exports `ARTEX_PG_DSN` for the local database and starts `/app/start.sh`.
6. On `docker stop`, forwards the signal to Artex and stops PostgreSQL.

Artex's UI/API is published on `127.0.0.1:8787` and its recording proxy on `127.0.0.1:8788`. The
Leash Control UI is on `127.0.0.1:18080`.

## Verify the boundary

First prove the manager attached its eBPF programs, not just that the containers started:

```bash
docker logs artex-leashed-manager 2>&1 | grep -E 'Successfully started monitoring (network|file|program)'
docker logs artex-leashed-manager 2>&1 | grep -iE 'Failed to attach|failed to attach' && echo 'FAIL: eBPF not attached' || echo 'PASS: no attach failure'
docker logs artex-leashed-manager 2>&1 | grep 'event=env.lsm'
```

The first command must print all three success lines: network connections/sendmsg, file opens, and
program execution. The third must show `bpf` in the LSM list. If the manager fell back to the HTTP
proxy only, stop: non-HTTP egress is not governed.

Inside the governed container, an allowed host should work:

```bash
docker exec artex-leashed curl -fsS --max-time 20 -o /dev/null -w '%{http_code}\n' https://example.com/
```

A denied host should produce a policy denial:

```bash
docker exec artex-leashed sh -lc \
  'curl -sS --max-time 20 -o /tmp/deny.out -w "%{http_code}\n" https://example.org/; cat /tmp/deny.out'
```

Expect `403` and a body containing `Connection denied by security policy`. The manager log also
records the decision:

```bash
docker logs artex-leashed-manager 2>&1 | grep -E 'Connect policy DENIED|no rule matched'
```

Confirm the generated policy has no wildcard-all permit:

```bash
grep -q 'Host::"\*"' policy/generated.cedar && echo 'FAIL: wildcard-all present' || echo 'PASS'
```

Run the offline renderer tests:

```bash
make test
```

## Security model and residual risks

**Enforced by Leash/Cedar**

- IPv4 outbound connections from the target cgroup that are not loopback, DNS, or allowlisted are
  denied by eBPF LSM.
- HTTP(S) on ports 80/443 is intercepted by the MITM proxy and checked against the hostname rules
  in the same Cedar policy.
- File opens and process exec are governed by the same policy; this setup permits them broadly so
  Artex and its tools can run.
- The default posture is deny; there is no `Host::"*"` permit.

**Not enforced / residual risks**

| Risk | What to do |
| --- | --- |
| Wildcard suffix matching | Leash's proxy matcher tests `strings.HasSuffix(hostname, suffix)`, so `*.example.com` can match `evil-example.com` when that IP is otherwise allowed. Prefer exact hosts; add wildcards only when you accept this upstream behavior. |
| IPv6 | Leash v1's connect hook only evaluates `AF_INET`. `check-host.sh` fails if the Docker default bridge has an IPv6 default route. Keep IPv6 disabled on the Docker host. |
| DNS exfiltration | Resolver IP:53 is intentionally permitted. A determined agent can encode data in DNS queries. Use a logging/filtering resolver for high-assurance work. |
| Non-HTTP ports | Leash's kernel rules pin exact hostnames to IPv4 at policy-load time. If an allowed host's IP changes, re-render and restart. Wildcard subdomains on non-HTTP ports are denied. |
| Raw sockets | `DROP_NET_RAW=1` removes `CAP_NET_RAW` from the governed container. This can make `nmap` SYN scans fail; `nmap -sT` (connect scan) still works. Setting it to `0` reopens the bypass. |
| Allowed hosts are not path/method scoped | The allowlist permits any path, method, and port on an allowed host. Use Artex's own target/scope rules and authorization for application-level limits. |
| Artex app-level scope | Leash is the network boundary. Mirror the same domains in Artex's company/task scope so the planner does not waste turns on out-of-scope assets. |
| Credentials in the container | Any LLM key you pass with `-e` is available to the target. Artex seals its process environment at startup, but the container is trusted with the key. Use scoped keys. |

### Hardening checklist

- [ ] `./scripts/check-host.sh` passes; `bpf` is active, not just compiled.
- [ ] Docker is rootful and uses cgroup v2; privileged containers are allowed.
- [ ] `config/allowlist.txt` contains exact company hosts; no wildcard-all, and ports are explicit where possible.
- [ ] The LLM endpoint is an internal gateway or a deliberately allowlisted host; no unrelated API hosts.
- [ ] `DROP_NET_RAW=1` unless a tool truly needs raw sockets.
- [ ] No IPv6 default route; IPv6 egress is disabled in Docker.
- [ ] DNS goes through a logging/filtering resolver; port 53 is the only DNS exception.
- [ ] Artex's company/task scope mirrors the allowlist; Leash is the network boundary.
- [ ] `.env` is 0600 with scoped keys; no secrets in the image or Git.
- [ ] Artex/Leash ports are bound to 127.0.0.1; do not expose them publicly.
- [ ] The Docker host is trusted: the Leash manager is privileged by design.
- [ ] Artex and Leash versions are pinned; rebuild deliberately.

## Operations

```bash
make check      # host preflight (BPF LSM + IPv6)
make build      # build Artex base + overlay
make run        # render policy and start Leash
make stop       # remove target/manager containers, keep data
make policy     # re-render policy with detected DNS
make test       # renderer unit tests
make clean      # remove .runtime and generated policy
make distclean  # remove data, keys, and the PostgreSQL volume
make public-export # copy public-safe files to dist/public
```

Data locations:

- `data/` — Artex traffic index, task files, transcripts (bind mount).
- `keys/` — `jwt.key` and `secret.key` (bind mount, mode 0700).
- `artex-leashed-pgdata` — PostgreSQL data (named Docker volume).

Back up the database volume and keys together:

```bash
mkdir -p backups
docker run --rm -v artex-leashed-pgdata:/pgdata:ro -v "$PWD/backups:/backup" \
  alpine:3.20 tar czf /backup/pgdata.tgz -C /pgdata .
tar czf backups/data-and-keys.tgz data keys
```

Reset everything (destroys Artex data and credentials):

```bash
make distclean
```

Update Artex by changing `ARTEX_REF` (a commit SHA, tag, or branch) and rebuilding:

```bash
ARTEX_REF=v0.6.0 ./scripts/build.sh
```

The default is the pinned commit in `scripts/build.sh`. Leash is pinned through `LEASH_IMAGE` in
`.env`; the CLI's `--leash-image` uses the same value.

## Publishing a public snapshot

Do not publish the working directory directly. It may contain the ignored live
`config/allowlist.txt`, `.env`, `keys/`, `data/`, `qa/`, `.omo/`, or `policy/generated.cedar`.
Create a public-safe copy instead:

```bash
make public-export
# output: dist/public
```

`export-public.sh` copies only the source, templates, docs, and scripts. It excludes the live
allowlist, secrets, runtime data, internal QA logs, and local plans, then scans the output for a
company-specific domain, a local user path, and an internal tool name. It deletes the snapshot if
any is found. Review `dist/public` before publishing.

## Troubleshooting

**`Failed to attach lsm_connect LSM program`** — BPF LSM is not active on the Docker host. Run
`./scripts/check-host.sh` on the Docker host, not on your Mac; it prints the active LSM list. Add
`bpf` to the kernel command line (see "Run securely with eBPF") and reboot. If the kernel lacks
`CONFIG_BPF_LSM` or BTF, use a different kernel; `SKIP_HOST_CHECK=1` does not let Leash attach.

**Docker reports cgroup v1, rootless Docker, or the host lacks BTF** — switch to rootful Docker on a
cgroup-v2 host with BTF (`/sys/kernel/btf/vmlinux`), or use the Lima/OrbStack path. Leash's manager
needs privileged container access to attach BPF.

**`failed to create MITM proxy: ... incomplete certificate authority state`** — a previous Leash
run left a CA cert without its private key. `run.sh` clears `.runtime/leash-*` on every start; if
you launch `leash` manually, remove those directories or run `scripts/stop.sh` first.

**`exec: "/leash/leash-entry-linux-arm64": no such file or directory`** — the Docker daemon cannot
see the Leash share directory (common with a remote VM). `run.sh` puts `LEASH_SHARE_DIR` under the
repository's `.runtime`, which is mounted in the Lima VM; if invoking `leash` manually, keep the
share/work dirs under a path the daemon can see and set `LEASH_SHARE_DIR`/`LEASH_WORK_DIR`.

**DNS failures inside the container** — The detected resolver changed or is IPv6. Re-run
`./scripts/render-policy.sh` and restart; inspect the `DNS resolvers` comment in
`policy/generated.cedar`.

**An allowed domain is denied** — Check for a wildcard entry, an IP that changed since the policy
was rendered, or a redirect to a host that is not in the allowlist. Re-render and restart.

**PostgreSQL permission errors** — Use the named volume (the default). If you switched `pgdata` to a
bind mount on macOS, the container may not be able to `chown` it; revert to the named volume.

**Containers already running** — `./scripts/stop.sh`, then `./scripts/run.sh`. Leash refuses to
start when `artex-leashed` or `artex-leashed-manager` already exists.

**Port already in use** — The stack binds `127.0.0.1:8787`, `8788`, and `18080`. Stop the conflicting
process or change the publish flags in `scripts/run.sh`.

## Verified setup

On 2026-11-20 the full path was verified on an isolated Ubuntu 26.10 VM (kernel 7.3.0) with active
LSMs `lockdown,capability,landlock,yama,apparmor,bpf,ima,evm`, using the Lima recipe. An allowlisted
host returned 200; a non-allowlisted host returned 403 with `Connection denied by security policy`;
the manager logged the denial and a restart preserved the PostgreSQL state. Rancher Desktop on
macOS did not activate `bpf`; the preflight correctly refused it. The public examples use the
reserved `example.com` and `example.org` domains.

## Upstream

- Artex: <https://github.com/BaaRai/ARTEX> (AGPL-3.0), pinned at
  `ab40834567475c449bb34f84a9aa50a6587cb471`.
- Leash: <https://github.com/strongdm/leash> (Apache-2.0). The `leash` CLI and
  `public.ecr.aws/s5i7k8t3/strongdm/leash` manager image must be compatible; this setup uses the
  CLI's default unless `LEASH_IMAGE` is set.

## License

This repository is MIT-licensed; see [LICENSE](LICENSE). Artex and Leash remain under their
upstream licenses (AGPL-3.0 and Apache-2.0, respectively).
