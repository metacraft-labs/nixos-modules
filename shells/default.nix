{
  self',
  pkgs,
  inputs',
  ...
}:
let
  repl = pkgs.writeShellApplication {
    name = "repl";
    text = ''
      nix repl --file "$REPO_ROOT/repl.nix";
    '';
  };
in
pkgs.mkShell {
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
    inputs'.dlang-nix.packages.dmd
    inputs'.dlang-nix.packages.dub
    act
    self'.checks.pre-commit-check.enabledPackages
  ];

  shellHook =
    ''
      export REPO_ROOT="$PWD"
      figlet -t "Metacraft Nixos Modules"
    ''
    + self'.checks.pre-commit-check.shellHook;
}
