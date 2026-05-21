{ inputs, ... }:
{
  flake.modules.nixos."tailscale-with-agenix" =
    {
      config,
      lib,
      ...
    }:
    let
      cfg = config.services."tailscale-with-agenix";
    in
    {
      imports = [
        inputs.agenix.nixosModules.default
      ];

      options.services."tailscale-with-agenix" = with lib; {
        enable = mkEnableOption (mdDoc "Tailscale configured with an agenix-managed auth key");

        authKeySecretFile = mkOption {
          type = types.path;
          description = mdDoc "Encrypted age file containing the Tailscale auth key.";
        };

        authKeySecretName = mkOption {
          type = types.str;
          default = "tailscale/auth-key";
          description = mdDoc "Name of the agenix secret that materializes the Tailscale auth key.";
        };

        extraSetFlags = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = mdDoc "Extra flags passed to services.tailscale.extraSetFlags.";
        };
      };

      config = lib.mkIf cfg.enable {
        age.secrets.${cfg.authKeySecretName}.file = cfg.authKeySecretFile;

        services.tailscale = {
          enable = true;
          authKeyFile = config.age.secrets.${cfg.authKeySecretName}.path;
          extraSetFlags = cfg.extraSetFlags;
        };
      };
    };
}
