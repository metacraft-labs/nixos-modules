{
  lib,
  buildPythonPackage,
  fetchgit,
  setuptools,
  python312,
}:
buildPythonPackage rec {
  pname = "segment-anything";
  version = "unstable";

  buildInputs = with python312.pkgs; [
    matplotlib
    opencv-python-headless
    pycocotools
    onnxruntime
    onnx
  ];

  src = fetchgit {
    url = "https://github.com/facebookresearch/segment-anything";
    rev = "dca509fe793f601edb92606367a655c15ac00fdf";
    hash = "sha256-28XHhv/hffVIpbxJKU8wfPvDB63l93Z6r9j1vBOz/P0=";
  };

  meta = {
    description = "";
    homepage = "https://github.com/facebookresearch/segment-anything";
  };
}
