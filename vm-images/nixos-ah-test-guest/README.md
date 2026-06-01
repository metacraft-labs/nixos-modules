# nixos-ah-test-guest

A NixOS aarch64 guest image preloaded with the toolchain Agent Harbor's
`just test-all` needs. Part of **M34** in the Multi-OS VM Automation
Campaign.

## Why this exists

The Agent Harbor (AH) test suite (`just test-all` and every equivalent
at-scale `cargo nextest` invocation) is currently known to hang macOS
hosts. The campaign's M33 triage milestone catalogs which test crates
account for the resource peaks — but the triage itself has to run
_inside a VM_, never on the host. This image is the canonical VM for
that work and for the downstream `just test-in-vm` Justfile target
(M36) that productionizes the workflow.

See the Multi-OS-VM-Automation-Campaign milestone file in
`reprobuild-specs/` for the full Phase-C context.

## What's inside

The NixOS configuration in [`configuration.nix`](./configuration.nix)
provisions:

- **Rust toolchain** — `rustc`, `cargo`, `clippy`, `rustfmt`,
  `rust-analyzer`, `cargo-nextest`. AH's flake bring its own fenix-pinned
  toolchain at `nix develop` time; this is the bootstrap probe layer.
- **Nim 2.x** — `nim2`, `nimble` for the AgentFS Nim bindings and the
  vm-harness library.
- **pixi**, **just**, **mutagen**, **mutagen-compose** — the rest of the
  AH developer tooling triad referenced by `pixi.toml`, the AH `Justfile`,
  and `ah-mutagen-sync`.
- **Nix** (multi-user) with the AH cachix substituters trusted, so the
  first `nix develop` against the synced AH source tree pulls from cache
  instead of rebuilding rustc/playwright/chromium from source.
- **System libraries the AH `nix/devshell.nix` Linux branch lists**:
  `openssl`, `libseccomp`, `libcap`, `fuse3`, `libuv`, `btrfs-progs`,
  `pkg-config`, `cmake`, `ninja`, `gcc`, `binutils`.
- **Instrumentation tooling for M33** — GNU `time`, `procps`, `sysstat`,
  `lsof`, `htop`, `bottom`, `strace`. These are what the
  `AH-Test-Resource-Profile.md` triage methodology invokes.
- **Source-control + script runtimes** — `git`, `bash`, `python3` with
  `psutil`/`pyyaml`/`requests`, `nodejs`, `yarn-berry`.
- A locked, key-only `agent` account with passwordless sudo and a
  cloud-init NoCloud seed for first-boot SSH key injection.

Resource caps baked in by default (declared as constants in
`configuration.nix` and as builder-argument defaults in `default.nix`):

| Resource | Default | Rationale                                                     |
| -------- | ------- | ------------------------------------------------------------- |
| vCPUs    | 8       | half of a 16-core M-series host                               |
| RAM      | 16 GiB  | observed cargo LTO peak ≈ 12 GiB + headroom                   |
| Disk     | 100 GiB | cargo `target/` ≈ 40 GiB, `/nix/store` ≈ 20 GiB, slack 40 GiB |

These are _measurement defaults_ sized to let M33 observe true peaks
without throttling. M37 (the host-starvation guard milestone) will tune
them downwards once the M33 profile lands in
`agent-harbor/specs/Public/AH-Test-Resource-Profile.md`.

## Building the image

The image is exposed as a flake-parts package via the
`vm-images` module exported by this repository's `flake.nix`. From a
consumer flake:

```nix
{
  inputs.nixos-modules.url = "github:metacraft-labs/nixos-modules";

  outputs = { nixpkgs, nixos-modules, ... }:
    let
      pkgs = nixpkgs.legacyPackages.aarch64-linux;
      vmImages = import (nixos-modules + /vm-images) {
        inherit pkgs;
        lib = pkgs.lib;
      };
      nixosAhTestGuest = import (nixos-modules + /vm-images/nixos-ah-test-guest) {
        inherit pkgs;
        lib = pkgs.lib;
      };
    in {
      packages.aarch64-linux.nixos-ah-test-guest = nixosAhTestGuest.makeNixosAhTestGuest { };
    };
}
```

Then:

```
nix build .#nixos-ah-test-guest
./result/bin/run-vm        # launches qemu-system-aarch64
```

On an Apple Silicon macOS host, the simplest path is Tart:

```
nix build .#nixos-ah-test-guest
tart create --from-disk ./result/disk.qcow2 ah-test-guest
tart run ah-test-guest
# cloud-init authorizes the bundled ssh-key/id_ed25519 on first boot
```

## SSH access

The cloud-init NoCloud seed injects a fixed test SSH key (see
[`cloud-init.nix`](./cloud-init.nix), `generateTestSSHKey`). The
private key is bundled at `$out/ssh-key/id_ed25519` of the image
package. **Do not reuse this key for anything other than disposable
development VMs.**

The host-side launcher forwards host TCP `2228` to the guest's port 22
by default (overridable via `AH_VM_SSH_PORT`). Connecting:

```
ssh -p 2228 -i ./result/ssh-key/id_ed25519 agent@localhost
```

## Verifying the toolchain (M34 verification)

```
ssh -p 2228 -i ./result/ssh-key/id_ed25519 agent@localhost \
  'rustc --version && nim --version && just --version && mutagen version && pixi --version'
```

That command line is the literal check executed by the M34 verification
tests `e2e_nixos_ah_test_guest_boots_with_all_toolchains` and
`e2e_nixos_ah_test_guest_pixi_environment_loads` (the latter additionally
syncs the AH source tree and runs `pixi shell --frozen` in it).

## How to update the image when AH's flake inputs change

The image deliberately does **not** vendor AH source code or AH-pinned
toolchain versions. Instead, it provides "good enough latest" versions
of the toolchains AH lists in its flake.nix + pixi.toml. When AH's
flake bumps a toolchain in a way that breaks `just test-all` inside the
guest, follow this update procedure:

1. **Diagnose the version drift.** SSH into the guest and capture the
   current versions, then compare against AH's expectations:

   ```
   ssh -p 2228 -i ssh-key/id_ed25519 agent@localhost
   # inside the guest:
   rustc --version
   nim --version
   pixi --version
   just --version
   mutagen version
   ```

   Compare against
   `agent-harbor/main/flake.nix` (inputs.rust-overlay etc.) and
   `agent-harbor/main/pixi.toml` (`[dependencies]` block).

2. **Bump the nixos-modules flake input** in this repository. The
   guest's toolchain pins follow the `nixpkgs-unstable` channel via
   `flake.nix` → `inputs.nixpkgs-unstable` → `pkgs.{rustc, nim2, ...}`.
   Refreshing that input is the canonical way to pick up new
   toolchains:

   ```
   cd /Users/zahary/metacraft/nixos-modules
   nix flake update nixpkgs-unstable
   nix build .#packages.aarch64-linux.nixos-ah-test-guest
   ```

3. **Re-run the M34 verification** against the rebuilt image to confirm
   the new versions still satisfy AH's expectations:

   ```
   tart delete ah-test-guest 2>/dev/null || true
   tart create --from-disk ./result/disk.qcow2 ah-test-guest
   tart run ah-test-guest &
   sleep 30  # boot
   tart ip ah-test-guest        # capture IP
   ssh -i ./result/ssh-key/id_ed25519 agent@<ip> \
     'rustc --version && nim --version && just --version && mutagen version'
   ```

4. **If AH bumps a toolchain to a version not in nixpkgs-unstable yet**
   (rare but possible for nightly Rust, Nim release candidates, Nim 2.x
   patch versions), add an explicit override in `configuration.nix`'s
   `environment.systemPackages` list. Prefer fenix for Rust overrides
   (the package set is already imported in this repo's flake) and a
   fetched-from-source Nim derivation for Nim overrides. Document the
   override in this README under a new "Active overrides" section.

5. **Rebuild and re-run M33** if the toolchain bump materially changes
   the test suite's resource profile (link-time codegen rework, new
   parallel compilation backend, etc.). M33's
   `AH-Test-Resource-Profile.md` includes a `# Methodology` section
   that documents the VM image used; update that section to the new
   build SHA when re-baselining.

## Limitations / known issues

- **(BLOCKING, 2026-06-01)** The current module **cannot yet produce a
  bootable QCOW2 disk image**. The configuration imports
  `installer/cd-dvd/installation-cd-minimal.nix`, which exposes
  `system.build.isoImage` (a bootable installer ISO), not
  `system.build.qcow2` (a self-contained bootable disk). The
  `default.nix` builder reaches for `system.build.qcow2` and so fails
  at build time with an explanatory `runCommand` placeholder. The fix
  is documented inline in `default.nix` and requires one of: (A) add
  `nixos-generators` as a flake input, (B) switch to the
  `${modulesPath}/image/repart.nix` declarative image builder, or
  (C) replace this with an Ubuntu-cloud-image + first-boot-NixOS
  install workflow. Until the fix lands, the M33 measurement pass uses
  the Tart Ubuntu 24.04 ARM fallback (see
  `agent-harbor/main/specs/Public/AH-Test-Resource-Profile.md` §
  "Triage path actually used (2026-06-01)" for the exact recipe).

  Note that the *evaluation* of the module is clean — `nix eval` of
  `makeNixosAhTestGuest {}.drvPath` returns a derivation path; the
  failure only surfaces during the actual build. This keeps the rest
  of the nixos-modules flake evaluatable on macOS.

- The `qemu-system-aarch64` launcher in `default.nix` uses
  `accel=hvf` on macOS hosts. HVF acceleration on macOS works well for
  CPU-bound workloads but has lower throughput on heavy I/O than KVM on
  Linux/aarch64 — expect the M33 disk-I/O peak measurements to be
  _lower_ on macOS hosts than on dedicated Linux runners. Operators
  who need a high-fidelity I/O baseline should rebuild on a
  Linux/aarch64 host (e.g., an Ampere bare-metal VM) and compare.

- The image does **not** ship the AH source tree. The M33 triage
  workflow either `git clone`s AH inside the guest or syncs it via
  `ah-mutagen-sync` (M24) from the host. Baking the source in would
  invalidate the image on every AH commit — not worth it.

- macFUSE on the _host_ is irrelevant to this guest: the guest uses
  Linux `fuse3` inside, so AgentFS FUSE tests work without any
  host-side kext.

## See also

- [Multi-OS-VM-Automation-Campaign.milestones.org](../../../reprobuild-specs/Multi-OS-VM-Automation-Campaign.milestones.org)
  — campaign-level context, M33+M34 deliverables, verification tests.
- [`../ubuntu/`](../ubuntu/) — the Ubuntu cloud-image VM builder whose
  structural pattern this module mirrors.
- `agent-harbor/main/specs/Public/AH-Test-Resource-Profile.md` —
  produced by M33; documents the triage measurements taken inside this
  guest.
