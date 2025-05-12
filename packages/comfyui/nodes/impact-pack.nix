{
  stdenv,
  python312,
  fetchFromGitHub,
  segment-anything,
  transformersWithCuda,
  lib,
}:
stdenv.mkDerivation rec {
  pname = "impact-pack";
  version = "8.14.2";
  src = fetchFromGitHub {
    owner = "ltdrdata";
    repo = "ComfyUI-Impact-Pack";
    rev = version;
    hash = "sha256-yPf769ncRD/WoWeYrMUNDNOYySgJihu6kiwQhtFrau8=";
  };
  installPhase = ''
    mkdir -p $out/custom_nodes/${pname}
    cp -r $src/* $out/custom_nodes/${pname}
  '';

  dependencies = with python312.pkgs; [
    segment-anything
    scikit-image
    piexif
    transformersWithCuda
    opencv-python-headless
    scipy
    numpy_1
    dill
    matplotlib
  ];
}
