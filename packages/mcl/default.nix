{
  lib,
  stdenv,
  dub,
  dcompiler,
  ...
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "mcl";
  version = "0.0.1";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.fileFilter (file: builtins.any file.hasExt ["d" "sdl" "json"]) ./.;
  };

  nativeBuildInputs = [dub dcompiler];

  buildPhase = "dub build";
  checkPhase = "dub test";
  installPhase = ''
    install -D -m755 ./build/${finalAttrs.pname} $out/bin/${finalAttrs.pname}
  '';

  meta.mainProgram = finalAttrs.pname;
})
