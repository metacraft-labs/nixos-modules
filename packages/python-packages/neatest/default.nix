{
  buildPythonPackage,
  fetchgit,
  chkpkg,
}:
buildPythonPackage rec {
  pname = "neatest_py";
  version = "3.9.1";
  pyproject = false;

  buildInputs = [
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
