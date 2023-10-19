{pkgs}: let
  nodejs = pkgs.nodejs-18_x;
in
  with pkgs;
    buildNpmPackage rec {
      pname = "lido-withdrawals-automation";
      version = "0.1.0";
      src = fetchFromGitHub {
        owner = "status-im";
        repo = "lido-withdrawals-automation";
        rev = "9a52167e86d8b727b27fd4ebe0d93935725a0ac3";
        hash = "sha256-xnFpMQrJTv4uUSqoMCQEdr+Eu80ac6dYQhAh0rBzvTQ=";
      };

      npmDepsHash = "sha256-cR9smnQtOnpY389ay54SdbR5qsD2MD6zB2X43tfoHwM=";

      npmPackFlags = ["--ignore-scripts"];
      dontNpmBuild = true;
      doCheck = false;

      nativeBuildInputs = [nodejs];

      buildInputs = [];

      meta = with lib; {
        mainProgram = "lido-withdrawals-automation";
        homepage = "https://github.com/status-im/lido-withdrawals-automation";
      };
    }
