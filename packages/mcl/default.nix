{
  lib,
  buildDubPackage,
  pkgs,
  fetchgit,
  buildEnv,
  ...
}: let
  deps = with pkgs; [
    cachix
    git
    nix
    nom
    nix-eval-jobs
    curl
  ];
  fullDeps = with pkgs;
    [
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
    ]
    ++ deps;
  excludedTests = (
    lib.concatStringsSep "|" [
      "(nix\\.(build|run))"
      "fetchJson|(coda\.)"
    ]
  );
  mclBase = buildDubPackage rec {
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
    buildInputs = deps;
    checkInputs = deps;

    dubBuildFlags = ["--compiler=dmd" "-b" "debug"];

    dubTestFlags = [
      "--compiler=dmd"
      "--"
      "-e"
      excludedTests
    ];

    meta.mainProgram = "mcl";
  };

  mclBuild = mclName: mclDeps:
    buildEnv rec {
      name = "${mclBase.pname}-mclName-${mclBase.version}";
      paths = [mclBase];
      pathsToLink = ["/" "/bin"];
      postBuild = ''
        wrapProgram $out/bin/mcl --set PATH "${lib.makeBinPath mclDeps}"
      '';
      nativeBuildInputs = [pkgs.makeWrapper];
      inherit (mclBase) meta;
    };
in rec {
  mclFull = mclBuild "full" fullDeps;
  mclMin = mclBuild "min" deps;
  mcl = mclMin;
}
