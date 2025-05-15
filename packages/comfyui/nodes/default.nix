{ callPyPackage }:
{
  wildcards = callPyPackage ./wildcards.nix { };
  impact-pack = callPyPackage ./impact-pack.nix { };
  # impact-subpack = callPyPackage ./impact-subpack.nix { }; # can't find ultralytics
  rgthree-comfy = callPyPackage ./rgthree-comfy.nix { };
  essentials = callPyPackage ./essentials.nix { };
  inspire-pack = callPyPackage ./inspire-pack.nix { };
  ljnodes = callPyPackage ./ljnodes.nix { };
  was-node-suite = callPyPackage ./was-node-suite.nix { }; # needs directory to be writeable, and opencv with ffmpeg
}
