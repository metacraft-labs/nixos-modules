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
          type = types.listOf types.str;
          description = "Ethereum hosts for the sequencer";
        };
        l1ConsensusHostUrls = mkOption {
          type = types.listOf types.str;
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
        validatorPrivateKeys = mkOption {
          type = types.path;
          description = "Path to private key of testnet L1 EOA that defines the sequencer identity that holds Sepolia ETH.";
        };
      };
      config = lib.mkIf cfg.enable {
        virtualisation.docker.enable = true;

        systemd.tmpfiles.rules = [
          "d /var/lib/aztec-sequencer 0755 root root -"
        ];
        systemd.services.aztec-sequencer = {
          description = "Aztec Sequencer";
          wantedBy = [ "multi-user.target" ];
          path = [ pkgs.docker ];
          environment = {
            HOME = "/var/lib/aztec-sequencer";
          };
          serviceConfig = {
            WorkingDirectory = "/var/lib/aztec-sequencer";

            ExecStart = pkgs.writeShellScript "aztec-sequencer" ''
              ${lib.getExe package} start --node --archiver --sequencer \
                --network alpha-testnet \
                --l1-rpc-urls ${lib.concatStringsSep "," cfg.ethereumHosts} \
                --l1-consensus-host-urls ${lib.concatStringsSep "," cfg.l1ConsensusHostUrls} \
                --sequencer.validatorPrivateKeys "$(cat ${cfg.validatorPrivateKeys})" \
                --sequencer.coinbase ${cfg.coinbase} \
                --p2p.p2pIp ${cfg.p2pIp} \
                --p2p.p2pPort ${toString cfg.p2pPort}
            '';
          };
        };

      };
    };
}
