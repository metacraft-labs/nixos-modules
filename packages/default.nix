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
        ci-matrix = pkgs.callPackage ./ci-matrix {inherit unstablePkgs;};
        deploy-spec = pkgs.callPackage ./deploy-spec {};
        shard-matrix = pkgs.callPackage ./shard-matrix {inherit ci-matrix;};
        validator-ejector = inputs'.validator-ejector.packages.validator-ejector;
      };
    checks = packages;
  };
}
