{
  pkgs,
  unstablePkgs,
  lib,
  inputs',
  writeShellApplication,
}: let
  dlangProg = pkgs.stdenv.mkDerivation rec {
    name = "ci-matrix-d";
    src = ./ci-matrix.d;
    dontUnpack = true;
    nativeBuildInputs = with pkgs; [dmd ldc];
    buildInputs = with pkgs; [ncurses zlib];

    buildPhase = ''
      runHook preBuild
      dmd -debug -preview=in "${src}"
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      cp *-ci-matrix $out/bin/ci-matrix-d
      chmod +x $out/bin/ci-matrix-d
      runHook postInstall
    '';

    postInstall = ''
      ${pkgs.removeReferencesTo}/bin/remove-references-to -t ${pkgs.ldc} $out/bin/ci-matrix-d
    '';
  };
in
  writeShellApplication {
    name = "ci-matrix";

    runtimeInputs = [dlangProg unstablePkgs.nix-eval-jobs];

    text = builtins.readFile ./ci-matrix.sh;
  }
