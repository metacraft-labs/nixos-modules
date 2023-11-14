{...}: {
  perSystem = {
    inputs',
    pkgs,
    ...
  }: {
    packages = {
      lido-withdrawals-automation = pkgs.callPackage ./lido-withdrawals-automation {};
      pyroscope = pkgs.callPackage ./pyroscope {};
      grafana-agent = import ./grafana-agent {inherit inputs';};
      validator-ejector = inputs'.validator-ejector.packages.validator-ejector;
    };
  };
}
