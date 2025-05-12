{
  lib,
  buildPythonPackage,
  fetchgit,
  setuptools,
  python312,
}:
buildPythonPackage rec {
  pname = "cstr";
  version = "unstable";
  pyproject = false;

  buildInputs = with python312.pkgs; [
  ];

  src = fetchgit {
    url = "https://github.com/WASasquatch/cstr";
    rev = "0520c29a18a7a869a6e5983861d6f7a4c86f8e9b";
    hash = "sha256-zQDnjUk7IFVkWujPxq8JfUH6XIPHoaEG+xrLOEwXoro=";
  };

  meta = {
    description = "";
    homepage = "https://github.com/WASasquatch/cstr";
  };
}
