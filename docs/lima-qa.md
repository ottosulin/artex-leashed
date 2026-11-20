# Running the stack on macOS without OrbStack

Leash needs `bpf` in the Docker host's active LSM list. Rancher Desktop's Alpine VM has BPF LSM
compiled but not active (verified); Docker Desktop's LinuxKit VM is not a supported enforcing
target for Leash (Leash has a degraded proxy-only mode for it). Neither can run this stack in
enforcing mode. OrbStack is the simplest supported macOS engine. If you do not have OrbStack,
this recipe boots an isolated Ubuntu VM with Lima and rootful Docker. It was used to verify the
allow/deny scenarios in this repository.

The VM intentionally installs rootful Docker; rootless Docker cannot attach BPF.

The VM mounts your home directory writable because Leash bind-mounts the policy, data, keys, and
its share directory. Use a dedicated VM, not a shared production one.

## 1. Create the VM

The `limactl` bundled with Rancher Desktop works; Homebrew Lima works too.

```bash
LIMA_HOME=/tmp/leash-qa-lima \
  "/Applications/Rancher Desktop.app/Contents/Resources/resources/darwin/lima/bin/limactl" \
  start --name=qa --tty=false ./lima/leash-qa.yaml
```

With Homebrew Lima:

```bash
brew install lima
LIMA_HOME=/tmp/leash-qa-lima limactl start --name=qa --tty=false ./lima/leash-qa.yaml
```

The first boot downloads an Ubuntu cloud image and installs rootful Docker. The YAML forwards
`8787`, `8788`, and `18080`, and exposes the VM's Docker socket at
`$LIMA_HOME/qa/sock/docker.sock`.

## 2. Confirm BPF LSM is active

```bash
LIMA_HOME=/tmp/leash-qa-lima limactl shell qa \
  sh -lc 'cat /sys/kernel/security/lsm; echo; docker info --format "{{.ServerVersion}}"'
```

`bpf` must appear in the comma-separated list. The tested Ubuntu 26.10 image reports:

```
lockdown,capability,landlock,yama,apparmor,bpf,ima,evm
```

If `bpf` is absent, add it to the kernel command line inside the VM and reboot:

```bash
LIMA_HOME=/tmp/leash-qa-lima limactl shell qa sudo sh -lc '
  cp /etc/default/grub /etc/default/grub.bak
  sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\\(.*\\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\\1 lsm=lockdown,capability,landlock,yama,apparmor,bpf\"/" /etc/default/grub
  update-grub
  reboot
'
```

Wait for the VM to come back, then re-check `/sys/kernel/security/lsm`.

## 3. Point Docker at the VM

```bash
export DOCKER_HOST=unix:///tmp/leash-qa-lima/qa/sock/docker.sock
docker info --format '{{.OperatingSystem}} {{.Architecture}}'
```

The Docker CLI warns that `DOCKER_HOST` overrides the active Rancher context; that is intended.

## 4. Build and run

Build directly against the VM (the repository is mounted at the same path):

```bash
DOCKER_HOST=$DOCKER_HOST ./scripts/build.sh
DOCKER_HOST=$DOCKER_HOST ./scripts/run.sh
```

If you already built the image with Rancher Desktop and want to transfer it instead:

```bash
docker save artex-leashed:local -o "$HOME/artex-leashed-image.tar"
DOCKER_HOST=$DOCKER_HOST docker load -i "$HOME/artex-leashed-image.tar"
DOCKER_HOST=$DOCKER_HOST ./scripts/run.sh
```

Then open <http://127.0.0.1:8787> and <http://127.0.0.1:18080>. The allow/deny checks in the
main README work with the same `DOCKER_HOST`:

```bash
DOCKER_HOST=$DOCKER_HOST docker exec artex-leashed \
  curl -fsS --max-time 20 -o /dev/null -w '%{http_code}\n' https://example.com/
DOCKER_HOST=$DOCKER_HOST docker exec artex-leashed sh -lc \
  'curl -sS --max-time 20 -o /tmp/deny.out -w "%{http_code}\n" https://example.org/; cat /tmp/deny.out'
```

## 5. Clean up

```bash
DOCKER_HOST=$DOCKER_HOST ./scripts/stop.sh
LIMA_HOME=/tmp/leash-qa-lima limactl stop qa
LIMA_HOME=/tmp/leash-qa-lima limactl delete qa
rm -rf /tmp/leash-qa-lima
```

The Ubuntu cloud image URL in `lima/leash-qa.yaml` is a moving target. If it is gone, replace the
`images:` entry with the current `ubuntu-*-server-cloudimg-arm64.img` URL from
<https://cloud-images.ubuntu.com/>.
