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
          type = types.nullOr (
            types.enum [
              "desktop"
              "server"
              "container"
            ]
          );
          default = null;
          example = [ "desktop" ];
          description = ''
            Whether this host is a desktop or a server.
          '';
        };

        isDebugVM = mkOption {
          type = types.nullOr types.bool;
          default = null;
          example = [ "false" ];
          description = ''
            Whether this configuration is a VM variant with extra debug
            functionality.
          '';
        };

        configPath = mkOption {
          type = types.nullOr types.path;
          default = null;
          example = [ "machines/server/solunska-server" ];
          description = ''
            The configuration path for this host relative to the repo root.
          '';
        };

        sshKey = mkOption {
          type = types.nullOr types.str;
          default = "";
          example = "ssh-ed25519 AAAAC3Nza";
          description = ''
            The public ssh key for this host.
          '';
        };
      };
      config = {
        assertions = [
          {
            assertion = config.mcl.host-info.type != null;
            message = "mcl.host-info.type must be defined for every host";
          }
          {
            assertion = config.mcl.host-info.isDebugVM != null;
            message = "mcl.host-info.isDebugVM must be defined for every host";
          }
          {
            assertion = config.mcl.host-info.configPath != null;
            message = "mcl.host-info.configPath must be defined for every host";
          }
        ];
      };
    };
}
