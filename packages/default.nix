{lib, ...}: {
  perSystem = {
    inputs',
    pkgs,
    ...
  }: let
    inherit (lib) optionalAttrs;
    inherit (pkgs) system;
    inherit (pkgs.hostPlatform) isLinux;
  in rec {
    legacyPackages = {
      inputs = {
        agenix = inputs'.agenix.packages;
        cachix = inputs'.cachix.packages;
        devenv = inputs'.devenv.packages;
        disko = inputs'.disko.packages;
        dlang-nix = inputs'.dlang-nix.packages;
        ethereum-nix = inputs'.ethereum-nix.packages;
        fenix = inputs'.fenix.packages;
        git-hooks-nix = inputs'.git-hooks-nix.packages;
        microvm = inputs'.microvm.packages;
        nix-fast-build = inputs'.nix-fast-build.packages;
        nixos-anywhere = inputs'.nixos-anywhere.packages;
        terranix = inputs'.terranix.packages;
        treefmt-nix = inputs'.treefmt-nix.packages;
      };

      rustToolchain = with inputs'.fenix.packages;
      with latest;
        combine [
          cargo
          clippy
          rust-analyzer
          rust-src
          rustc
          rustfmt
          targets.wasm32-wasi.latest.rust-std
        ];
    };

    packages =
      {
        lido-withdrawals-automation = pkgs.callPackage ./lido-withdrawals-automation {};
        pyroscope = pkgs.callPackage ./pyroscope {};

        inherit (legacyPackages) rustToolchain;
        inherit (legacyPackages.inputs.ethereum-nix) geth;
        inherit (legacyPackages.inputs.dlang-nix) dub;
        inherit (inputs'.nix-fast-build.packages) nix-fast-build;
      }
      // optionalAttrs (system == "x86_64-linux" || system == "aarch64-darwin") {
        grafana-agent = import ./grafana-agent {inherit inputs';};
      }
      // optionalAttrs isLinux {
        inherit (inputs'.validator-ejector.packages) validator-ejector;
        folder-size-metrics = pkgs.callPackage ./folder-size-metrics {};
      }
      // optionalAttrs (system == "x86_64-linux") {
        mcl = pkgs.callPackage ./mcl {
          buildDubPackage = inputs'.dlang-nix.legacyPackages.buildDubPackage.override {
            ldc = inputs'.dlang-nix.packages."ldc-binary-1_34_0";
          };
        };

        inherit (pkgs) terraform;
        inherit (legacyPackages.inputs.terranix) terranix;
        inherit (legacyPackages.inputs.dlang-nix) dcd dscanner serve-d dmd ldc;
        inherit (legacyPackages.inputs.ethereum-nix) mev-boost nethermind web3signer foundry nimbus-eth2;
      };
    checks = packages;
  };
}
