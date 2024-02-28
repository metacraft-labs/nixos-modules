{lib,  ...}: {
  perSystem = {
    inputs',
    pkgs,
    ...
  }: let
    inherit (pkgs.hostPlatform) isLinux isx86;
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
        lido-withdrawals-automation = pkgs.callPackage ./lido-withdrawals-automation {};
        pyroscope = pkgs.callPackage ./pyroscope {};
        grafana-agent = import ./grafana-agent {inherit inputs';};
        ci-matrix = pkgs.callPackage ./ci-matrix {inherit unstablePkgs;};
        folder-size-metrics = pkgs.callPackage ./folder-size-metrics {};
        deploy-spec = pkgs.callPackage ./deploy-spec {};
      }
      // pkgs.lib.optionalAttrs isLinux {
        inherit (inputs'.validator-ejector.packages) validator-ejector;
      }
      // pkgs.lib.optionalAttrs (isLinux && isx86) {
        mcl = pkgs.callPackage ./mcl {
          inherit (inputs'.dlang-nix.packages) dub;
          dcompiler = inputs'.dlang-nix.packages.ldc;
        };
      };
    checks = packages;
  };
}
