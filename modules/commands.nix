{ withSystem, ... }:
{
  flake.modules.nixos.mcl-commands =
    {
      lib,
      pkgs,
      flakeArgs,
      config,
      ...
    }:
    let
      cfg = config.programs.admin-cmds;

      makeSystemctlCommand =
        service: command:
        pkgs.writeShellApplication {
          name = "${service}-${command}";
          text = "systemctl ${command} ${service}.service";
        };
      systemctlCommands = builtins.concatMap (
        service: map (command: (makeSystemctlCommand service command)) cfg.systemctl-commands
      ) cfg.services;

      getPackageCommands =
        package:
        lib.pipe "${lib.getExe package}/.." [
          builtins.readDir
          builtins.attrNames
        ];

      server-help = pkgs.writeShellApplication {
        name = "server-help";
        text = ''
          echo -e "There are a few sudo commands which:\n
          * Restart certain services\n
          * Get certain services status\n
          * Get certain services logs\n\n

          Available commands:\n
          ${
            lib.pipe systemctlCommands [
              (map getPackageCommands)
              builtins.concatLists
              (builtins.concatStringsSep "\n")
            ]
          }"
        '';
      };
    in
    {
      options.programs.admin-cmds = with lib; {
        services = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [
            "nginx"
            "grafana"
            "nimbus-eth2"
          ];
          description = ''
            Services for which you have admin commands.
          '';
        };

        systemctl-commands = mkOption {
          type = types.listOf types.str;
          default = [
            "restart"
            "status"
            "stop"
          ];
          example = [
            "restart"
            "start"
            "stop"
          ];
          description = ''
            Systemd commands which you can use for services.
          '';
        };
      };

      config = lib.mkIf (cfg.services != [ ]) {
        security.sudo.extraRules = [
          {
            groups = [ "metacraft" ];
            commands = [
              (lib.pipe systemctlCommands [
                (map getPackageCommands)
                builtins.concatLists
                (lib.concatMapStringsSep ", " (n: "/run/current-system/sw/bin/${n}"))
              ])
            ];
          }
        ];

        environment.systemPackages = systemctlCommands ++ [ server-help ];
      };
    };
}
