{
  lib,
  buildPythonPackage,
  fetchgit,
  setuptools,
  python312,
  korniaWithCuda,
}:
buildPythonPackage rec {
  pname = "pixeloe";
  version = "unstable";
  pyproject = true;

  buildInputs = with python312.pkgs; [
    numpy
    opencv-python
    pillow
    korniaWithCuda
    torchWithCuda
  ];

  src = fetchgit {
    url = "https://github.com/KohakuBlueleaf/PixelOE";
    rev = "7a77ea53c573e8092a2b1808c0a56b2f4bad8f46";
    hash = "sha256-cnGyQFUrrtEI4YmsNSc4nAxh9wyq7/ouGe8TLF5fjJE=";
  };

  meta = {
    description = "";
    homepage = "https://github.com/KohakuBlueleaf/PixelOE";
  };
}
