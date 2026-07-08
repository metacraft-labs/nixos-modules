{ ... }:
{
  # Declarative GARM Reconcile — deliverables (2) + (3): make the incus
  # bridge + the runner image declarative, so the "run `incus admin init` once"
  # and "`incus image import` once" operator steps disappear from EXP2/EXP4.
  #
  # This is a small REUSABLE host helper the per-host garm-runner configs turn
  # on (setting their per-host subnet). It has NO opinion about GARM itself —
  # `services.garm` still owns the control plane. It only provisions the two
  # host-level prerequisites GARM's incus provider consumes:
  #
  #   (2) `virtualisation.incus.preseed` for the FULL host triple a fresh GARM
  #       host needs — the managed `incusbr0` bridge on the per-host /24
  #       (high-mem-server 10.157.159.0/24, gpu-server-001 10.158.160.0/24), a
  #       `dir` storage pool, and the `default` profile's root+eth0 devices.
  #       nixpkgs' incus module ships an idempotent `incus-preseed.service`
  #       (ordered After=incus.service) that applies the preseed; the preseed
  #       CREATES/UPDATES entities but never REMOVES them, so it is safe to
  #       re-apply on every switch and coexists with the host's other incus
  #       containers/networks. Replaces the manual `incus admin init` /
  #       `incus network create incusbr0 …`.
  #
  #       CAVEAT (why (2b) exists): nixpkgs' `incus-preseed.service` only runs
  #       `incus admin init --preseed` while incus is UNINITIALISED (it guards on
  #       a first-run marker) and only on an incus.service (re)start. A host whose
  #       incus daemon self-initialised EMPTY before this config landed (as
  #       gpu-server-001 did) therefore gets NOTHING from the preseed — no pool,
  #       no bridge, no profile devices. So the preseed alone cannot guarantee a
  #       converged host.
  #
  #   (2b) an IDEMPOTENT `garm-incus-storage-network.service` convergence oneshot
  #        that, on EVERY switch, create-if-missing reconciles the same triple
  #        directly via the incus CLI (storage pool, bridge network, default
  #        profile root+eth0 devices). Each step is guarded (`incus … show ||
  #        incus … create`) so it is a NO-OP on a converged host and NEVER mutates
  #        an existing pool's immutable fields. This SUPERSEDES relying on the
  #        preseed's uninitialised-only / restart-coupled semantics, so a fresh
  #        GPU host converges on first `nixos-rebuild switch` with zero hand
  #        steps. Runs only when `managePreseed` is true (the host we manage);
  #        adopted hosts (managePreseed = false) stay byte-unchanged.
  #
  #   (3) an idempotent `garm-incus-image-import.service` oneshot that imports
  #       the runner image (default alias `vmh-linux-runner`) if — and ONLY if —
  #       it is absent from the host's incus image store, from a nix-built or
  #       operator-provided tarball. Replaces the manual `incus image import` /
  #       `incus image alias create`. A re-run with the image already present is
  #       a no-op (the oneshot checks `incus image alias list` first).
  flake.modules.nixos.garm-incus-runner-host =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.garm-incus-runner-host;
      inherit (lib)
        mkEnableOption
        mkIf
        mkOption
        types
        ;
      incusPkg = config.virtualisation.incus.package;
      incusBin = "${incusPkg}/bin/incus";
    in
    {
      options.services.garm-incus-runner-host = {
        enable = mkEnableOption ''
          the declarative incus host prerequisites for GARM incus runners: the
          managed `incusbr0` bridge (via incus.preseed) and the runner-image
          import oneshot
        '';

        bridgeName = mkOption {
          type = types.str;
          default = "incusbr0";
          description = ''
            The managed incus bridge name. Must match
            `services.garm.providers.<name>.incusBridge`.
          '';
        };

        bridgeSubnet = mkOption {
          type = types.str;
          example = "10.157.159.0/24";
          description = ''
            The per-host incusbr0 subnet, `a.b.c.0/nn`. The bridge host IP (the
            `.1` gateway the per-job containers reach GARM on) is derived by
            replacing the host octet with `1`. Distinct per host so two hosts on
            a shared netbird L2 never collide (high-mem-server 10.157.159.0/24,
            gpu-server-001 10.158.160.0/24).
          '';
        };

        bridgeGateway = mkOption {
          type = types.str;
          default = "";
          example = "10.157.159.1";
          description = ''
            The bridge host IP / gateway in `a.b.c.d/nn`-less dotted form. Empty
            (default) ⇒ derived from `bridgeSubnet` by setting the host octet to
            `1`. Emitted as `ipv4.address = <gateway>/<prefix>` in the preseed.
          '';
        };

        nat = mkOption {
          type = types.bool;
          default = true;
          description = "Enable ipv4.nat on the managed bridge (container egress).";
        };

        managePreseed = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether to declare the full incus host triple (bridge network,
            storage pool, default profile devices) via
            `virtualisation.incus.preseed` AND run the idempotent
            `garm-incus-storage-network` convergence oneshot that reconciles the
            same triple on every switch (belt-and-suspenders for an incus that
            self-initialised before this config landed). Default true. Set false
            on a host whose incus is provisioned some other way / adopted (the
            image-import oneshot then still applies, but the preseed + the
            storage-network convergence oneshot are BOTH inert, so the host is
            byte-unchanged).
          '';
        };

        storagePool = {
          name = mkOption {
            type = types.str;
            default = "default";
            description = ''
              The incus storage pool the `default` profile's root disk uses.
              Declared in the preseed and reconciled by the convergence oneshot
              (create-if-missing; never mutated once present).
            '';
          };

          driver = mkOption {
            type = types.str;
            default = "dir";
            description = ''
              The storage pool driver. `dir` (the default) matches
              high-mem-server and needs no extra host setup (a plain directory
              pool under /var/lib/incus).
            '';
          };
        };

        image = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Whether to run the runner-image import oneshot.";
          };

          alias = mkOption {
            type = types.str;
            default = "vmh-linux-runner";
            description = ''
              The incus image alias GARM's provider references
              (`services.garm.providers.<name>.images.<k>.sourceImage`). The
              oneshot imports the tarball under this alias iff it is absent.
            '';
          };

          source = mkOption {
            type = types.nullOr types.path;
            default = null;
            example = "/var/lib/garm/images/vmh-linux-runner.tar.gz";
            description = ''
              Path to a unified incus image tarball (`incus image export`
              format) imported under `alias` when the alias is absent. Null
              (default) ⇒ the oneshot is a NO-OP unless the image already
              exists (it never fails a host that has no source AND no image —
              it just logs that the operator must seed the image). A nix-built
              image derivation can be pointed at here.
            '';
          };
        };
      };

      config = mkIf cfg.enable (
        let
          # subnet a.b.c.0/nn -> prefix + derived gateway a.b.c.1
          parts = lib.splitString "/" cfg.bridgeSubnet;
          netAddr = builtins.elemAt parts 0;
          prefix = builtins.elemAt parts 1;
          octets = lib.splitString "." netAddr;
          derivedGateway = lib.concatStringsSep "." ((lib.sublist 0 3 octets) ++ [ "1" ]);
          gateway = if cfg.bridgeGateway != "" then cfg.bridgeGateway else derivedGateway;

          # (2b) The idempotent storage+network+profile convergence oneshot.
          # Every step is create-if-missing so it is a no-op on a converged host
          # and never mutates an existing pool's immutable fields. `</dev/null`
          # on every incus call keeps the CLI from consuming the script's stdin.
          convergeScript = pkgs.writeShellApplication {
            name = "garm-incus-storage-network";
            runtimeInputs = [
              incusPkg
              pkgs.coreutils
              pkgs.gnugrep
            ];
            text = ''
              set -euo pipefail
              pool="${cfg.storagePool.name}"
              driver="${cfg.storagePool.driver}"
              bridge="${cfg.bridgeName}"
              addr="${gateway}/${prefix}"
              nat="${lib.boolToString cfg.nat}"

              # Storage pool (immutable-safe: only create if absent).
              if ${incusBin} storage show "$pool" </dev/null >/dev/null 2>&1; then
                echo "garm-incus-storage-network: storage pool '$pool' present — no-op"
              else
                echo "garm-incus-storage-network: creating storage pool '$pool' ($driver)"
                ${incusBin} storage create "$pool" "$driver" </dev/null
              fi

              # Managed bridge (only create if absent — never re-set an existing
              # bridge's immutable ipv4.address).
              if ${incusBin} network show "$bridge" </dev/null >/dev/null 2>&1; then
                echo "garm-incus-storage-network: network '$bridge' present — no-op"
              else
                echo "garm-incus-storage-network: creating network '$bridge' ($addr, nat=$nat)"
                ${incusBin} network create "$bridge" \
                  "ipv4.address=$addr" "ipv4.nat=$nat" "ipv6.address=none" </dev/null
              fi

              # default profile root disk (create if the device is absent).
              if ${incusBin} profile device list default </dev/null 2>/dev/null | grep -qxF root; then
                echo "garm-incus-storage-network: profile default root present — no-op"
              else
                echo "garm-incus-storage-network: adding profile default root (pool=$pool)"
                ${incusBin} profile device add default root disk \
                  "pool=$pool" path=/ </dev/null
              fi

              # default profile eth0 nic on the managed bridge.
              if ${incusBin} profile device list default </dev/null 2>/dev/null | grep -qxF eth0; then
                echo "garm-incus-storage-network: profile default eth0 present — no-op"
              else
                echo "garm-incus-storage-network: adding profile default eth0 (network=$bridge)"
                ${incusBin} profile device add default eth0 nic \
                  "network=$bridge" name=eth0 </dev/null
              fi

              echo "garm-incus-storage-network: converged"
            '';
          };

          importScript = pkgs.writeShellApplication {
            name = "garm-incus-image-import";
            runtimeInputs = [
              incusPkg
              pkgs.coreutils
            ];
            text = ''
              set -euo pipefail
              alias="${cfg.image.alias}"
              src="${if cfg.image.source == null then "" else toString cfg.image.source}"

              # Idempotent: if the alias already resolves to an image, do nothing.
              if ${incusBin} image alias list --format csv 2>/dev/null \
                  | cut -d, -f1 | grep -qxF "$alias"; then
                echo "garm-incus-image-import: alias '$alias' already present — no-op"
                exit 0
              fi

              if [ -z "$src" ]; then
                echo "garm-incus-image-import: alias '$alias' absent and no source configured — operator must seed the image (services.garm-incus-runner-host.image.source)" >&2
                exit 0
              fi
              if [ ! -e "$src" ]; then
                echo "garm-incus-image-import: source '$src' does not exist" >&2
                exit 1
              fi

              echo "garm-incus-image-import: importing '$src' as alias '$alias'"
              ${incusBin} image import "$src" --alias "$alias" --reuse
              echo "garm-incus-image-import: done"
            '';
          };
        in
        {
          # (2) The full host triple — managed incusbr0 bridge + a `dir` storage
          # pool + the `default` profile's root/eth0 devices — declared via
          # incus.preseed. nixpkgs' incus module renders an idempotent
          # incus-preseed.service that CREATES/UPDATES (never removes) these
          # after incus.service, on a FRESH (uninitialised) incus. For a host
          # whose incus already self-initialised, (2b) below converges the same
          # triple imperatively.
          virtualisation.incus.preseed = mkIf cfg.managePreseed {
            networks = [
              {
                name = cfg.bridgeName;
                type = "bridge";
                config = {
                  "ipv4.address" = "${gateway}/${prefix}";
                  "ipv4.nat" = lib.boolToString cfg.nat;
                  "ipv6.address" = "none";
                };
              }
            ];
            storage_pools = [
              {
                name = cfg.storagePool.name;
                driver = cfg.storagePool.driver;
              }
            ];
            profiles = [
              {
                name = "default";
                devices = {
                  root = {
                    type = "disk";
                    path = "/";
                    pool = cfg.storagePool.name;
                  };
                  eth0 = {
                    type = "nic";
                    network = cfg.bridgeName;
                    name = "eth0";
                  };
                };
              }
            ];
          };

          # (2b) The convergence oneshot — idempotent create-if-missing of the
          # storage pool + bridge + default profile devices, ordered after the
          # incus daemon. RemainAfter so a re-switch re-checks; each guarded step
          # keeps it a no-op on a converged host. This is what lets a fresh GPU
          # host (whose incus self-initialised empty before this config landed)
          # come up with zero hand steps. Gated on managePreseed so adopted hosts
          # (managePreseed = false) stay byte-unchanged.
          systemd.services.garm-incus-storage-network = mkIf cfg.managePreseed {
            description = "Converge the GARM incus storage pool, bridge, and default profile devices";
            after = [
              "incus.service"
              "incus-preseed.service"
            ];
            requires = [ "incus.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = lib.getExe convergeScript;
            };
          };

          # (3) The runner-image import oneshot — idempotent, ordered after the
          # incus daemon (and after the preseed so the bridge exists). RemainAfter
          # so a re-switch re-checks; the check-then-import keeps it a no-op when
          # the image is already present.
          systemd.services.garm-incus-image-import = mkIf cfg.image.enable {
            description = "Import the GARM incus runner image if absent";
            # Order after the storage-network convergence oneshot only when it
            # exists (managePreseed); this keeps the image-import unit
            # byte-identical on adopted hosts (managePreseed = false).
            after = [
              "incus.service"
              "incus-preseed.service"
            ]
            ++ lib.optional cfg.managePreseed "garm-incus-storage-network.service";
            requires = [ "incus.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = lib.getExe importScript;
            };
          };
        }
      );
    };
}
