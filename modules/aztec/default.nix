{ withSystem, ... }:
{
  flake.modules.nixos.aztec-sequencer =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      cfg = config.services.aztec-sequencer;
      package = withSystem pkgs.stdenv.hostPlatform.system ({ config, ... }: config.packages.aztec);
    in
    {
      options.services.aztec-sequencer = with lib; {
        enable = mkEnableOption (lib.mdDoc "Aztec Sequencer");
        ethereumHosts = mkOption {
          type = types.str;
          description = "Ethereum hosts for the sequencer";
        };
        l1ConsensusHostUrls = mkOption {
          type = types.str;
          description = "L1 consensus host URLs for the sequencer";
        };
        coinbase = mkOption {
          type = types.str;
          description = "Coinbase for the sequencer";
        };
        p2pIp = mkOption {
          type = types.str;
          description = "P2P IP for the computer running the node (you can get this by running, curl api.ipify.org, on your node)";
        };
        p2pPort = mkOption {
          type = types.port;
          default = 40400;
          description = "The port for the P2P service.";
        };
      };
      config = lib.mkIf cfg.enable {
        mcl.secrets.services.aztec.secrets.validatorPrivateKey = { };

        systemd.services.aztec-sequencer = {
          description = "Aztec Sequencer";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = ''
              ${lib.getExe package} --node --archiver --sequencer \
                --network alpha-testnet \
                --l1-rpc-urls ${lib.concatStringsSep "," cfg.ethereumHosts} \
                --l1-consensus-host-urls ${lib.concatStringsSep "," cfg.l1ConsensusHostUrls} \
                --sequencer.validatorPrivateKey ${config.age.secrets."aztec/validatorPrivateKey"} \
                --sequencer.coinbase ${cfg.coinbase} \
                --p2p.p2pIp ${cfg.p2pIp} \
                --p2p.p2pPort ${cfg.p2pPort}
            '';
          };
        };

      };
    };
}
