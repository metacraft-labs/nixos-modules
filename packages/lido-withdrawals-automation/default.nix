{
  lib,
  fetchFromGitHub,
  buildNpmPackage,
}:
buildNpmPackage rec {
  pname = "lido-withdrawals-automation";
  version = "1.0.2";

  src = fetchFromGitHub {
    owner = "status-im";
    repo = "lido-withdrawals-automation";
    rev = "605bd0a2f5867de01612d05352f8345cf53b3985";
    hash = "sha256-azEnN2+uA6BgIHfxU/J23uLnr1TvGFnDyHxFWOyAwIU=";
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
