{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      checks.terraform-ci-matrix =
        pkgs.runCommand "terraform-ci-matrix-test"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.coreutils
              pkgs.findutils
              pkgs.jq
              pkgs.python3
            ];
          }
          ''
            export TERRAFORM_CI_MATRIX_SCRIPT=${../terraform/ci/terraform-ci-matrix}
            export TERRAFORM_CI_MATRIX_SCHEMA=${../terraform/ci/metadata.schema.json}
            export TERRAFORM_CI_MATRIX_BASH=${pkgs.bash}/bin/bash

            ${pkgs.bash}/bin/bash ${../terraform/ci/tests/test-matrix.sh}
            ${pkgs.bash}/bin/bash ${../terraform/ci/tests/test-matrix-mutations.sh}
            touch "$out"
          '';
    };
}
