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
  #   (2) `virtualisation.incus.preseed` for the managed `incusbr0` bridge on the
  #       per-host /24 (high-mem-server 10.157.159.0/24, gpu-server-001
  #       10.158.160.0/24). nixpkgs' incus module already ships an idempotent
  #       `incus-preseed.service` (ordered After=incus.service) that applies the
  #       preseed; the preseed CREATES/UPDATES the network but never REMOVES
  #       entities, so it is safe to re-apply on every switch and coexists with
  #       the host's other incus containers/networks. Replaces the manual
  #       `incus admin init` / `incus network create incusbr0 …`.
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
            Whether to declare the `incusbr0` network via
            `virtualisation.incus.preseed`. Default true. Set false on a host
            whose incusbr0 is provisioned some other way (the image-import
            oneshot then still applies).
          '';
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
          # (2) The managed incusbr0 bridge, declared via incus.preseed. nixpkgs'
          # incus module renders an idempotent incus-preseed.service that
          # CREATES/UPDATES (never removes) this network after incus.service.
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
          };

          # (3) The runner-image import oneshot — idempotent, ordered after the
          # incus daemon (and after the preseed so the bridge exists). RemainAfter
          # so a re-switch re-checks; the check-then-import keeps it a no-op when
          # the image is already present.
          systemd.services.garm-incus-image-import = mkIf cfg.image.enable {
            description = "Import the GARM incus runner image if absent";
            after = [
              "incus.service"
              "incus-preseed.service"
            ];
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
