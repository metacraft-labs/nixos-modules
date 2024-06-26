{
  lib,
  inputs,
  ...
}: {
  perSystem = {
    inputs',
    pkgs,
    ...
  }: let
    inherit (pkgs.hostPlatform) isLinux isDarwin isx86;
    unstablePkgs = inputs'.nixpkgs-unstable.legacyPackages;
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
    };

    packages =
      {
        nix-fast-build = inputs'.nix-fast-build.packages.nix-fast-build;
        lido-withdrawals-automation = pkgs.callPackage ./lido-withdrawals-automation {};
        pyroscope = pkgs.callPackage ./pyroscope {};
        grafana-agent = import ./grafana-agent {inherit inputs';};
      }
      // pkgs.lib.optionalAttrs isLinux {
        inherit (inputs'.validator-ejector.packages) validator-ejector;
        folder-size-metrics = pkgs.callPackage ./folder-size-metrics {};
      }
      // pkgs.lib.optionalAttrs ((isLinux && isx86) || isDarwin) rec {
        mcl = pkgs.callPackage ./mcl {
          buildDubPackage = inputs'.dlang-nix.legacyPackages.buildDubPackage.override {
            dCompiler = inputs'.dlang-nix.packages."ldc-binary-1_38_0";
          };
          nix-eval-jobs = inputs'.nix-eval-jobs.packages.nix-eval-jobs;
        };
      };
    checks = packages;
  };
}
