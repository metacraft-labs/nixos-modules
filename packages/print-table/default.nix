{
  pkgs,
  unstablePkgs,
  lib,
}: let
  jqBin = "${pkgs.jq}/bin/jq";
in
  pkgs.substituteAll {
    name = "print-table";
    inherit jqBin;
    dir = "bin";
    isExecutable = true;
    src = ./print-table.sh;
    meta.mainProgram = "print-table";
  }
