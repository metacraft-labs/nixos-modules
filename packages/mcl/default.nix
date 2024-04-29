{
  lib,
  buildDubPackage,
  nix-eval-jobs,
  pkgs,
  fetchgit,
  ...
}: let
  deps = with pkgs; [cachix git nix nom nix-eval-jobs curl gawk dmidecode jc edid-decode];
in
  buildDubPackage rec {
    pname = "mcl";
    version = "unstable";
    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.fileFilter (file: builtins.any file.hasExt ["d" "sdl" "json" "nix"]) ./.;
    };

    nativeBuildInputs = [pkgs.makeWrapper] ++ deps;
    buildInputs = deps;
    checkInputs = deps;
    postFixup = ''
      wrapProgram $out/bin/${pname} --set PATH "${lib.makeBinPath deps}"
    '';

    dubBuildFlags = ["--compiler=dmd"];

    dubTestFlags = ["--compiler=dmd" "--" "-e" "(nix\\.(build|run)\\!JSONValue)|(nix\\.(build|run))|fetchJson"];

    meta.mainProgram = pname;
  }
