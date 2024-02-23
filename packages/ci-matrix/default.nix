{pkgs}: let
in
  with pkgs;
    stdenv.mkDerivation rec {
      pname = "ci-matrix";
      version = "main";

      src = ./.;

      buildPhase = ''
        sed -i 's|jq|${jq}/bin/jq|' *.sh
        sed -i 's|nix-eval-jobs |${nix-eval-jobs}/bin/nix-eval-jobs |' *.sh
        sed -i 's|"$root_dir/scripts/|"'$out'/bin/|' *.sh
      '';
      installPhase = ''
        mkdir -p $out/bin
        cp {ci-matrix,nix-eval-jobs,system-info}.sh $out/bin'';
      doCheck = false;

      meta.mainProgram = "ci-matrix.sh";
    }
