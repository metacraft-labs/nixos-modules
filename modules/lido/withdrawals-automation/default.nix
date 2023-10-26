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
      };
    };
    config = {
      systemd.services.lido-withdrawals-automation = lib.mkIf cfg.enable {
        description = "Lido Withdrawals Automation";

        wantedBy = ["multi-user.target"];

        environment =
          lib.filterAttrs
          (k: v: (v != "null") && (v != "") && (v != null))
          {
            PERCENTAGE = builtins.toJSON cfg.args.percentage;
            KAPI_URL = cfg.args.kapi-url;
            REMOTE_SIGNER_URL = cfg.args.remote-signer-url;
            KEYMANAGER_URLS = cfg.args.keymanager-urls;
            PASSWORD = cfg.args.password;
            OUTPUT_FOLDER = cfg.args.output-folder;
            OPERATOR_ID = builtins.toJSON cfg.args.operator-id;
            BEACON_NODE_URL = cfg.args.beacon-node-url;
            MODULE_ID = builtins.toJSON cfg.args.module-id;
          };

        path = [package];

        serviceConfig = {
          ExecStart = "${lib.getExe package}";
        };
      };
    };
  };
}
