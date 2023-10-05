{
  config,
  pkgs,
  lib,
  self,
  flakeArgs,
  ...
}: let
  baseNixOS = flakeArgs.lib.nixosSystem {
    modules = [
      {
        nixpkgs.hostPlatform = pkgs.system;
        networking.networkmanager.enable = true;
      }
    ];
  };

  baseModules = builtins.attrNames baseNixOS.config.systemd.services;

  currentModules = builtins.attrNames config.systemd.services;

  interestingModules = lib.lists.subtractLists baseModules currentModules;

  systemctlQuery = builtins.concatStringsSep " " (builtins.map (s: "${s}.service") interestingModules);
in {
  systemd.services.motdScript = {
    wantedBy = ["multi-user.target"];
    serviceConfig.Type = "oneshot";
    path = [
      pkgs.systemd
      pkgs.sudo
      pkgs.boxes
      pkgs.procps
      pkgs.coreutils
      pkgs.gnused
    ];
    script = ''
      {
        systemctl --type=service --all list-units ${systemctlQuery} | sed -n '/LOAD   = Reflects whether the unit definition was properly loaded./q;p' | boxes -d stone
        sudo df -h | boxes -d stone
        free -h | boxes -d stone
        date
      } > /run/motd
    '';
  };
  systemd.timers.motdScript = {
    wantedBy = ["timers.target"];
    partOf = ["motdScript.service"];
    timerConfig = {
      OnCalendar = "*-*-* *:*:00,30";
      Unit = "motdScript.service";
    };
  };
}
