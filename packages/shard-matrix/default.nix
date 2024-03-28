{
  pkgs,
  ci-matrix,
}: let
  jqBin = "${pkgs.jq}/bin/jq";
in
  pkgs.substituteAll {
    name = "shard-matrix";
    inherit jqBin;
    dir = "bin";
    isExecutable = true;
    src = ./shard-matrix.sh;
    meta.mainProgram = "shard-matrix";
  }
