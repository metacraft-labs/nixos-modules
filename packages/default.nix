{pkgs, ...}: let
  lido-withdrawals-automation = pkgs.callPackage ./lido-withdrawals-automation {};
in {
  packages = {
    inherit lido-withdrawals-automation;
  };
}
