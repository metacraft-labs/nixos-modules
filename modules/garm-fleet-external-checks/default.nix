# garm-fleet-external-checks — the GENERAL exporter for the two runner-chain
# checks garm_* cannot see (GitHub App token minting + webhook delivery health).
#
# Company-agnostic: hosts/orgs/creds are all options. The concrete Metacraft
# instantiation (which orgs, which App ids, which agenix key files, and the
# Prometheus scrape wiring) lives in `infra`, per the campaign :repo_layering:.
#
# It runs github-fleet-checks.py on a timer and writes a node-exporter TEXTFILE
# snapshot, so no new scrape target is needed — the existing node-exporter
# textfile collector picks it up. The garm-fleet-alerts library carries the
# alert rules over the emitted metrics.
{ ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      py = pkgs.python3.withPackages (p: [
        p.pyjwt
        p.cryptography
      ]);
    in
    {
      packages.garm-fleet-external-checks = pkgs.runCommand "garm-fleet-external-checks"
        { nativeBuildInputs = [ pkgs.makeWrapper ]; }
        ''
          mkdir -p $out/bin $out/share
          cp ${./github-fleet-checks.py} $out/share/github-fleet-checks.py
          makeWrapper ${py}/bin/python3 $out/bin/garm-fleet-external-checks \
            --add-flags $out/share/github-fleet-checks.py
        '';
    };

  flake.modules.nixos.garm-fleet-external-checks =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.garm-fleet-external-checks;
      inherit (lib)
        mkEnableOption
        mkOption
        mkIf
        types
        mapAttrsToList
        ;

      pkg = mkOption {
        type = types.package;
        default = pkgs.garm-fleet-external-checks or (throw "set services.garm-fleet-external-checks.package");
        description = "The exporter package (github-fleet-checks.py wrapped with PyJWT).";
      };

      appsJson = builtins.toJSON (
        mapAttrsToList (name: a: {
          app = name;
          app_id = a.appId;
          installation_id = a.installationId;
          private_key_file = a.privateKeyFile;
        }) cfg.apps
      );
      webhooksJson = builtins.toJSON (
        map (w: {
          inherit (w) org;
          hook_id = w.hookId;
          token_file = w.tokenFile;
        }) cfg.webhooks
      );
    in
    {
      options.services.garm-fleet-external-checks = {
        enable = mkEnableOption "the GARM fleet external-checks exporter (App token + webhook delivery)";
        package = pkg;

        apiBase = mkOption {
          type = types.str;
          default = "https://api.github.com";
          description = "GitHub API base URL.";
        };

        textfileDir = mkOption {
          type = types.path;
          default = "/var/lib/node-exporter/textfile";
          description = "node-exporter textfile-collector directory to write the .prom snapshot into.";
        };

        interval = mkOption {
          type = types.str;
          default = "5m";
          description = "systemd OnUnitActiveSec interval between check cycles.";
        };

        apps = mkOption {
          default = { };
          description = "GitHub Apps whose installation-token minting is checked (keyed by a display name used as the `app` label).";
          type = types.attrsOf (
            types.submodule {
              options = {
                appId = mkOption {
                  type = types.either types.int types.str;
                  description = "GitHub App id.";
                };
                installationId = mkOption {
                  type = types.either types.int types.str;
                  description = "Installation id to mint a token for.";
                };
                privateKeyFile = mkOption {
                  type = types.str;
                  description = "Path to the App private key (PEM); stage via agenix.";
                };
              };
            }
          );
        };

        webhooks = mkOption {
          default = [ ];
          description = "Org webhooks whose GitHub delivery ledger is checked (POST-PHASE-C).";
          type = types.listOf (
            types.submodule {
              options = {
                org = mkOption {
                  type = types.str;
                  description = "GitHub org login.";
                };
                hookId = mkOption {
                  type = types.either types.int types.str;
                  description = "The org webhook (hook) id.";
                };
                tokenFile = mkOption {
                  type = types.str;
                  description = "Path to a token with admin:org_hook read (or an App token file); stage via agenix.";
                };
              };
            }
          );
        };
      };

      config = mkIf cfg.enable {
        systemd.services.garm-fleet-external-checks = {
          description = "GARM fleet external checks (GitHub App token + webhook delivery)";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${cfg.package}/bin/garm-fleet-external-checks";
            # Hardened: only needs to read the (agenix) key files and write the
            # textfile dir.
            DynamicUser = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            NoNewPrivileges = true;
            ReadWritePaths = [ cfg.textfileDir ];
            Environment = [
              "GFC_OUTPUT=${cfg.textfileDir}/garm-fleet-external-checks.prom"
              "GFC_API=${cfg.apiBase}"
              "GFC_APPS_JSON=${appsJson}"
              "GFC_WEBHOOKS_JSON=${webhooksJson}"
            ];
          };
        };

        systemd.timers.garm-fleet-external-checks = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "2m";
            OnUnitActiveSec = cfg.interval;
          };
        };
      };
    };
}
