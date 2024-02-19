{...}: {
  perSystem = {
    inputs',
    pkgs,
    ...
  }: rec {
    packages =
      rec {
        lido-withdrawals-automation = pkgs.callPackage ./lido-withdrawals-automation {};
        pyroscope = pkgs.callPackage ./pyroscope {};
        grafana-agent = import ./grafana-agent {inherit inputs';};
        ci-matrix = pkgs.callPackage ./ci-matrix {};
      }
      // pkgs.lib.optionalAttrs pkgs.hostPlatform.isLinux rec {
        validator-ejector = inputs'.validator-ejector.packages.validator-ejector;
      };
    checks = packages;
  };
}
