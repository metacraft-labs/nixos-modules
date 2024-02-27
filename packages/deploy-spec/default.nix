{pkgs}: let
  cachixBin = "${pkgs.cachix}/bin/cachix";
in
  pkgs.substituteAll {
    name = "deploy-spec";
    inherit cachixBin;
    dir = "bin";
    isExecutable = true;
    src = ./deploy-spec.sh;
    meta.mainProgram = "deploy-spec.sh";
  }
