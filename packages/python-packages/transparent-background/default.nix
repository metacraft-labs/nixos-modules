{
  buildPythonPackage,
  fetchgit,
  python312,
}:
buildPythonPackage {
  pname = "transparent-background";
  version = "unstable";

  buildInputs = with python312.pkgs; [
    numpy
    opencv-python-headless
    pillow
  ];

  preBuild = ''
    export HOME=$TMPDIR
  '';
  preInstall = ''
    ls $HOME
  '';

  src = fetchgit {
    url = "https://github.com/plemeri/transparent-background";
    rev = "60c6bc4b3d326d592f6e99568a5fdc5a28d9d791";
    hash = "sha256-MSvq7WX9gb9+UmvAh654OMXcCZIVrErL/rKtmjXnT0U=";
  };

  meta = {
    description = "";
    homepage = "https://github.com/plemeri/transparent-background";
  };
}
