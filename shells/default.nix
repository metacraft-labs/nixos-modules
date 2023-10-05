{
  pkgs,
  flake,
  inputs',
  ...
}: let
  repl = pkgs.writeShellApplication {
    name = "repl";
    text = ''
      nix repl --file "$REPO_ROOT/repl.nix";
    '';
  };
in
  pkgs.mkShellNoCC {
    packages = with pkgs; [
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
    ];

    shellHook = ''
      export REPO_ROOT="$PWD"
      figlet -w$COLUMNS "${flake.description}"
    '';
  }
