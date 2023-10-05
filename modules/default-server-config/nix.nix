{
  nix = {
    settings = {
      trusted-users = ["root" "@metacraft"];
      experimental-features = ["nix-command" "flakes"];
    };
    generateNixPathFromInputs = true;
    generateRegistryFromInputs = true;
    linkInputs = true;
  };
}
