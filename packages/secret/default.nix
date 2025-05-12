{
  inputs',
  pkgs,
  lib,
  ...
}:
let
  agenix = inputs'.agenix.packages.agenix.override { ageBin = "${pkgs.rage}/bin/rage"; };
in
  pkgs.substituteAll {
    name = "secret";
    dir = "bin";
    src = ./secret.sh;
    isExecutable = true;

    binPath = lib.makeBinPath (with pkgs; [
      coreutils util-linux gnused
    ]);
  }
