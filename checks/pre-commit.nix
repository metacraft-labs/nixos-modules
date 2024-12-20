{ inputs, system, ... }:
inputs.pre-commit-hooks.lib.${system}.run {
  src = ../.;
  hooks = {
    nixfmt-rfc-style.enable = true;
  };
}
