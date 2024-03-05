{
  pkgs,
  ci-matrix,
}: let
  jqBin = "${pkgs.jq}/bin/jq";
  nixBin = "${pkgs.nix}/bin/nix";
in
  pkgs.substituteAll {
    name = "shard-matrix";
    inherit jqBin nixBin;
    dir = "bin";
    isExecutable = true;
    src = ./shard-matrix.sh;
    meta.mainProgram = "shard-matrix";
  }
