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

      reexportedPackages = {
        ethereum_nix =
          {
            # geth = inputs'.ethereum_nix.packages.geth; # TODO: re-enable when flake show/check passes
          }
          // lib.optionalAttrs (pkgs.hostPlatform.isx86 && pkgs.hostPlatform.isLinux) {
            # nimbus = inputs'.ethereum_nix.packages.nimbus-eth2; # TODO: re-enable when flake show/check passes
          };
        # noir = {
        #   nargo = inputs'.noir.packages.nargo;
        #   noirc_abi_wasm = inputs'.noir.packages.noirc_abi_wasm;
        #   acvm_js = inputs'.noir.packages.acvm_js;
        # };
      };

      disabledPackages = [
        #"circ" # has been fixed
        "leap"
        "go-opera"
      ];
    in
    rec {
      checks =
        (builtins.removeAttrs self'.packages disabledPackages)
        // reexportedPackages.ethereum_nix
        // {
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
