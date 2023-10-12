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
        rev = "6e45ee3ab35461288f23856b80b300312e23554a";
        hash = "sha256-/JX6/G5DWY5/hg/5yzCjv+vPocnADKuc7E486nfLrZc=";
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
