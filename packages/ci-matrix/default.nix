{
  pkgs,
  lib,
}: let
  options = {
    dir = "bin";
    isExecutable = true;

    jqBin = "${pkgs.jq}/bin/jq";
    cachixBin = "${pkgs.cachix}/bin/cachix";
    nixEvalJobsBin = "${pkgs.nix-eval-jobs}/bin/nix-eval-jobs";
  };

  scripts = rec {
    system-info = pkgs.substituteAll ({
        src = ./system-info.sh;
      }
      // options);
    nix-eval-jobs = pkgs.substituteAll ({
        systemInfoSh = "${system-info}/bin/system-info.sh";
        src = ./nix-eval-jobs.sh;
      }
      // options);
    ci-matrix = pkgs.substituteAll ({
        nixEvalJobsSh = "${nix-eval-jobs}/bin/nix-eval-jobs.sh";
        src = ./ci-matrix.sh;
      }
      // options);
  };
in
  with pkgs;
    pkgs.symlinkJoin rec {
      name = "ci-matrix";

      paths = lib.attrValues scripts;

      meta.mainProgram = "ci-matrix.sh";
    }
