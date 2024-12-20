{ withSystem, ... }:
{
  flake.nixosModules.grafana-agent-flow =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      cfg = config.services.grafana-agent-flow;
      package = withSystem pkgs.stdenv.hostPlatform.system (
        { config, ... }: config.packages.grafana-agent
      );
    in
    {
      options.services.grafana-agent-flow = with lib; {
        enable = mkEnableOption (lib.mdDoc "Grafana Agent (Flow mode)");
        config-file = mkOption {
          type = types.str;
          default = "./config.river";
          example = "./config.river";
        };
      };
      config = {
        systemd.services.grafana-agent-flow = lib.mkIf cfg.enable {
          description = "Grafana Agent (Flow mode)";

          wantedBy = [ "multi-user.target" ];

          environment = {
            AGENT_MODE = "flow";
          };

          serviceConfig = {
            ExecStart = ''${package}/bin/grafana-agent-flow run ${cfg.config-file}'';
          };
        };
      };
    };
}
