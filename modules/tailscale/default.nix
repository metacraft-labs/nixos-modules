{
  ...
}:
{
  flake.modules.nixos.mcl-tailscale =
    {
      config,
      lib,
      ...
    }:
    {
      options.mcl.tailscale = with lib; {
        enable = mkEnableOption (mdDoc "Tailscale with an agenix-managed auth key");

        extraSetFlags = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = mdDoc "Extra flags passed to services.tailscale.extraSetFlags.";
        };
      };

      config = lib.mkIf config.mcl.tailscale.enable {
        mcl.secrets.services.tailscale.secrets.auth-key = { };

        services.tailscale = {
          enable = true;
          authKeyFile = config.age.secrets."tailscale/auth-key".path;
          extraSetFlags = config.mcl.tailscale.extraSetFlags;
        };
      };
    };
}
