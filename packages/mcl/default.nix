{
  lib,
  buildDubPackage,
  pkgs,
  cachix,
  nix,
  nix-eval-jobs,
  ...
}: let
  deps =
    [
      cachix
      nix
      nix-eval-jobs
    ]
    ++ (with pkgs; [
      git
      nom
      curl
      gawk
      dmidecode
      jc
      edid-decode
      coreutils-full
      util-linux
      xorg.xrandr
      glxinfo
      nixos-install-tools
      perl
      systemd
      alejandra
      openssh
    ]);
  excludedTests = (
    lib.concatStringsSep "|" [
      "(nix\\.(build|run))"
      "fetchJson|(coda\.)"
      "checkPackage"
    ]
  );
in
  buildDubPackage rec {
    pname = "mcl";
    version = "unstable";
    src = lib.fileset.toSource {
      root = ./.;
      fileset =
        lib.fileset.fileFilter
        (file: builtins.any file.hasExt ["d" "sdl" "json" "nix"])
        ./.;
    };

    nativeBuildInputs = [pkgs.makeWrapper] ++ deps;

    postFixup = ''
      wrapProgram $out/bin/${pname} --set PATH "${lib.makeBinPath deps}"
    '';

    dubBuildFlags = ["--compiler=dmd" "-b" "debug"];

    dubTestFlags = [
      "--compiler=dmd"
      "--"
      "-e"
      excludedTests
    ];

    meta.mainProgram = pname;
  }
