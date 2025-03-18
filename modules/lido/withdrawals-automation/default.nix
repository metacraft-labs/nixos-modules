{ withSystem, ... }:
{
  flake.modules.nixos.lido-withdrawals-automation =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      cfg = config.services.lido-withdrawals-automation;
      package = withSystem pkgs.stdenv.hostPlatform.system (
        { config, ... }: config.packages.lido-withdrawals-automation
      );
      inherit (import ../../lib.nix { inherit lib; }) toEnvVariables;
    in
    {
      options.services.lido-withdrawals-automation = with lib; {
        enable = mkEnableOption (lib.mdDoc "Lido Withdrawals Automation");
        timerFrequency = mkOption {
          type = types.str;
          default = "daily";
          example = "hourly";
        };
        args = {
          percentage = mkOption {
            type = types.nullOr types.int;
            default = null;
            example = 10;
          };
          kapi-url = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "https://example.com/kapi";
          };
          remote-signer-url = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "https://remotesigner.local:8080";
          };
          keymanager-urls = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "https://example.com/, https://example2.com/";
          };
          password = mkOption {
            type = types.str;
            example = "mysecretpassword";
          };
          output-folder = mkOption {
            type = types.str;
            example = "/path/to/your/output-folder";
          };
          operator-id = mkOption {
            type = types.int;
            example = 123;
          };
          beacon-node-url = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "http://localhost:5052";
          };
          module-id = mkOption {
            type = types.nullOr types.int;
            default = null;
            example = 1;
          };
          keymanager-token-file = mkOption {
            type = types.nullOr types.path;
            default = null;
            example = ./token;
          };
          overwrite = mkOption {
            type = types.nullOr (
              types.enum [
                "always"
                "never"
                "prompt"
              ]
            );
            default = null;
            example = "always";
          };
        };
      };
      config = lib.mkIf cfg.enable {

        systemd.timers.lido-withdrawals-automation = {
          wantedBy = [ "timers.target" ];
          partOf = [ "lido-withdrawals-automation.service" ];
          timerConfig = {
            OnCalendar = cfg.timerFrequency;
            Unit = "lido-withdrawals-automation.service";
          };
        };

        systemd.services.lido-withdrawals-automation = {
          description = "Lido Withdrawals Automation";

          environment = toEnvVariables cfg.args;

          path = [ package ];

          serviceConfig = lib.mkMerge [
            {
              Type = "oneshot";
              Group = "lido";
              ExecStart = lib.getExe (
                pkgs.writeShellApplication {
                  name = "repl";
                  text = ''
                    ${lib.getExe package}
                  '';
                }
              );
            }
          ];
        };
      };
    };
}
