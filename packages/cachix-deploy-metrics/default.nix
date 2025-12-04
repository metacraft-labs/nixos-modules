{
  lib,
  buildDubPackage,
  pkgs,
  ...
}:
buildDubPackage rec {
  pname = "cachix-deploy-metrics";
  version = "unstable";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.fileFilter (
      file:
      builtins.any file.hasExt [
        "d"
        "sdl"
        "json"
      ]
    ) ./.;
  };
  dubLock = ./dub.lock.json; # Auto generated with `dub-to-nix`.
  dubBuildFlags = [ ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m755 ./build/${pname} $out/bin/${pname}
    runHook postInstall
  '';

  nativeBuildInputs = [
    pkgs.pkg-config
    pkgs.makeWrapper
  ];

  buildInputs = [
    pkgs.curl
  ];

  postFixup = ''
    wrapProgram $out/bin/${pname}
  '';

  meta.mainProgram = pname;
}
