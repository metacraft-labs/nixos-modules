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
      final,
      self',
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

          shellHook =
            ''
              export REPO_ROOT="$PWD"
              figlet -t "Metacraft Nixos Modules"
            ''
            + config.pre-commit.installationScript;
        };

      devShells.all = import ./all.nix {
        pkgs = final;
        inherit self';
      };
      devShells.ci = import ./ci.nix {
        pkgs = final;
        inherit config;
      };
      devShells.nexus = import ./nexus.nix { pkgs = final; };
      devShells.jolt = import ./jolt.nix { pkgs = final; };
      devShells.zkm = import ./zkm.nix { pkgs = final; };
      devShells.zkwasm = import ./zkwasm.nix { pkgs = final; };
      devShells.sp1 = import ./sp1.nix { pkgs = final; };
      devShells.risc0 = import ./risc0.nix { pkgs = final; };
    };
}
