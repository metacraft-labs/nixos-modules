{ withSystem, ... }:
{
  flake.modules.nixos.tacchain =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      cfg = config.services.tacchain;
      package = withSystem pkgs.stdenv.hostPlatform.system ({ config, ... }: config.packages.tacchain);
      persistent_peers = "9c32b3b959a2427bd2aa064f8c9a8efebdad4c23@206.217.210.164:45130,04a2152eed9f73dc44779387a870ea6480c41fe7@206.217.210.164:45140,5aaaf8140262d7416ac53abe4e0bd13b0f582168@23.92.177.41:45110,ddb3e8b8f4d051e914686302dafc2a73adf9b0d2@23.92.177.41:45120";
      genesis = pkgs.fetchurl {
        url = "https://raw.githubusercontent.com/TacBuild/tacchain/refs/heads/main/networks/tacchain_2391-1/genesis.json";
        hash = "sha256-ZGz5KtMX1Xx70/h7+VRAPtuPD+Xs5Y01Lv5d/bZF91c=";
      };
    in
    {
      options.services.tacchain = with lib; {
        enable = mkEnableOption (lib.mdDoc "Tacchain");
        nodeName = mkOption {
          type = types.str;
          default = "tacchain";
          description = "The name of the tacchain node.";
        };
        home = mkOption {
          type = types.path;
          default = "/var/lib/tacchain";
          description = "The home directory for the tacchain node.";
        };
      };
      config = lib.mkIf cfg.enable {
        mcl.secrets.services.tacchain.secrets = {
          validator-private-key = { };
        };
        systemd.tmpfiles.rules = [
          "d ${cfg.home} 0755 root root - - -"
        ];
        systemd.services.tacchain_setup = {
          description = "tacchain_setup";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            Environment = "HOME=${cfg.home}";
            ConditionPathExists = "!${cfg.home}/config/genesis.json";
            ExecStart = [
              ''${lib.getExe package} init ${cfg.nodeName} --chain-id tacchain_2391-1 --home ${cfg.home}''
              ''${pkgs.gnused}/bin/sed -i 's/timeout_commit = "5s"/timeout_commit = "2s"/' ${cfg.home}/config/config.toml''
              ''${pkgs.gnused}/bin/sed -i 's/persistent_peers = ".*"/persistent_peers = "${persistent_peers}"/' ${cfg.home}/config/config.toml''
              ''${pkgs.coreutils}/bin/cp ${genesis} ${cfg.home}/config/genesis.json''
              ''${lib.getExe package} keys import validator ${
                config.age.secrets."tacchain/validator-private-key".path
              } --home ${cfg.home} --keyring-backend test''
            ];

          };
        };
        systemd.services.tacchain = {
          description = "tacchain";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Environment = "HOME=${cfg.home}";
            After = "tacchain_setup.service";
            ExecStart = ''${lib.getExe package} start --chain-id tacchain_2391-1 --home ${cfg.home}'';
          };
        };
      };
    };
}
