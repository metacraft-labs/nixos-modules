{ inputs, ... }:
{
  imports = [
    (import ../checks/pre-commit.nix {
      inherit inputs;
    }).flake.modules.flake.git-hooks
  ];

  perSystem =
    {
      pkgs,
      inputs',
      config,
      ...
    }:
    {
      devShells.default =
        let
          repl = pkgs.writeShellApplication {
            name = "repl";
            text = ''
              nix repl --file "$REPO_ROOT/repl.nix";
            '';
          };
        in
        pkgs.mkShell {
          packages =
            with pkgs;
            [
              inputs'.agenix.packages.agenix
              inputs'.nixos-anywhere.packages.nixos-anywhere
              figlet
              just
              jq
              nix-eval-jobs
              nixos-rebuild
              nix-output-monitor
              repl
              rage
              inputs'.dlang-nix.packages.dub
            ]
            ++ pkgs.lib.optionals (pkgs.stdenv.system == "x86_64-linux") [
              inputs'.dlang-nix.packages.dmd
              inputs'.dlang-nix.packages."ldc-binary-1_38_0"
            ];

          shellHook =
            ''
              export REPO_ROOT="$PWD"
              export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:${pkgs.curl.out}/lib"
              figlet -t "Metacraft Nixos Modules"
            ''
            + config.pre-commit.installationScript;
        };
    };
}
