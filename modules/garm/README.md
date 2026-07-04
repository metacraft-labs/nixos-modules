# `services.garm` — GARM (GitHub Actions Runner Manager) control plane

Declarative NixOS module for the [cloudbase/garm](https://github.com/cloudbase/garm)
control plane, wired for the **Ephemeral-Windows-Runners-GARM** campaign: fresh
Windows-11 VMs boot from a golden image, JIT-register with GitHub, run exactly one
job, and are destroyed — orchestrated by GARM through the stateless
`garm-provider-vmharness` libvirt provider.

This document is the operator runbook and security posture reference (campaign
milestone **M6**). It covers: the hardened-but-provider-capable systemd unit and
each sandbox relaxation; declarative App / provider / scale-set / metrics wiring;
the security posture (fork-PR gating, network isolation, secret management);
observability (Prometheus); the eval-time resource guard; and known cosmetic log
noise.

---

## 1. Quick start (production shape)

```nix
services.garm = {
  enable = true;

  # API + guest-facing controller URLs. The metadata/callback base URLs must be
  # reachable BY THE GUEST — on the libvirt NAT network that is the host bridge
  # IP (virbr0 = 192.168.122.1), NEVER localhost.
  apiServer = { bind = "0.0.0.0"; port = 9997; };
  metadataURL = "http://192.168.122.1:9997/api/v1/metadata";
  callbackURL = "http://192.168.122.1:9997/api/v1/callbacks";

  # Prometheus /metrics on the same apiserver port.
  metrics = { enable = true; disableAuth = true; period = "60s"; };

  # GitHub App forge credentials, declarative. The PEM is staged at runtime via
  # LoadCredential (agenix) and NEVER enters the Nix store.
  github = {
    enable = true;
    appId = 3115338;
    installationId = 117072647;
    appKeyFile = "/run/agenix/github-runners/mcl-app-key";
  };

  # The libvirt/KVM provider. Turning this on switches the unit to the
  # provider-capable posture (see §2).
  providers.vmharness = {
    enable = true;
    poolDir = "/var/lib/libvirt/images";
    memoryMb = 4096;
    vcpus = 4;
    images.golden.sourceImage = "/storage/iso/golden-win11-cloudbase-sysprep.qcow2";
  };

  # Declarative autoscale policy (applied at runtime via garm-cli — see §4).
  scaleSets.windows-ephemeral = {
    provider = "vmharness";
    image = "golden";
    osType = "windows";
    maxRunners = 2;      # concurrency cap
    minIdleRunners = 0;  # scale-to-zero (raise for a warm pool)
  };

  # Eval-time resource guard budget (see §6).
  hostBudget = { memoryMb = 65536; vcpus = 32; };
};
```

Orgs and scale sets carry GitHub-side state (a message-queue subscription, a
numeric id) and are therefore NOT part of `config.toml`; they are provisioned at
runtime with `garm-cli` against the live, App-authenticated org (see §4). Only the
credentials, provider, metrics, and controller URLs are declarative.

---

## 2. THE M6 CENTERPIECE — running the libvirt provider under a hardened unit

The M0 forge-less boot ran GARM under a `DynamicUser` with a **maximal** sandbox
(`ProtectSystem=strict`, `PrivateDevices`, `MemoryDenyWriteExecute`,
`DeviceAllow=[]`, `~@resources` syscall filter). That is ideal for a pure-Go API
daemon but **fatal** for the libvirt provider, which GARM execs as a child: the
provider shells to `virsh`/`qemu-img`/`genisoimage`, talks to the
`qemu:///system` libvirt socket, and ultimately drives `/dev/kvm`.

The module therefore uses a **provider-conditional posture**:

- **`providers.vmharness.enable = false`** (M0/boot-gate): the strict
  DynamicUser sandbox, **byte-for-byte unchanged**. The M0 boot gate still passes.
- **`providers.vmharness.enable = true`**: a dedicated `garm` system user in the
  `libvirtd`/`kvm` groups, with **only** the minimum relaxations below. Everything
  that does not block the provider stays on.

### Relaxations (provider posture) — each and why

| Change | M0 posture | Provider posture | Why the relaxation is required |
|---|---|---|---|
| **User** | `DynamicUser=true` | dedicated `garm` system user | A DynamicUser gets a fresh uid every boot and **cannot be a stable group member**. The provider needs a persistent uid in `libvirtd`+`kvm` to reach `qemu:///system` and `/dev/kvm`. |
| **Groups** | none | `SupplementaryGroups = [libvirtd kvm]` | Group-gated access to the libvirt socket (`/run/libvirt/libvirt-sock`, `libvirtd`) and `/dev/kvm` (`kvm`). |
| **ProtectSystem** | `strict` | `full` | `strict` makes the whole FS read-only except explicit `ReadWritePaths`; the provider writes per-job overlay + nvram + config-drive into the pool dir and touches the libvirt runtime. `full` keeps `/usr`,`/boot`,`/etc` read-only (the important protection) while allowing the granted paths below. |
| **ReadWritePaths** | (n/a) | pool dir, `/var/lib/libvirt`, `/run/libvirt` | Explicit write grants for the VM pool artifacts + libvirt runtime socket. `StateDirectory` already grants the GARM state dir. |
| **PrivateDevices** | `true` | **removed** | `PrivateDevices=true` hides `/dev/kvm`; qemu cannot start a HW-accelerated guest without it. Scoped instead via `DeviceAllow` (below). |
| **DeviceAllow** | (implicit deny-all) | `/dev/kvm rw` + null/zero/full/random/urandom/ptmx | Grant **exactly** the devices the provider/qemu path needs, nothing more. |
| **MemoryDenyWriteExecute** | `true` | **removed** | qemu (and some tool child processes) JIT / map W+X pages; MDWE breaks them. Dropped **only** in the provider posture. |
| **SystemCallFilter** | `@system-service ~@privileged ~@resources` | **removed** | The provider execs a chain of VM tooling (qemu-img, virsh, cdrkit `mkisofs`); `mkisofs` is **killed by SIGSYS** under `@system-service` (verified: `status=31/SYS, core dumped`). Rather than chase a vendored tool's exact syscall (brittle), the filter is dropped for the provider path. Isolation stays strong via the non-root user, `NoNewPrivileges`, empty caps, device scoping, and namespace/realtime restrictions. |
| **PATH** | (none) | cdrkit(genisoimage)+qemu+libvirt via unit `path` | GARM does **not** forward its PATH to external providers; the provider resolves `genisoimage` via `LookPath`. The provider block sets `environment_variables = ["PATH"]` and the unit contributes a PATH containing `genisoimage`. `virsh`/`qemu-img` are absolute (from the provider config). |

### Filesystem access for the non-root `garm` user (M6 integration notes)

Running the provider as a **non-root** user (instead of root as the M4/M5
harnesses did) surfaces two real access requirements the root path masked:

1. **Golden readability.** The provider opens the golden as the qemu-img CoW
   backing file. The golden **and every parent directory** must be readable +
   traversable by the `garm` user. If the golden lives under a group-gated path
   (e.g. `/storage/... root:metacraft 0770`), grant a POSIX ACL:
   ```
   setfacl -m u:garm:--x /storage
   setfacl -m u:garm:r-x /storage/iso
   setfacl -m u:garm:r-- /storage/iso/<golden>.qcow2
   ```
   or add `garm` to the owning group via `services.garm.extraGroups`.
2. **Pool-dir writability.** The provider writes the per-job overlay +
   config-drive + nvram into `providers.vmharness.poolDir`. The shared
   `/var/lib/libvirt/images` is root-only (`0711`), so the module defaults
   `poolDir` to a **garm-owned** `/var/lib/garm/pool` and provisions it via
   systemd-tmpfiles as `garm:libvirtd 0771`. qemu runs the domains as root on a
   stock NixOS libvirtd host, so it reads the overlays regardless. If you point
   `poolDir` at a shared pool, grant `garm` write access there yourself.

**Everything else stays hardened** in both postures: `NoNewPrivileges`,
`ProtectHome`, `PrivateTmp`, `ProtectKernel{Tunables,Modules,Logs}`,
`ProtectControlGroups`, `ProtectClock`, `ProtectHostname`, `ProtectProc=invisible`,
`ProcSubset=pid`, `RestrictNamespaces`, `RestrictRealtime`, `RestrictSUIDSGID`,
`LockPersonality`, `RemoveIPC`, `RestrictAddressFamilies` (INET/INET6/UNIX only),
`SystemCallArchitectures=native`, empty `CapabilityBoundingSet`/`AmbientCapabilities`,
`UMask=0077`. This is still a **superset** of the upstream `contrib/garm.service`
(which only sets `User=garm`).

---

## 3. Declarative App / provider wiring

- **App credentials** are emitted as a `[[github]]` block with `auth_type = "app"`.
  The App PEM is multi-line, so it cannot be inlined; the render hook copies it from
  the `LoadCredential`-staged path to a stable `0600` file under `stateDir` and the
  block's `private_key_path` points there. **The PEM never enters the store.**

  > **GARM constraint (important).** GARM imports config `[[github]]` credentials
  > into its DB only via the legacy one-shot `migrateCredentialsToDB`
  > (`cmd/garm/main.go`: `cfg.Database.MigrateCredentials = cfg.Github`), and only
  > (a) on the **first** DB open (before the credentials table exists) **and** (b)
  > if an **admin user already exists** at that instant. GARM's first-run flow
  > creates the admin via the API *after* boot, so on a **fresh deploy the import is
  > always skipped** ("Admin user doesn't exist. This is a new deploy."). The
  > `[[github]]` block is therefore effective only for **upgrading** a pre-existing
  > single-user GARM, not for greenfield installs. For a fresh deploy, register the
  > credentials once with `garm-cli github credentials add ... --private-key-path
  > <stateDir>/app-key.pem` — using the App ID / installation ID from
  > `services.garm.github` and the **module-staged PEM**. Every input is still
  > declarative (module options + LoadCredential); only the final `garm-cli`
  > registration is a runtime step, exactly like org/scale-set creation. A future
  > reconcile activation can automate this idempotently.
- **Controller URLs** (`metadata_url`, `callback_url`) go in `[default]` and must be
  guest-reachable (host bridge IP).
- **Provider** is a `[[provider]]` external block pointing at the
  `garm-provider-vmharness` binary + a secret-free provider `config.toml` carrying
  `virsh_path`/`qemu_img_path`/`libvirt_uri`/`network`/`pool_dir`/`uefi_*`/
  `memory_mb`/`vcpus` + the golden `[images.*]` map (all from module options).

---

## 4. Provisioning orgs + scale sets at runtime

Scale sets carry GitHub-side state, so after the daemon is up:

```bash
# org (references the declarative App creds by name)
garm-cli organization add --name metacraft-labs --credentials mcl-app \
  --webhook-secret "$(openssl rand -hex 16)"   # scale sets ignore the webhook

# scale set (the runs-on: selector is the scale-set NAME)
garm-cli scaleset add --org <ORG_ID> --provider-name vmharness \
  --image golden --name windows-ephemeral --flavor default --enabled \
  --min-idle-runners 0 --max-runners 2 --os-type windows --os-arch amd64 \
  --runner-bootstrap-timeout 30
```

The `services.garm.scaleSets.<name>` option records the **intended** policy so a
host config documents its concurrency in one place; a future reconcile activation
can apply it. `garm-cli controller update --minimum-job-age-backoff 0` makes
scale-to-zero react eagerly.

---

## 5. Security posture

### (a) Fork-PR / untrusted-code gating

**Self-hosted runners must never auto-run fork-PR jobs.** GitHub-hosted runners are
ephemeral and disposable; self-hosted runners — even ephemeral ones — expose the
host libvirt/KVM control plane to whatever code a job runs. Mitigations, in order
of strength:

1. **Org runner-group scoping** (primary): put the ephemeral scale set in a
   dedicated org runner group and restrict it to **selected private repositories**.
   Fork PRs from public repos then cannot target these runners at all.
2. **Require approval for outside collaborators / all outside contributors** in the
   org → Actions → *Fork pull request workflows* settings (`Require approval for all
   external contributors`). No workflow (hence no runner request) runs until a
   maintainer approves.
3. **Label discipline**: the `runs-on:` selector is the scale-set NAME. Do not put
   the ephemeral scale set on public repos whose workflows accept untrusted input.

The ephemeral model itself is a strong secondary control: each job runs in a fresh
VM destroyed afterward (no state bleed — proved by the M6 gate), so even a
malicious job cannot persist into the next.

### (b) Network isolation for runner VMs

The per-job VMs attach to the libvirt **NAT** `default` network (virbr0,
192.168.122.0/24). Posture:

- Guests reach the host's GARM metadata/callback endpoint (virbr0 = 192.168.122.1)
  and the public internet (GitHub, actions downloads) through NAT.
- Guests are **isolated from each other** at the workload level by being ephemeral
  and single-job; they share the NAT subnet, so for stronger tenant isolation use a
  per-tenant libvirt network or `<network><forward mode='nat'/><ip>` with
  `isolated` semantics, or nftables rules on virbr0 restricting guest→guest and
  guest→host-control-plane traffic to only the GARM port.
- The GARM API/metrics bind should be an **overlay/LAN or bridge** interface, never
  the public internet. On this host virbr0 is a trusted interface so guests reach
  the host on the GARM port without opening the host firewall to the world.
- **Do not** give runner VMs a route to the host management plane, the deploy
  agent, the binary cache signing keys, or other tenants. The default NAT already
  prevents inbound host→guest; restrict guest→host to the GARM port where feasible.

### (c) Secret management

All GARM secrets are runtime-rendered and **never** in the Nix store:

- **DB passphrase** + **JWT secret**: generated on first boot and persisted `0600`
  under `stateDir` (or supplied via `dbPassphraseFile`/`jwtSecretFile` +
  LoadCredential). The store holds only a template with `@SENTINEL@` placeholders.
- **GitHub App PEM**: staged via `LoadCredential` from the agenix path
  (`github.appKeyFile`) and copied to a `0600` file under `stateDir`; the store
  never sees it. Verify with `strings $(readlink /run/current-system) | grep -i
  BEGIN.*PRIVATE` returning nothing garm-related, and the gate asserts no PEM in
  `/nix/store`.

---

## 6. Observability (Prometheus)

Set `metrics.enable = true`. GARM serves `/metrics` on the **same apiserver port**.
With `disableAuth = true` it is scrapeable without a JWT metrics-token (keep the
endpoint on a trusted interface). Otherwise mint a token with
`garm-cli metrics-token create` and scrape with an `Authorization` header.

Scrape config for the existing monitoring stack:

```yaml
scrape_configs:
  - job_name: "garm"
    metrics_path: /metrics
    static_configs:
      - targets: ["<garm-host>:9997"]
    # if disable_auth = false:
    # authorization: { credentials: "<metrics-token>" }
```

Key series (namespace `garm_`): `garm_health` (gauge, alert on `== 0`),
`garm_runner_status`, `garm_runner_operations_total` / `garm_runner_errors_total`
(by `operation`,`provider`), `garm_scaleset_desired_runner_count` /
`garm_scaleset_max_runners` / `garm_scaleset_min_idle_runners`,
`garm_github_rate_limit_remaining`. Minimal alerts:

- `garm_health == 0` for 5m → GARM unhealthy.
- `rate(garm_runner_errors_total[15m]) > 0` → provider create/delete failures.
- `garm_github_rate_limit_remaining < 100` → App rate-limit pressure.

---

## 7. Eval-time resource guard (M5 guard promoted to a module assertion)

The M5 autoscale gate enforced `MAX_RUNNERS * memory` against free RAM at **runtime**
(harness-only). M6 promotes this to a **module assertion** so a bad config fails to
**eval**:

```
sum over scaleSets (maxRunners * providers.vmharness.memoryMb) <= hostBudget.memoryMb
sum over scaleSets (maxRunners * providers.vmharness.vcpus)    <= hostBudget.vcpus
```

An over-committed config aborts `nixos-rebuild`/`nix flake check` with, e.g.:

> services.garm: worst-case ephemeral guest RAM (sum of maxRunners *
> providers.vmharness.memoryMb = 81920 MiB) exceeds hostBudget.memoryMb (16384
> MiB). Lower maxRunners/memoryMb or raise hostBudget.memoryMb.

This is a *ceiling*, not a live free-RAM check — the autoscale gate's runtime guard
still applies on top for transient host load.

---

## 8. Known cosmetic log noise: `%!s(<nil>)`

Every consolidate cycle GARM may log:

```
failed to consolidate runner state ... provider binary <path> returned error: %!s(<nil>)
```

This is a **GARM-side** Go formatting artifact, **not** a provider bug. In
`runner/providers/v0.1.1/external.go` GARM wraps the provider's error with
`NewProviderError("... returned error: %s", execPath, err)`; when `err` is a
nil-valued wrapped error in the consolidate/GetInstance path, `%s` renders it as
`%!s(<nil>)`. The `garm-provider-vmharness` provider returns clean results:
`ListInstances`/`List` return `(nil, nil)` on the empty case (verified in
`internal/backend/virsh.go` `listFiltered` and `internal/provider/provider.go`
`ListInstances`), and `DeleteInstance` treats absence as success (idempotent). The
noise is **cosmetic** — it does not affect correctness (all M4/M5 phases were green
with VMs correctly created and destroyed). We do **not** patch the vendored GARM
(read-only in this workspace); the fix belongs upstream (guard the log/format on a
non-nil error). Tracked here for operators who see it.

---

## 9. Through-the-module e2e (M6 evidence)

The M6 gate `checks/t_ephemeral_runner_security_and_metrics.sh` runs a real one-job
ephemeral e2e **through the declarative `services.garm` module** (not a concrete
root config): the module-built hardened unit starts GARM, the provider clones a
fresh Windows VM, JIT-registers, runs one job, and destroys the VM. It additionally
asserts: no state bleed between jobs (a marker written in job 1 is absent in a fresh
job-2 VM), `/metrics` is served, no secret material in `/nix/store`, and — via a
sibling eval — the resource-guard assertion fires on a bad config.

**Prerequisites** (documented; the full run needs org+App+KVM+root):
- Run as root on the KVM host (`/dev/kvm`, `qemu:///system`, libvirt `default` net).
- The Windows golden (prefer the sysprepped
  `/storage/iso/golden-win11-cloudbase-sysprep.qcow2`) with cloudbase-init + the
  actions runner staged; UTC RTC.
- OVMF firmware under `/run/libvirt/nix-ovmf`.
- The GitHub App PEM readable at `/run/agenix/github-runners/mcl-app-key` (App
  3115338 / installation 117072647 on metacraft-labs, `Self-hosted runners: R/W`).
- `gh` authenticated with `repo`+`admin:org`.

The gate is ISOLATED + SELF-CLEANING: a unique scale-set name + a throwaway repo it
creates and deletes; it uses ONLY `garm-*`/`m6-*` names and never touches
production (`windows-runner-001`) or the concurrent `sysprep2-*` workstream.
