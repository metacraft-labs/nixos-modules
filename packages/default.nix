{ lib, ... }:
{
  perSystem =
    {
      inputs',
      pkgs,
      ...
    }:
    let
      inherit (lib) optionalAttrs versionAtLeast;
      inherit (pkgs.stdenv.hostPlatform) system isLinux;
    in
    rec {
      legacyPackages = {
        inputs = {
          nixpkgs = rec {
            inherit (pkgs) cachix nix-eval-jobs;
            nix = nix-eval-jobs.passthru.nix;
            nix-fast-build = pkgs.nix-fast-build.override { inherit nix-eval-jobs; };
          };
          agenix = inputs'.agenix.packages;
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

        rustToolchain =
          with inputs'.fenix.packages;
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

      packages = {
        lido-withdrawals-automation = pkgs.callPackage ./lido-withdrawals-automation { };
        pyroscope = pkgs.callPackage ./pyroscope { };
        random-alerts = pkgs.callPackage ./random-alerts { };
      }
      // optionalAttrs (system == "x86_64-linux" || system == "aarch64-darwin") {
        secret = import ./secret { inherit inputs' pkgs; };
        aztec = pkgs.callPackage ./aztec { };
      }
      // optionalAttrs isLinux {
        folder-size-metrics = pkgs.callPackage ./folder-size-metrics { };
      }
      // optionalAttrs (system == "x86_64-linux") {
        mcl = pkgs.callPackage ./mcl {
          dCompiler = inputs'.dlang-nix.packages."ldc-binary-1_38_0";
          inherit (legacyPackages.inputs.nixpkgs) cachix nix nix-eval-jobs;
        };
      };
    };
}
