{
  lib,
  buildDubPackage,
  pkgs,
  ...
}: let
  excludedTests = (
    lib.concatStringsSep "|" [
      "(nix\\.(build|run))"
      "fetchJson|(coda\.)"
    ]
  );
in
  buildDubPackage rec {
    pname = "random-alerts";
    version = "unstable";
    src = lib.fileset.toSource {
      root = ./.;
      fileset =
        lib.fileset.fileFilter
        (file: builtins.any file.hasExt ["d" "sdl" "json" "nix"])
        ./.;
    };
    buildInputs = [pkgs.openssl];

    dubBuildFlags = ["--compiler=dmd" "-b" "debug"];

    doCheck = false;
    dubTestFlags = [
      "--compiler=dmd"
      "--"
      "-e"
      excludedTests
    ];

    meta.mainProgram = pname;
  }
