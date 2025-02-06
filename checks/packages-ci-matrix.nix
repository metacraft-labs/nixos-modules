{
  lib,
  inputs,
  ...
}:
{
  perSystem =
    {
      inputs',
      self',
      pkgs,
      ...
    }:
    let
      inherit (lib) optionalAttrs;
      inherit (pkgs) system;
      inherit (pkgs.hostPlatform) isLinux;
    in
    rec {
      checks =
        self'.packages
        // {
          inherit (self'.legacyPackages) rustToolchain;
          inherit (self'.legacyPackages.inputs.dlang-nix) dub;
          inherit (self'.legacyPackages.inputs.nixpkgs)
            cachix
            nix
            nix-eval-jobs
            nix-fast-build
            ;
          inherit (self'.legacyPackages.inputs.ethereum-nix) foundry;
        }
        // optionalAttrs (system == "x86_64-linux" || system == "aarch64-darwin") {
          inherit (self'.legacyPackages.inputs.ethereum-nix) geth;
        }
        // optionalAttrs isLinux {
          inherit (inputs'.validator-ejector.packages) validator-ejector;
        }
        // optionalAttrs (system == "x86_64-linux") {
          inherit (pkgs) terraform;
          inherit (self'.legacyPackages.inputs.terranix) terranix;
          inherit (self'.legacyPackages.inputs.dlang-nix)
            dcd
            dscanner
            serve-d
            dmd
            ldc
            ;
          inherit (self'.legacyPackages.inputs.ethereum-nix)
            mev-boost
            nethermind
            web3signer
            nimbus
            ;
        };
    };
}
