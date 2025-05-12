{
  lib,
  runCommand,
  callPyPackage,
  writers,
  writeTextFile,
  pkgs,
  basePath ? "/var/lib/comfyui",
  modelsPath ? "${basePath}/models",
  inputPath ? "${basePath}/input",
  outputPath ? "${basePath}/output",
  tempPath ? "${basePath}/temp",
  userPath ? "${basePath}/user",
  customNodes ? [ ],
  models ? {
    checkpoints = [ ];
    clip = [ ];
    clip_vision = [ ];
    configs = [ ];
    controlnet = [ ];
    embeddings = [ ];
    upscale_modules = [ ];
    vae = [ ];
    vae_approx = [ ];
    gligen = [ ];
  },
}:

let
  version = "unstable-2025-04-26";

  config-data = {
    comfyui = {
      base_path = modelsPath;
      checkpoints = "${modelsPath}/checkpoints";
      clip = "${modelsPath}/clip";
      clip_vision = "${modelsPath}/clip_vision";
      configs = "${modelsPath}/configs";
      controlnet = "${modelsPath}/controlnet";
      diffusion_models = "${modelsPath}/diffusion_models";
      embeddings = "${modelsPath}/embeddings";
      loras = "${modelsPath}/loras";
      style_models = "${modelsPath}/style_models";
      text_encoders = "${modelsPath}/text_encoders";
      upscale_models = "${modelsPath}/upscale_models";
      vae = "${modelsPath}/vae";
      vae_approx = "${modelsPath}/vae_approx";
    };
  };

  modelPathsFile = writeTextFile {
    name = "extra_model_paths.yaml";
    text = (lib.generators.toYAML { } config-data);
  };

  pythonEnv = callPyPackage ./python-env.nix {
    inherit customNodes;
  };

  installedModels =
    let
      # Helper function to process a single category
      processCategory =
        category: urls:
        map (
          model:
          if lib.isDerivation model then
            model
          else
            pkgs.fetchurl rec {
              url = model.url;
              name = if builtins.hasAttr "name" model then model.name else builtins.baseNameOf model.url;
              hash = model.hash;
              downloadToTemp = true;
              recursiveHash = true;
              postFetch = ''
                echo mkdir -p "$out"/${category}
                mkdir -p "$out"/${category}
                cp "$downloadedFile" "$out"/${category}/${name}
              '';
            }
        ) urls;
    in
    builtins.concatLists (builtins.attrValues (builtins.mapAttrs processCategory models));

  comfyui-base = callPyPackage ./base.nix {
    inherit
      version
      modelsPath
      modelPathsFile
      inputPath
      outputPath
      tempPath
      userPath
      ;
  };

  wrapperScript = writers.writeBashBin "comfyui" ''
    cd $out
    export WAS_CONFIG_DIR="${userPath}"
    ${pythonEnv}/bin/python comfyui \
      --input-directory ${inputPath} \
      --output-directory ${outputPath} \
      --extra-model-paths-config ${modelPathsFile} \
      --temp-directory ${tempPath} \
      "$@"
  '';

in
(runCommand "comfyui"
  {
    inherit version;

    meta = {
      homepage = "https://github.com/comfyanonymous/ComfyUI";
      description = "The most powerful and modular stable diffusion GUI with a graph/nodes interface.";
      license = lib.licenses.gpl3;
      platforms = lib.platforms.all;
    };
    passthru.nodes = import ./nodes { inherit callPyPackage; };
  }
  (
    ''
      mkdir -p $out/{bin,custom_nodes,models}
    ''
    + (lib.concatMapStrings (dir: ''
      [[ ${dir.pname} == "was-node-suite" ]] && mkdir -p $out/custom_nodes/was-node-suite
      cp -r ${dir}/* $out/
    '') ([ comfyui-base ] ++ customNodes))
    + (lib.concatMapStrings (model: ''
      cd ${model}
      find . -mindepth 1 -type d -exec mkdir -p $out/models/{} \;
      cp -rs ${model}/* $out/models/
    '') installedModels)
    + ''
      cp ${wrapperScript}/bin/comfyui $out/bin/comfyui
      chmod +x $out/bin/comfyui
      substituteInPlace $out/bin/comfyui --replace "\$out" "$out"
    ''
  )
)
