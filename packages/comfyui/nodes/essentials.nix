{
  stdenv,
  python312,
  fetchFromGitHub,
  lib,
  colour-science,
  rembg,
  pixeloe,
  transparent-background,
}:
stdenv.mkDerivation rec {
  pname = "essentials";
  version = "unstable";
  src = fetchFromGitHub {
    owner = "cubiq";
    repo = "ComfyUI_essentials";
    rev = "9d9f4bedfc9f0321c19faf71855e228c93bd0dc9";
    hash = "sha256-wkwkZVZYqPgbk2G4DFguZ1absVUFRJXYDRqgFrcLrfU=";
  };
  installPhase = ''
    mkdir -p $out/custom_nodes/${pname}
    cp -r $src/* $out/custom_nodes/${pname}
  '';

  dependencies = buildInputs;
  buildInputs = with python312.pkgs; [
    numba
    colour-science
    rembg
    pixeloe
    transparent-background
  ];
}
