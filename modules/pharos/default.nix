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
        "atlantic" = {
          image = "public.ecr.aws/k2g7b7g1/pharos/atlantic";
          tag = "atlantic_community-v0.7.2_102206";
          digest = "sha256:c2f8b08d4fb9778537e118404be2ad1782c1c64a171954ebe3ff2a063c52eccf";
          sha256 = "sha256-1lEoVuyKyHvfn3zZzl9qZHr+Topu6MLbiUv8sg2FGDI=";
        };
        "testnet" = {
          image = "public.ecr.aws/k2g7b7g1/pharos/testnet";
          tag = "pharos_community_v7_0923_01";
          digest = "sha256:6b563cb6a24b349885ed25787b99ba25a9177038b26f58fa2beebdca81d6b58d";
          sha256 = "sha256-Rep13rjLkX+INQ2wE/4UJNc+reBzZWi38C4ZfL9ks5I=";
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
            "atlantic"
            "devnet"
            "mainnet"
          ];
          default = "atlantic";
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
