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
              openssl
              zlib
              pkg-config
              repl
              rage
              dub
              dub-to-nix
              ldc
              act
            ]
            ++ pkgs.lib.optionals (pkgs.stdenv.system == "x86_64-linux") [
              dmd
            ];

          shellHook = ''
            export REPO_ROOT="$PWD"
            figlet -t "Metacraft Nixos Modules"
          ''
          + config.pre-commit.installationScript;
        };
    };
}
