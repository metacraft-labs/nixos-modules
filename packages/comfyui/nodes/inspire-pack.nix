{
  stdenv,
  python312,
  fetchFromGitHub,
}:
stdenv.mkDerivation rec {
  pname = "inspire-pack";
  version = "1.18";
  src = fetchFromGitHub {
    owner = "ltdrdata";
    repo = "ComfyUI-Inspire-Pack";
    rev = version;
    hash = "sha256-mRE6RWK4gwc6Hw1gL2xeIWpSzT677QnBTNAy9OdutLM=";
  };
  installPhase = ''
    mkdir -p $out/custom_nodes/${pname}
    cp -r $src/* $out/custom_nodes/${pname}
  '';

  dependencies = with python312.pkgs; [
    matplotlib
    cachetools
    numpy_1
    webcolors
    opencv-python-headless
  ];
}
