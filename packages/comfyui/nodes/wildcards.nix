{ stdenv, fetchFromGitHub }:
stdenv.mkDerivation rec {
  pname = "comfyui_wildcards";
  version = "unstable";
  src = fetchFromGitHub {
    owner = "lordgasmic";
    repo = "comfyui_wildcards";
    rev = "c14cf0919f2fc6def75c7b34e954e22fc9c5135e";
    hash = "sha256-fRlgrwLpQy3iVhrV+kzCTObH3lWRJ3JYJLVAvDJXPCI=";
  };
  installPhase = ''
    mkdir -p $out/custom_nodes/${pname}
    cp -r $src/* $out/custom_nodes/${pname}
  '';
  dependencies = [ ];
}
