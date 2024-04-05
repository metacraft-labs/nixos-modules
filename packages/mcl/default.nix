{
  lib,
  stdenv,
  dub,
  dcompiler,
  unstablePkgs,
  pkgs,
  fetchgit,
  ...
}:
stdenv.mkDerivation rec {
  name = "mcl";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.fileFilter (file: builtins.any file.hasExt ["d" "sdl" "json"]) ./.;
  };

  nativeBuildInputs = [dub dcompiler pkgs.makeWrapper];

  silly = fetchgit {
    url = "https://gitlab.com/AntonMeep/silly";
    rev = "v1.1.1";
    sha256 = "sha256-pggc+tlxoiSngmSwOT7euXkbcChwRuicVo/FL20tn3s=";
  };

  buildPhase = ''
    mkdir home
    export HOME="$(pwd)/home"
    dub add-local "${silly}" "1.1.1"
    dub build
  '';
  checkPhase = "dub test";
  installPhase = ''
    install -D -m755 ./build/${name} $out/bin/${name}
  '';
  postFixup = ''
    wrapProgram $out/bin/${name} --set PATH ${lib.makeBinPath [
      pkgs.cachix
      pkgs.git
      pkgs.nix
      unstablePkgs.nix-eval-jobs
      pkgs.curl
    ]}
  '';

  meta.mainProgram = name;
}
