{
  stdenv,
  python312,
  fetchFromGitHub,
}:
stdenv.mkDerivation rec {
  pname = "rgthree-comfy";
  version = "unstable";
  src = fetchFromGitHub {
    owner = "rgthree";
    repo = "rgthree-comfy";
    rev = "aa6c75a30b3ee8f01d7c9f8b0a126cccdc90616a";
    hash = "sha256-TTSBZatQhZFYkOumO30XUzJekqHZBFwLzVGw3JpeJX4=";
  };
  installPhase = ''
    mkdir -p $out/custom_nodes/${pname}
    cp -r $src/* $out/custom_nodes/${pname}
  '';

  dependencies = buildInputs;
  buildInputs = [ ];
}
