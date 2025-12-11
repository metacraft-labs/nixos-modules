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

        log-level = mkOption {
          type = types.enum [
            "all"
            "trace"
            "info"
            "warning"
            "error"
            "critical"
            "fatal"
            "off"
          ];
          default = "info";
          description = "Log level";
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

        bind-addresses = mkOption {
          type = types.listOf types.str;
          default = [ "127.0.0.1" ];
          description = "List of addresses to bind to.";
          example = [ "127.0.0.1" "::1" ];
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
                --log-level ${cfg.log-level} \
                --port ${toString cfg.port} \
                --bind-addresses ${builtins.concatStringsSep "," cfg.bind-addresses} \
                --scrape-interval ${toString cfg.scrape-interval} \
                --auth-token-path ${cfg.auth-token-path} \
                --workspace ${cfg.workspace} \
                --agent-names ${builtins.concatStringsSep "," cfg.agent-names}
            '';
            Restart = "on-failure";
            RestartSec = 10;
          };
        };
      };
    };
}
