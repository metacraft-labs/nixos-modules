{
  lib,
  dCompiler,
  pkgs,
  nix,
  nix-eval-jobs,
  cachix,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isLinux isx86;
  deps =
    with pkgs;
    [
      nix
      nix-eval-jobs
      cachix
    ]
    ++ (with pkgs; [
      gitMinimal
      jc
      util-linux
      xorg.xrandr
      alejandra
      openssh
    ])
    ++ lib.optionals (isLinux && isx86) [
      dmidecode
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

  compiler = dCompiler;

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
      --prefix PATH : "${lib.makeBinPath deps}" \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath deps}"
  '';

  meta = {
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    mainProgram = pname;
  };
}
