{
  lib,
  buildPythonPackage,
  fetchgit,
  setuptools,
  python312,
  chkpkg,
  neatest,
}:
buildPythonPackage rec {
  pname = "img2texture";
  version = "unstable";
  pyproject = false;

  buildInputs = with python312.pkgs; [
    mypy
    chkpkg
    click
    pyinstaller
    neatest
  ];

  src = fetchgit {
    url = "https://github.com/WASasquatch/img2texture";
    rev = "d6159abea44a0b2cf77454d3d46962c8b21eb9d3";
    hash = "sha256-58me9Rng+hy1ntUBJ8cUVVrk+CEFgmW/ATnzYk7N8U4=";
  };

  meta = {
    description = "";
    homepage = "https://github.com/WASasquatch/img2texture";
  };
}
