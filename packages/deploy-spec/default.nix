{
  pkgs,
  inputs',
}: let
  cachixBin = "${inputs'.cachix.packages.cachix}/bin/cachix";
in
  pkgs.substituteAll {
    name = "deploy-spec";
    inherit cachixBin;
    dir = "bin";
    isExecutable = true;
    src = ./deploy-spec.sh;
    meta.mainProgram = "deploy-spec";
  }
