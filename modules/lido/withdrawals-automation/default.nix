{withSystem, ...}: {
  flake.nixosModules.lido-withdrawals-automation = {
    pkgs,
    config,
    lib,
    ...
  }: let
    cfg = config.services.lido-withdrawals-automation;
    package = withSystem pkgs.stdenv.hostPlatform.system (
      {config, ...}:
        config.packages.lido-withdrawals-automation
    );
    inherit (import ../../lib.nix {inherit lib;}) toEnvVariables;
  in {
    options.services.lido-withdrawals-automation = with lib; {
      enable = mkEnableOption (lib.mdDoc "Lido Withdrawals Automation");
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
          type = types.nullOr (types.enum ["always" "never" "prompt"]);
          default = null;
          example = "always";
        };
      };
    };
    config = {
      systemd.services.lido-withdrawals-automation = lib.mkIf cfg.enable {
        description = "Lido Withdrawals Automation";

        wantedBy = ["multi-user.target"];

        environment = toEnvVariables cfg.args;

        path = [package];

        serviceConfig = lib.mkMerge [
          {
            Group = "lido";
            ExecStartPre = pkgs.writeShellScript "healthcheck.sh" ''
              #!/usr/bin/env bash
              set -euo pipefail

              while true; do
              if ${lib.getExe pkgs.curl} -sSf ${cfg.args.kapi-url} > /dev/null; then
                  echo "${cfg.args.kapi-url} is online"
                  break
              else
                  echo "${cfg.args.kapi-url} is offline, waiting..."
                  sleep 5  # Adjust the sleep duration as needed
              fi
              done
            '';
            ExecStart = lib.getExe (pkgs.writeShellApplication {
              name = "repl";
              text = ''
                export KEYMANAGER_TOKEN_FILE=$CREDENTIALS_DIRECTORY/keymanager-token-file
                ${lib.getExe package}
              '';
            });
          }
          (lib.mkIf (cfg.args.keymanager-token-file != null) {
            LoadCredential = ["keymanager-token-file:${cfg.args.keymanager-token-file}"];
          })
        ];
      };
    };
  };
}
