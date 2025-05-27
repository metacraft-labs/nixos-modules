{
  lib,
  buildPythonPackage,
  fetchPypi,
  setuptools,
  torchWithCuda,
  torchvisionWithCuda,
  safetensorsWithCuda,
  einops,
}:
buildPythonPackage rec {
  pname = "spandrel";
  version = "0.4.1";
  pyproject = true;

  buildInputs = [
    torchWithCuda
    torchvisionWithCuda
    safetensorsWithCuda
    einops
    setuptools
  ];

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-ZG2YFqlC5Z1WqrLckENTlS5X3uSyyz9Z9+pNwPsRofI=";
  };

  pythonImportsCheck = [ "spandrel" ];

  meta = {
    description = "library for loading and running pre-trained PyTorch models";
    homepage = "https://github.com/chaiNNer-org/spandrel/";
    changelog = "https://github.com/chaiNNer-org/spandrel/releases/tag/v${version}";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ scd31 ];
  };
}
