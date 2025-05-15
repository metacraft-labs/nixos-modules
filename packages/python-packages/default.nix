{
  callPyPackage,
  pkgs,
  nixpkgs-unstable,
}:
let
  python312Pkgs = pkgs.python312.pkgs;
in
rec {
  spandrel = callPyPackage ./spandrel { };

  comfyui-frontend-package = callPyPackage ./comfyui-frontend-package { };

  comfyui-workflow-templates = callPyPackage ./comfyui-workflow-templates { };

  segment-anything = callPyPackage ./segment-anything { };

  pixeloe = callPyPackage ./pixeloe { };

  pilgram = callPyPackage ./pilgram { };

  transparent-background = callPyPackage ./transparent-background { };

  colour-science = callPyPackage ./colour-science { };

  cstr = callPyPackage ./cstr { };

  img2texture = callPyPackage ./img2texture { };

  chkpkg = callPyPackage ./chkpkg { };

  neatest = callPyPackage ./neatest { };

  inherit (python312Pkgs) torchWithCuda;
  torchsdeWithCuda = (python312Pkgs.torchsde.override ({ torch = torchWithCuda; }));
  torchvisionWithCuda = (python312Pkgs.torchvision.override ({ torch = torchWithCuda; }));
  torchaudioWithCuda = (python312Pkgs.torchaudio.override ({ torch = torchWithCuda; }));
  safetensorsWithCuda = (python312Pkgs.safetensors.override ({ torch = torchWithCuda; }));
  transformersWithCuda = (
    python312Pkgs.transformers.override ({ safetensors = safetensorsWithCuda; })
  );
  korniaWithCuda = (python312Pkgs.kornia.override ({ torch = torchWithCuda; }));
  fairscaleWithCuda = (python312Pkgs.fairscale.override ({ torch = torchWithCuda; }));
  timmWithCuda = (
    python312Pkgs.timm.override ({
      safetensors = safetensorsWithCuda;
      torchvision = torchvisionWithCuda;
      torch = torchWithCuda;
    })
  );

  inherit (nixpkgs-unstable.legacyPackages.python312.pkgs) ultralytics ultralytics-thop rembg;

}
