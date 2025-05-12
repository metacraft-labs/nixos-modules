{
  stdenv,
  python312,
  fetchFromGitHub,
  lib,
  ultralytics,
  ultralytics-thop,
}:
stdenv.mkDerivation rec {
  pname = "impact-subpack";
  version = "1.3.2";
  src = fetchFromGitHub {
    owner = "ltdrdata";
    repo = "ComfyUI-Impact-Subpack";
    rev = version;
    hash = "sha256-kddOby08UI4dIEL7nHvONRnwNY50FU8Qsj7RRDHw8k4=";
  };
  installPhase = ''
    mkdir -p $out/custom_nodes/${pname}
    cp -r $src/* $out/custom_nodes/${pname}
  '';

  dependencies = with python312.pkgs; [
    matplotlib
    ultralytics
    ultralytics-thop
    numpy_1
    opencv-python-headless
    dill
  ];
}
