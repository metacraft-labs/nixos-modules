{
  lib,
  buildPythonPackage,
  fetchgit,
  setuptools,
  python312,
  chkpkg,
}:
buildPythonPackage rec {
  pname = "neatest_py";
  version = "3.9.1";
  pyproject = false;

  buildInputs = with python312.pkgs; [
    chkpkg
  ];

  src = fetchgit {
    url = "https://github.com/rtmigo/neatest_py";
    rev = version;
    hash = "sha256-bZlbVCqLXLp0ankEArDqxOFdn4ZtEDTMg9CwYnJaiFs=";
  };

  meta = {
    description = "";
    homepage = "https://github.com/rtmigo/neatest_py";
  };
}
