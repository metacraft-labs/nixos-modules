{
  python312,
  comfyui-frontend-package,
  comfyui-workflow-templates,
  torchWithCuda,
  torchsdeWithCuda,
  torchvisionWithCuda,
  torchaudioWithCuda,
  numpy,
  einops,
  transformersWithCuda,
  tokenizers,
  sentencepiece,
  safetensorsWithCuda,
  aiohttp,
  yarl,
  pyyaml,
  pillow,
  scipy,
  tqdm,
  psutil,

  korniaWithCuda,
  spandrel,
  av,
  pydantic,

  customNodes,
}:
python312.buildEnv.override {
  extraLibs =
    with python312.pkgs;
    (
      [
        comfyui-frontend-package
        comfyui-workflow-templates
        torchWithCuda
        torchsdeWithCuda
        torchvisionWithCuda
        torchaudioWithCuda
        numpy
        einops
        transformersWithCuda
        tokenizers
        sentencepiece
        safetensorsWithCuda
        aiohttp
        yarl
        pyyaml
        pillow
        scipy
        tqdm
        psutil

        korniaWithCuda
        spandrel
        av
        pydantic
      ]
      ++ (builtins.concatMap (node: node.dependencies) customNodes)
    );
  ignoreCollisions = false;
}
