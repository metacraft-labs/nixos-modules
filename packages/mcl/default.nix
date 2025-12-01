{
  lib,
  buildDubPackage,
  pkgs,
  nix,
  nix-eval-jobs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isLinux isx86;
  deps =
    with pkgs;
    [
      nix
      nix-eval-jobs
    ]
    ++ (with pkgs; [
      gitMinimal
      gawk
      jc
      edid-decode
      coreutils-full
      util-linux
      xorg.xrandr
      perl
      alejandra
      openssh
      cachix
      curl
    ])
    ++ lib.optionals (isLinux && isx86) [
      dmidecode
      mesa-demos
      nixos-install-tools
      systemd
    ];
  excludedTests = (
    lib.concatStringsSep "|" [
      "(nix\\.(build|run|eval))"
      "fetchJson|(coda\.)"
      "checkPackage"
      "generateShardMatrix"
    ]
  );
in
buildDubPackage rec {
  pname = "mcl";
  version = "unstable";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.fileFilter (
      file:
      builtins.any file.hasExt [
        "d"
        "sdl"
        "json"
        "nix"
      ]
    ) ./.;
  };

  nativeBuildInputs = [ pkgs.makeWrapper ] ++ deps;

  postFixup = ''
    wrapProgram $out/bin/${pname} --set PATH "${lib.makeBinPath deps}" --set LD_LIBRARY_PATH "${lib.makeLibraryPath deps}"
  '';

  dubBuildFlags = [
    "-b"
    "debug"
  ];

  dubTestFlags = [
    "--"
    "-e"
    excludedTests
  ];

  meta.mainProgram = pname;
}
