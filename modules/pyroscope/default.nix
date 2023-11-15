{withSystem, ...}: {
  flake.nixosModules.pyroscope = {
    pkgs,
    config,
    lib,
    ...
  }: let
    cfg =
      config.services.pyroscope;
    package = withSystem pkgs.stdenv.hostPlatform.system (
      {config, ...}:
        config.packages.pyroscope
    );
  in {
    options.services.pyroscope = with lib; {
      enable = mkEnableOption (lib.mdDoc "Grafana Agent (Flow mode)");
    };
    config = {
      systemd.services.pyroscope = lib.mkIf cfg.enable {
        description = "Pyroscope";
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          ExecStart = ''${lib.getExe package}'';
        };
      };
    };
  };
}
