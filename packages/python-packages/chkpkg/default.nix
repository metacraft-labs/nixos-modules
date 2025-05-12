{
  lib,
  buildPythonPackage,
  fetchgit,
  setuptools,
  python312,
}:
buildPythonPackage rec {
  pname = "chkpkg_py";
  version = "0.5.2";
  pyproject = false;

  buildInputs = with python312.pkgs; [
    mypy
  ];

  src = fetchgit {
    url = "https://github.com/rtmigo/chkpkg_py";
    rev = version;
    hash = "sha256-qfIyrWlU65rryBKwxmWgmWbl1cbDQ1Pkfr6BsYJn+ks=";
  };

  meta = {
    description = "";
    homepage = "https://github.com/rtmigo/chkpkg_py";
  };
}
