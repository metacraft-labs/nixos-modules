{
  config,
  lib,
  dirs,
  ...
}: {
  options.mcl.host-info = with lib; {
    type = mkOption {
      type = types.nullOr (types.enum ["desktop" "server"]);
      default = null;
      example = ["desktop"];
      description = ''
        Whether this host is a desktop or a server.
      '';
    };

    isVM = mkOption {
      type = types.nullOr types.bool;
      default = null;
      example = ["false"];
      description = ''
        Whether this configuration is a VM variant.
      '';
    };

    configPath = mkOption {
      type = types.nullOr types.string;
      default = null;
      example = ["machines/server/solunska-server"];
      description = ''
        The configuration path for this host relative to the repo root.
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
        assertion = config.mcl.host-info.isVM != null;
        message = "mcl.host-info.isVM must be defined for every host";
      }
      {
        assertion = config.mcl.host-info.configPath != null;
        message = "mcl.host-info.configPath must be defined for every host";
      }
    ];
  };
}
