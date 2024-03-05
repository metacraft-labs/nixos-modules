{
  pkgs,
  unstablePkgs,
  lib,
  system-info,
}: let
  jqBin = "${pkgs.jq}/bin/jq";
  systemInfoSh = "${system-info}/bin/system-info";
  nixEvalJobsBin = "${unstablePkgs.nix-eval-jobs}/bin/nix-eval-jobs";
in
  pkgs.substituteAll {
    name = "nix-eval-jobs";
    inherit jqBin nixEvalJobsBin systemInfoSh;
    dir = "bin";
    isExecutable = true;
    src = ./nix-eval-jobs.sh;
    meta.mainProgram = "nix-eval-jobs";
  }
