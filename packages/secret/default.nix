{
  inputs',
  pkgs,
  ...
}: let
  agenix = inputs'.agenix.packages.agenix.override {ageBin = "${pkgs.rage}/bin/rage";};
in
  pkgs.writeShellApplication {
    name = "secret";
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail

      machine=""
      service=""
      secret=""
      vm=""
      export RULES=""

      while [[ $# -gt 0 ]]; do
          case "$1" in
              --machine=*)
                  machine="''${1#*=}"
                  ;;
              --service=*)
                  service="''${1#*=}"
                  ;;
              --secret=*)
                  secret="''${1#*=}"
                  ;;
              --vm)
                  vm="true"
                  ;;
              --help)
                  echo -e "NAME\n\
          secret\n\n\
      SYNOPSIS\n\
          secret [OPTION]\n\n\
      EXAMPLE\n\
          secret --machine=mymachine --service=myservice --secret=mysecret\n\n\
      DESCRIPTION\n\
          Secret is the command made for nix repos to get rid of the secret.nix when\n\
          you are using agenix. Secret must be used with mcl-secrets and mcl-host-info\n\
          modules from nixos-modules repository to work properly.\n\n\
      OPTIONS\n\
          --machine - Machine for which you want to create a secret.\n\
          --service - Service for which you want to create a secret.\n\
          --secret  - Secret you want to encrypt.\n\
          --vm - Make secret for the vmVariant."
              exit 0
                  ;;
              *)
                  echo "Unknown option: $1"
                  exit 1
                  ;;
          esac
          shift
      done

      if [[ -z "$machine" || -z "$service" || -z "$secret" ]]; then
          echo "You must specify machine, service, and secret"
          exit 1
      fi

      if [ "$vm" = "true" ]; then
          RULES="$(nix eval --raw ".#nixosConfigurations.$machine-vm.config.virtualisation.vmVariant.mcl.secrets.services.$service.nix-file")"
      else
          RULES="$(nix eval --raw ".#nixosConfigurations.$machine.config.mcl.secrets.services.$service.nix-file")"
      fi
      "${agenix}/bin/agenix" -e "$secret.age"
    '';
  }
