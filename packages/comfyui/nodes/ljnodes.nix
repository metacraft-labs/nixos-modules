{
  stdenv,
  python312,
  fetchFromGitHub,
  lib,
}:
stdenv.mkDerivation rec {
  pname = "ljnodes";
  version = "unstable";
  src = fetchFromGitHub {
    owner = "coolzilj";
    repo = "ComfyUI-LJNodes";
    rev = "8172f7221071bc9b04e0230aed7648944c62c350";
    hash = "sha256-sBEf6bY2/EU7CznR5m20G6CY6+LCdGRhWAHHcRSZNiY=";
  };
  installPhase = ''
    mkdir -p $out/custom_nodes/${pname}
    cp -r $src/* $out/custom_nodes/${pname}
  '';

  dependencies = with python312.pkgs; [
  ];
}
