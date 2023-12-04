{
  lib,
  fetchFromGitHub,
  buildNpmPackage,
}:
buildNpmPackage rec {
  pname = "lido-withdrawals-automation";
  version = "1.0.2";

  # src = fetchFromGitHub {
  #   owner = "status-im";
  #   repo = "lido-withdrawals-automation";
  #   rev = "v${version}";
  #   hash = "sha256-XW+IpB+KHYXf0tm90bztjuM/tYRM1/uzZ9rwg50gAcU=";
  # };

  src = fetchFromGitHub {
    owner = "MartinNikov";
    repo = "lido-withdrawals-automation";
    rev = "27a5fb57e29b004891d1717d94c6585dc0cef4f6";
    hash = "sha256-9Uj/o2MQwj0EL6h8FtlCLl+HrNrTiPWpr998syqwEgk=";
  };

  npmDepsHash = "sha256-cR9smnQtOnpY389ay54SdbR5qsD2MD6zB2X43tfoHwM=";

  dontNpmBuild = true;
  doCheck = true;

  checkPhase = ''
    npm run coverage
  '';

  meta = with lib; {
    mainProgram = "lido-withdrawals-automation";
    homepage = "https://github.com/status-im/lido-withdrawals-automation";
  };
}
