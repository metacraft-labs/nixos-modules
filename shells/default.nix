{ ... }:
{
  perSystem =
    {
      pkgs,
      inputs',
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
            ];

          shellHook = ''
            export REPO_ROOT="$PWD"
            figlet -t "Metacraft Nixos Modules"
          '';
        };
    };
}
