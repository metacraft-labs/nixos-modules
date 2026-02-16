# Integration test for `mcl secret` — verifies edit, re-encrypt, and
# re-encrypt-all against a minimal nixosConfiguration that imports the
# mcl secrets module.
#
# Run:  nix run .#checks.x86_64-linux.secret-integration
{
  lib,
  inputs,
  self,
  ...
}:
{
  # ---------------------------------------------------------------------------
  # 1.  Define a nixosConfiguration to test the mcl.secrets and `mcl secret`
  #     command.
  # ---------------------------------------------------------------------------
  flake.nixosConfigurations.test-secret-machine = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      self.modules.nixos.mcl-host-info
      self.modules.nixos.mcl-secrets
      {
        _module.args.dirs.modules = self + "/modules";
        mcl.host-info = {
          type = "server";
          isDebugVM = false;
          configPath = self + "/checks/test-machine";
          sshKey = builtins.readFile ./test-keys/id_ed25519.pub;
        };
        mcl.secrets = {
          extraKeys = [ (builtins.readFile ./test-keys/extra_id_ed25519.pub) ];
          services.test-svc = {
            encryptedSecretDir = self + "/checks/test-machine/secrets";
            secrets.password = { };
            secrets.api-key = { };
          };
          services.other-svc = {
            encryptedSecretDir = self + "/checks/test-machine/secrets";
            secrets.token = { };
          };
        };
        boot.loader.grub.enable = false;
        fileSystems."/".device = "none";
        system.stateVersion = "25.11";
      }
    ];
  };

  # ---------------------------------------------------------------------------
  # 2.  A runnable test script that exercises `mcl secret` subcommands.
  # ---------------------------------------------------------------------------
  perSystem =
    {
      self',
      pkgs,
      ...
    }:
    let
      inherit (pkgs.stdenv.hostPlatform) isLinux;
    in
    {
      checks = lib.optionalAttrs isLinux {
        secret-integration = pkgs.writeShellApplication {
          name = "test-mcl-secret";
          runtimeInputs = [
            self'.packages.mcl
            pkgs.age
            pkgs.openssh
            pkgs.gitMinimal
            pkgs.nix
          ];
          text = "bash ${
            pkgs.replaceVars ./test-mcl-secret.sh {
              TEST_KEYS_DIR = "${./test-keys}";
            }
          }";
        };
      };
    };
}
