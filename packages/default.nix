{...}: {
  perSystem = {
    inputs',
    pkgs,
    ...
  }: rec {
    packages = {
      lido-withdrawals-automation = pkgs.callPackage ./lido-withdrawals-automation {};
      pyroscope = pkgs.callPackage ./pyroscope {};
      grafana-agent = import ./grafana-agent {inherit inputs';};
      validator-ejector = inputs'.validator-ejector.packages.validator-ejector;
      ci-matrix = pkgs.callPackage ./ci-matrix {};
    };
    checks = packages;
  };
}
