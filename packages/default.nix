{...}: {
  perSystem = {
    inputs',
    pkgs,
    ...
  }: {
    packages = {
      lido-withdrawals-automation = pkgs.callPackage ./lido-withdrawals-automation {};
      validator-ejector = inputs'.validator-ejector.packages.validator-ejector;
    };
  };
}
