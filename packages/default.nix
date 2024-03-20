{...}: {
  perSystem = {
    inputs',
    pkgs,
    ...
  }: let
    unstablePkgs = inputs'.nixpkgs-unstable.legacyPackages;
  in rec {
    packages =
      rec {
        lido-withdrawals-automation = pkgs.callPackage ./lido-withdrawals-automation {};
        pyroscope = pkgs.callPackage ./pyroscope {};
        grafana-agent = import ./grafana-agent {inherit inputs';};
      }
      // pkgs.lib.optionalAttrs pkgs.hostPlatform.isLinux rec {
        deploy-spec = pkgs.callPackage ./deploy-spec {inherit inputs';};
        shard-matrix = pkgs.callPackage ./shard-matrix {inherit ci-matrix;};
        validator-ejector = inputs'.validator-ejector.packages.validator-ejector;

        system-info = pkgs.callPackage ./system-info {inherit unstablePkgs;};
        nix-eval-jobs = pkgs.callPackage ./nix-eval-jobs {inherit unstablePkgs system-info;};
        print-table = pkgs.callPackage ./print-table {inherit unstablePkgs;};
        ci-matrix = pkgs.callPackage ./ci-matrix {inherit unstablePkgs print-table nix-eval-jobs inputs';};
      };
    checks = packages;
  };
}
