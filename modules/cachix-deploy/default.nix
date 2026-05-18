{
  ...
}:
{
  flake.modules.nixos.mcl-cachix-deploy =
    {
      config,
      lib,
      ...
    }:
    {
      options.mcl.cachix-deploy = with lib; {
        enable = mkEnableOption (mdDoc "Cachix Deploy agent");

        tokenPath = mkOption {
          type = types.path;
          default = "/etc/cachix-agent.token";
          description = mdDoc "Path where the Cachix Deploy agent token is materialized.";
        };
      };

      config = lib.mkIf config.mcl.cachix-deploy.enable {
        mcl.secrets.services.cachix-deploy.secrets.token.path = config.mcl.cachix-deploy.tokenPath;

        services.cachix-agent.enable = lib.mkDefault true;
      };
    };
}
