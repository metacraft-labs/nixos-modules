{
  lib,
  stdenv,
  dub,
  dcompiler,
  unstablePkgs,
  pkgs,
  ...
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "mcl";
  version = "0.0.1";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.fileFilter (file: builtins.any file.hasExt ["d" "sdl" "json"]) ./.;
  };

  nativeBuildInputs = [dub dcompiler pkgs.makeWrapper];

  buildPhase = "dub build";
  checkPhase = "dub test";
  installPhase = ''
    install -D -m755 ./build/${finalAttrs.pname} $out/bin/${finalAttrs.pname}
  '';
  postFixup = ''
    wrapProgram $out/bin/${finalAttrs.pname} --set PATH ${lib.makeBinPath [
      pkgs.cachix
      pkgs.git
      pkgs.nix
      unstablePkgs.nix-eval-jobs
      pkgs.curl
    ]}
  '';

  meta.mainProgram = finalAttrs.pname;
})
