{
  buildPythonPackage,
  fetchgit,
  python312,
  poetry,
}:
buildPythonPackage rec {
  pname = "pilgram";
  version = "unstable";
  pyproject = true;

  nativeBuildInputs = buildInputs;
  preBuild = ''
    export HOME=$TMPDIR
  '';
  buildInputs = with python312.pkgs; [
    numpy
    pillow
    poetry
    poetry-core
    flake8
    black
    isort
    pytest
    pytest-cov
    pytest-mock
    pytest-benchmark
  ];

  src = fetchgit {
    url = "https://github.com/akiomik/pilgram";
    rev = "ecef609b233b2f650dd82ca90d3c3d20148849c7";
    hash = "sha256-j8mqUwMZdyN7XdvJ141GTVyW9XtNN5bQFCOscM7NqbA=";
  };

  meta = {
    description = "";
    homepage = "https://github.com/akiomik/pilgram";
  };
}
