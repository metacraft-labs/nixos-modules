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
          tag = "pharos_community_v7_0918";
          digest = "sha256:9415d973aeff168d09ce7cb74982c1cf16bd07e1ce902b7a9c9cac46d2307a3b";
          sha256 = "sha256-+UXJvRp4q8ZfH1JnbEgjjAJtZB0r2KWS5Q0ay4bLunk=";
        };
        "devnet" = {
          image = "public.ecr.aws/k2g7b7g1/pharos";
          tag = "latest";
          digest = "sha256:82c7d84fc7d7f17056e947030c4a67bf23a139fe19539a6b237ab42df8215e7b";
          sha256 = "sha256-dZZJKT9mK3D5gzzNcA1WTIBH80N+V0gBHDb5U5SFCdI=";
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
