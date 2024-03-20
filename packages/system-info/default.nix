{
  pkgs,
  unstablePkgs,
  lib,
}: let
  jqBin = "${pkgs.jq}/bin/jq";
in
  pkgs.substituteAll {
    name = "system-info";
    inherit jqBin;
    dir = "bin";
    isExecutable = true;
    src = ./system-info.sh;
    meta.mainProgram = "system-info";
  }
