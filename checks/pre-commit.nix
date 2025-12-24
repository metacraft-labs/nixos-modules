{ inputs, ... }:
{
  flake.modules.flake.git-hooks =
    { ... }:
    {
      imports = [
        # Import git-hooks flake-parts module
        # docs: https://flake.parts/options/git-hooks-nix
        inputs.git-hooks-nix.flakeModule
      ];

      config = {
        perSystem =
          { config, pkgs, ... }:
          {
            devShells.pre-commit =
              let
                inherit (config.pre-commit.settings) enabledPackages package configFile;
              in
              pkgs.mkShell {
                packages = enabledPackages ++ [ package ];
                shellHook = ''
                  ln -fvs ${configFile} .pre-commit-config.yaml
                  echo "Running Pre-commit checks"
                  echo "========================="
                '';
              };

            # impl: https://github.com/cachix/git-hooks.nix/blob/master/flake-module.nix
            pre-commit = {
              # Disable `checks` flake output
              check.enable = false;

              # Enable commonly used formatters
              settings = {
                # Use Rust-based alternative to pre-commit:
                # https://github.com/j178/prek
                package = pkgs.prek;

                excludes = [ "^.*\.age$" ];

                hooks = {
                  # Basic whitespace formatting
                  end-of-file-fixer.enable = true;
                  editorconfig-checker.enable = true;

                  # *.nix formatting
                  nixfmt-rfc-style.enable = true;

                  # *.rs formatting
                  rustfmt.enable = true;

                  # *.{js,jsx,ts,tsx,css,html,md,json} formatting
                  prettier = {
                    enable = true;
                    args = [
                      "--check"
                      "--list-different=false"
                      "--log-level=warn"
                      "--ignore-unknown"
                      "--write"
                    ];
                  };
                };
              };
            };
          };
      };
    };
}
