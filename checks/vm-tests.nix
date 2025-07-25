{
  lib,
  inputs,
  self,
  ...
}:
{
  perSystem =
    {
      inputs',
      self',
      pkgs,
      system,
      ...
    }:
    {
      checks = {
        "healthcheck-test-01" = pkgs.testers.runNixOSTest {
          name = "healthcheck-test-01";
          node.specialArgs = {
            inherit self system lib;
          };
          testScript = ''
            machine.start()
            machine.wait_for_unit("default.target")
          '';
          nodes.machine =
            { pkgs, ... }:
            {
              imports = [
                ../machines/modules/base.nix
                ../machines/modules/healthcheck.nix
              ];
            };

        };
      };
    };
}
