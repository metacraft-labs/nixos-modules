{ ... }:
{
  flake.modules.nixos.nix-topology-web =
    {
      config,
      lib,
      ...
    }:
    let
      cfg = config.mcl.nix-topology-web;
    in
    {
      options.mcl.nix-topology-web = with lib; {
        enable = mkEnableOption "nix-topology web interface";
        domain = mkOption {
          type = types.str;
          description = "Domain name for the topology web interface";
        };
        topologyOutput = mkOption {
          type = types.package;
          description = "The nix-topology output derivation to serve";
        };
      };

      config = lib.mkIf cfg.enable {
        services.nginx = {
          enable = true;
          virtualHosts.${cfg.domain} = {
            enableACME = true;
            forceSSL = true;
            locations."/".root = cfg.topologyOutput;
          };
        };

        networking.firewall.allowedTCPPorts = lib.mkBefore [
          80
          443
        ];
      };
    };
}
