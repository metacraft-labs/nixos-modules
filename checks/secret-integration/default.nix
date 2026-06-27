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
let
  # Build a minimal nixosConfiguration importing the mcl secrets modules.
  # `secretsModule` supplies the per-machine `mcl.secrets` definition so each
  # test machine can vary its services (including a deliberately broken one).
  mkMachine =
    secretsModule:
    inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        self.modules.nixos.mcl-host-info
        self.modules.nixos.mcl-secrets
        secretsModule
        {
          _module.args.dirs.modules = self + "/modules";
          mcl.host-info = {
            type = "server";
            isDebugVM = false;
            configPath = "./checks/test-machine";
            sshKey = builtins.readFile ./test-keys/.ssh/id_ed25519.pub;
          };
          mcl.secrets.extraKeys = [ (builtins.readFile ./test-keys/.ssh/extra_id_ed25519.pub) ];
          boot.loader.grub.enable = false;
          fileSystems."/".device = "none";
          fileSystems."/".fsType = "tmpfs";
          system.stateVersion = "25.11";
        }
      ];
    };
in
{
  # ---------------------------------------------------------------------------
  # 1.  Define nixosConfigurations to test the mcl.secrets and `mcl secret`
  #     command. Besides the primary machine, we add:
  #       - `broken-machine`: its `mcl.secrets.services` throws on evaluation,
  #         exercising the per-machine `tryEval` error path in `list` (the
  #         whole-fleet eval must not abort just because one machine fails).
  #       - `test-secret-machine-vm`: a valid machine whose name ends in
  #         `-vm`, exercising the VM filtering in `list` (hidden by default,
  #         shown with `--include-vms`).
  # ---------------------------------------------------------------------------
  flake.nixosConfigurations.test-secret-machine = mkMachine {
    mcl.secrets.services.test-svc = {
      encryptedSecretDir = self + "/checks/test-machine/secrets";
      secrets.password = { };
      secrets.api-key = { };
    };
    mcl.secrets.services.other-svc = {
      encryptedSecretDir = self + "/checks/test-machine/secrets";
      secrets.token = { };
    };
  };

  # A machine whose secrets fail to evaluate. `mcl secret list` forces
  # `attrNames services.<name>.secrets`, so a throwing `secrets` attrset
  # triggers the `builtins.tryEval` guard and yields an `__error__` marker
  # instead of aborting the whole-fleet evaluation.
  flake.nixosConfigurations.broken-machine = mkMachine {
    mcl.secrets.services.broken-svc.secrets = throw "intentional eval failure for broken-machine";
  };

  # A valid machine whose name ends in `-vm`; `list` hides it unless
  # `--include-vms` is passed.
  flake.nixosConfigurations.test-secret-machine-vm = mkMachine {
    mcl.secrets.services.vm-svc = {
      encryptedSecretDir = self + "/checks/test-machine/secrets";
      secrets.vm-secret = { };
    };
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
            pkgs.nix
            pkgs.jq
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
