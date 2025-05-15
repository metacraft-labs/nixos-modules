{
  stdenv,
  python312,
  fetchFromGitHub,
  rembg,
  fairscaleWithCuda,
  timmWithCuda,
  transformersWithCuda,
  pilgram,
  img2texture,
  cstr,
}:
stdenv.mkDerivation rec {
  pname = "was-node-suite";
  version = "unstable";
  src = fetchFromGitHub {
    owner = "WASasquatch";
    repo = "was-node-suite-comfyui";
    rev = "1cd8d304eda256c412b8589ce1f00be3c61cf9ec";
    hash = "sha256-wV7MOaAWVPyw+oA5Rhw0+WYkuiZ+Ygr01DbPWbQsXHM=";
  };
  installPhase = ''
    mkdir -p $out/custom_nodes/${pname}
    cp -r $src/* $out/custom_nodes/${pname}
  '';

  dependencies = with python312.pkgs; [
    cmake
    fairscaleWithCuda
    img2texture
    cstr
    gitpython
    imageio
    joblib
    matplotlib
    numba
    numpy
    opencv-python-headless
    pilgram
    #git+https://github.com/WASasquatch/ffmpy.git #WASasquatch's version only changes the version number
    ffmpy
    rembg
    scikit-image
    scikit-learn
    scipy
    timmWithCuda
    tqdm
    transformersWithCuda

    pip
  ];
}
