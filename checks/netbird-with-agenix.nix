top@{ config, ... }:
{
  perSystem =
    {
      pkgs,
      lib,
      ...
    }:
    let
      flake = top.config.flake;
      system = lib.nixosSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          flake.modules.nixos."netbird-with-agenix"
          {
            networking.hostName = "netbird-test";
            services."netbird-with-agenix" = {
              enable = true;
              clientName = "default";
              setupKeySecretFile = pkgs.writeText "netbird-test-setup-key.age" "AGE-ENCRYPTED-FIXTURE";
            };
          }
        ];
      };
      service = system.config.systemd.services.netbird-default-login;
      script = service.script;
      restart = service.serviceConfig.Restart or "";
      failures = lib.flatten [
        (lib.optional (lib.hasInfix "Connected\\|NeedsLogin" script) "login script still uses broad Connected|NeedsLogin grep")
        (lib.optional (
          !lib.hasInfix "^Daemon status:[[:space:]]*NeedsLogin" script
        ) "login script does not anchor NeedsLogin to daemon status")
        (lib.optional (
          !lib.hasInfix "^Management:[[:space:]]*Connected" script
        ) "login script does not anchor connected state to Management")
        (lib.optional (
          !lib.hasInfix "NetBird login did not reach a connected state" script
        ) "login script does not fail when final connected state is not reached")
        (lib.optional (restart != "on-failure") "login service does not retry on failure")
      ];
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        netbird-with-agenix-login-script = pkgs.runCommand "netbird-with-agenix-login-script" { } ''
          ${lib.concatMapStringsSep "\n" (failure: ''
            echo ${lib.escapeShellArg failure} >&2
            exit 1
          '') failures}
          touch "$out"
        '';
      };
    };
}
