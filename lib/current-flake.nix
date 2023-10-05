let
  currentFlake = builtins.fromJSON (builtins.readFile ../flake.lock);
  inherit (currentFlake.nodes.nixos-2305.locked) owner repo rev narHash;
  nixpkgs = builtins.fetchTarball {
    url = "https://github.com/${owner}/${repo}/archive/${rev}.tar.gz";
    sha256 = narHash;
  };
in {
  inherit currentFlake;
  lib = (import nixpkgs {system = "x86_64-linux";}).lib;
}
