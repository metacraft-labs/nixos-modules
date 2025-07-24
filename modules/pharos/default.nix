{ ... }:
{
  flake.modules.nixos.pharos =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.pharos;
      # In order to get the hash and digest of the image, use:
      # nix run nixpkgs#nix-prefetch-docker -- --image-name  'public.ecr.aws/k2g7b7g1/pharos' --image-tag latest
      # The url can be found in the pharos documentation
      # https://docs.pharosnetwork.xyz/node-and-validator-guide/validator-node-deployment/using-docker-testnet
      # https://docs.pharosnetwork.xyz/node-and-validator-guide/validator-node-deployment/using-docker-devnet
      images = {
        "testnet" = {
          image = "public.ecr.aws/k2g7b7g1/pharos/testnet";
          tag = "pharos_community_v4_0713";
          digest = "sha256:8f8100f1cb70b58e0737004fdece6e3cc0a32ceb7e9eaac81c7d8f1cac745512";
          sha256 = "sha256-e4zJJIajtzBBYMBWE1NNqdNSv/yNeLa6Vm6O9C6srKA=";
        };
        "devnet" = {
          image = "public.ecr.aws/k2g7b7g1/pharos";
          tag = "latest";
          digest = "sha256:82c7d84fc7d7f17056e947030c4a67bf23a139fe19539a6b237ab42df8215e7b";
          sha256 = "1lh9hna57y9n3h0lhmvy8grlg02caq6p1k9whgwp0av67wllk5km";
        };
      };
    in
    {
      options.services.pharos = with lib; {
        enable = mkEnableOption (lib.mdDoc "Pharos");
        network = mkOption {
          type = types.enum [
            "testnet"
            "devnet"
            "mainnet"
          ];
          default = "testnet";
          description = "Network to connect to";
        };
      };
      config = {
        virtualisation.oci-containers.containers."pharos-${cfg.network}" = {
          image = with images."${cfg.network}"; "${image}:${tag}";

          imageFile =
            with images."${cfg.network}";
            pkgs.dockerTools.pullImage {
              imageName = image;
              imageDigest = digest;
              sha256 = sha256;
              finalImageName = image;
              finalImageTag = tag;
            };
          volumes = [
            "/var/lib/pharos-${cfg.network}:/data"
          ];
          ports = [
            "18100:18100"
            "18200:18200"
            "19000:19000"
          ];
        };
        assertions = [
          {
            assertion = cfg.network != "mainnet";
            message = "Pharos is not available on mainnet yet";
          }
        ];
        systemd.tmpfiles.rules = [
          "d /var/lib/pharos-${cfg.network} 0700 root root - -"
        ];
      };
    };
}
