{ withSystem, ... }:
{
  flake.modules.nixos.cachix-deploy-metrics =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      inherit (lib)
        types
        mkEnableOption
        mkOption
        mkIf
        concatMapStringsSep
        ;
      cfg = config.services.cachix-deploy-metrics;
      defaultPackage = withSystem pkgs.stdenv.hostPlatform.system (
        { config, ... }: config.packages.cachix-deploy-metrics
      );
    in
    {
      options.services.cachix-deploy-metrics = with lib; {
        enable = mkEnableOption (lib.mdDoc "Cachix Deploy Metrics");

        package = mkOption {
          type = types.package;
          default = defaultPackage;
          description = "Package providing the deploy-metrics binary.";
        };

        scrape-interval = mkOption {
          type = types.int;
          default = 1;
          description = "Scrape interval in seconds.";
        };

        auth-token-path = mkOption {
          type = types.path;
          description = "Cachix auth token path.";
        };

        workspace = mkOption {
          type = types.str;
          description = "Cachix workspace.";
        };

        agent-names = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "List of Cachix deploy agents.";
          example = [
            "machine-01"
            "machine-02"
          ];
        };

        port = mkOption {
          type = types.port;
          default = 9160;
          description = "Port number of Cachix Deployments Exporter service.";
        };
      };

      config = mkIf cfg.enable {
        systemd.services.cachix-deploy-metrics = {
          description = "Prometheus exporter for Cachix Deploy";
          wantedBy = [ "multi-user.target" ];
          path = [ cfg.package ];
          serviceConfig = {
            ExecStart = ''
              ${lib.getExe cfg.package} \
                --port ${toString cfg.port} \
                --scrape-interval ${toString cfg.scrape-interval} \
                --auth-token-path ${cfg.auth-token-path} \
                --workspace ${cfg.workspace} \
                ${
                  if cfg.agent-names == [ ] then
                    ""
                  else
                    concatMapStringsSep " \\\n" (agent: "--agent-names=${agent}") cfg.agent-names
                }
            '';
            Restart = "on-failure";
            RestartSec = 10;
          };
        };
      };
    };
}
