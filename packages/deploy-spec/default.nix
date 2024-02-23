{pkgs}: let
in
  with pkgs;
    stdenv.mkDerivation rec {
      pname = "deploy-spec";
      version = "main";

      src = ./.;

      buildPhase = ''
        sed -i 's|cachix|${cachix}/bin/cachix|' *.sh
      '';
      installPhase = ''
        mkdir -p $out/bin
        cp deploy-spec.sh $out/bin'';
      doCheck = false;

      meta.mainProgram = "deploy-spec.sh";
    }
