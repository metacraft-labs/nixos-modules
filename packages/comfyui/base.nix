{
  version,
  modelPathsFile,
  modelsPath,
  inputPath,
  outputPath,
  tempPath,
  userPath,
  stdenv,
  fetchFromGitHub,
}:
stdenv.mkDerivation {
  pname = "comfyui-base";
  inherit version;

  src = fetchFromGitHub {
    owner = "comfyanonymous";
    repo = "ComfyUI";
    rev = "b685b8a4e098237919adae580eb29e8d861b738f";
    hash = "sha256-OtTvyqiz2Ba7HViW2MxC1hFulSWPuQaCADeQflr80Ik=";
  };

  installPhase = ''
    runHook preInstall
    echo "Preparing bin folder"
    mkdir -p $out/bin/
    echo "Copying comfyui files"
    # These copies everything over but test/ci/github directories.  But it's not
    # very future-proof.  This can lead to errors such as "ModuleNotFoundError:
    # No module named 'app'" when new directories get added (which has happened
    # at least once).  Investigate if we can just copy everything.
    cp -r $src/app $out/
    cp -r $src/api_server $out/
    cp -r $src/comfy $out/
    cp -r $src/comfy_api_nodes $out/
    cp -r $src/comfy_extras $out/
    cp -r $src/comfy_execution $out/
    cp -r $src/utils $out/
    cp $src/*.py $out/
    cp --remove-destination $src/folder_paths.py $out/
    cp  $src/requirements.txt $out/
    mv $out/main.py $out/comfyui
    echo "Copying ${modelPathsFile} to $out"
    cp ${modelPathsFile} $out/extra_model_paths.yaml
    echo "Setting up input and output folders"
    ln -s ${inputPath} $out/input
    ln -s ${outputPath} $out/output
    echo "Setting up node folders"
    ln -s ${modelsPath}/wildcards $out/wildcards
    mkdir -p $out/${tempPath}
    echo "Patching python code..."
    substituteInPlace $out/folder_paths.py --replace 'os.path.join(base_path, "temp")' '"${tempPath}"'
    substituteInPlace $out/folder_paths.py --replace 'os.path.join(base_path, "user")' '"${userPath}"'
    runHook postInstall
  '';
}
