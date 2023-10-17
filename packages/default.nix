{
  pkgs,
  inputs',
  ...
}: let
  lido-withdrawals-automation = pkgs.callPackage ./lido-withdrawals-automation {};
in {
  packages = {
    inherit lido-withdrawals-automation;
    validator-ejector = inputs'.validator-ejector.packages.validator-ejector;
  };
}
