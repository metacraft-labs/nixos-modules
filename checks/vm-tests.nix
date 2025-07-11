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
      ...
    }:
    {
      checks = {
        "healthcheck-test-01" = pkgs.testers.runNixOSTest {
          name = "healthcheck-test-01";
          nodes = {
            machine =
              { config, pkgs, ... }:
              {

                imports = [
                  self.modules.nixos.machine_healthcheck
                ];

              };
            testScript =
              { nodes, ... }:
              ''
                machine.wait_for_unit("default.target")
              '';
          };
        };
      };
    };
}
