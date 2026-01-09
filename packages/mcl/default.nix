{
  lib,
  dCompiler,
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
      v4l-utils
      dmidecode
      mesa-demos
      nixos-install-tools
      systemd
    ];
  excludedTests = (
    lib.concatStringsSep "|" [
      "(nix\\.(build|run|eval))"
      "fetchJson|(coda\.)"
      "isCached"
      "generateShardMatrix"
    ]
  );
in
pkgs.buildDubPackage rec {
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

  inherit dCompiler;

  dubLock = ./dub-lock.json;

  nativeBuildInputs = [ pkgs.makeWrapper ] ++ deps;

  dubBuildType = "debug";

  doCheck = true;

  checkPhase = ''
    dub test --skip-registry=all "''${dubFlags[@]}" ''${dubTestFlags[@]}
  '';

  dubTestFlags = [
    "--"
    "-e"
    excludedTests
  ];

  installPhase = ''
    runHook preInstall
    install -Dm755 ./build/${pname} -t $out/bin/
    runHook postInstall
  '';

  dontStrip = true;

  postFixup = ''
    wrapProgram $out/bin/${pname} \
      --set PATH "${lib.makeBinPath deps}" \
      --set LD_LIBRARY_PATH "${lib.makeLibraryPath deps}"
  '';

  meta = {
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    mainProgram = pname;
  };
}
