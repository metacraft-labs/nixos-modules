{
  nix2container,

  lib,
  callPackage,
  runCommand,

  bashInteractive,
  coreutils,
  procps,
  util-linux,
  nix,
  direnv,
  cachix,
  curl,
  jq,
  gnupg,
  docker-client,
  nodejs_24,
  gitMinimal,
  gh,
}:
let
  inherit (callPackage ./utils.nix { inherit nix2container; }) mkNixImage;
in
mkNixImage {
  imageName = "gh-actions-ci-image";
  userName = "ci-user";
  packages = [
    gitMinimal
    procps
    util-linux
    nix
    direnv
    cachix
    curl
    jq
    gnupg
    docker-client
    nodejs_24
    gh
  ];
}
