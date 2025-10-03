{ withSystem, ... }:
{
  flake.modules.nixos.mcl-host-info =
    {
      config,
      lib,
      ...
    }:
    {
      options.mcl.host-info = with lib; {
        type = mkOption {
          type = types.enum [
            "notebook"
            "desktop"
            "server"
            "container"
          ];
          example = "desktop";
          description = ''
            Whether this host is a desktop or a server.
          '';
        };

        isDebugVM = mkOption {
          type = types.bool;
          example = false;
          description = ''
            Whether this configuration is a VM variant with extra debug functionality.
          '';
        };

        configPath = mkOption {
          type = types.path;
          example = [ "machines/server/solunska-server" ];
          description = ''
            The configuration path for this host relative to the repo root.
          '';
        };

        sshKey = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "ssh-ed25519 AAAAC3Nza";
          description = ''
            The public ssh key for this host.
          '';
        };
      };
    };
}
