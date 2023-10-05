{
  config,
  lib,
  dirs,
  ...
}: let
  enabled = config.mcl.sleep.enable;
in {
  options.mcl.sleep = with lib; {
    enable = mkEnableOption (mdDoc "Enable automatic sleep");
  };

  config = {
    services.xserver.displayManager.gdm.autoSuspend = enabled;
    systemd.targets.sleep.enable = enabled;
    systemd.targets.suspend.enable = enabled;
    systemd.targets.hibernate.enable = enabled;
    systemd.targets.hybrid-sleep.enable = enabled;
  };
}
