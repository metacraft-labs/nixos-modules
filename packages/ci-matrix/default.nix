{
  pkgs,
  unstablePkgs,
  lib,
  nix-eval-jobs,
  print-table,
  inputs',
}: let
  jqBin = "${pkgs.jq}/bin/jq";
  cachixBin = "${inputs'.cachix.packages.cachix}/bin/cachix";
  nixEvalJobsSh = "${nix-eval-jobs}/bin/nix-eval-jobs";
  printTableSh = "${print-table}/bin/print-table";
in
  pkgs.substituteAll {
    name = "ci-matrix";
    dir = "bin";
    isExecutable = true;

    inherit jqBin cachixBin nixEvalJobsSh printTableSh;

    src = ./ci-matrix.sh;

    meta.mainProgram = "ci-matrix";
  }
