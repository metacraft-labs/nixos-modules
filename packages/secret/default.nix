{
  inputs',
  pkgs,
  ...
}:
let
  agenix = inputs'.agenix.packages.agenix.override { ageBin = "${pkgs.rage}/bin/rage"; };
in
pkgs.writeShellApplication {
  name = "secret";
  text = ''
    #!/usr/bin/env bash
    set -euo pipefail

    machine=""
    configurationType="nixos"
    service=""
    secret=""
    vm=false
    reEncrypt=false
    reEncryptAll=false
    export RULES=""
    secretsFolder=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --machine=*) machine="''${1#*=}";;
            --configuration-type=*) configurationType="''${1#*=}";;
            --secrets-folder=*) secretsFolder="''${1#*=}";;
            --service=*) service="''${1#*=}";;
            --secret=*) secret="''${1#*=}";;
            --vm) vm=true;;
            -r) reEncrypt=true;;
            --re-encrypt-all) reEncryptAll=true;;
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
        --secrets-folder - pecifies the location where secrets are saved.\n\
        By default, secrets are stored in /(folder of the machine)/secrets/service/\n\
        if this directory exists, unless otherwise specified.
        --machine - Machine for which you want to create a secret.\n\
        --configuration-type - Type of configurations, either \`nixos\` or \`nix-darwin\`\n\
        --service - Service for which you want to create a secret.\n\
        --secret  - Secret you want to encrypt.\n\
        --vm - Make secret for the vmVariant.\n\
        -r - Re-encrypt the secret."
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
        shift
    done

    case "$configurationType" in
      (nixos)
        configurationsAttr="nixosConfigurations"
        ;;
      (nix-darwin)
        configurationsAttr="darwinConfigurations"
        ;;
      (*)
        echo "Invalid configuration type $configurationType"
        exit 1
        ;;
    esac

    if [[ "$reEncryptAll" == true && -z "$machine" ]]; then
      echo "You must specify machine"
      exit 1
    elif [[ "$reEncrypt" == true && (-z "$machine" || -z "$service") ]]; then
      echo "You must specify machine and service"
      exit 1
    elif [[ "$reEncrypt" == false && "$reEncryptAll" == false && (-z "$machine" || -z "$service" || -z "$secret") ]]; then
      echo "You must specify machine, service, and secret"
      exit 1
    fi

    machineFolder="$(nix eval ".#$configurationsAttr.$machine.config.mcl.host-info.configPath" | sed 's|^\([^/]*/\)\{4\}||; s|"||g')"

    if [ "$secretsFolder" == "" ]; then
      secretsFolder="$machineFolder/secrets/$service"
    fi

    if [[ "$vm" == true && "$reEncryptAll" == false ]]; then
        if [[ "$configurationType" != "nixos" ]]; then
            echo "Cannot use \`vm\` with \`configuration-type\` $configurationType" 1>&2
            exit 1
        fi
        RULES="$(nix eval --raw ".#nixosConfigurations.$machine-vm.config.virtualisation.vmVariant.mcl.secrets.services.$service.nix-file")"
        secretsFolder="./modules/default-vm-config/secrets/$service"
    elif [ "$reEncryptAll" == false ]; then
        RULES="$(nix eval --raw ".#$configurationsAttr.$machine.config.mcl.secrets.services.$service.nix-file")"
    fi

    if [ "$reEncryptAll" == true ]; then
      for s in $(nix eval ".#$configurationsAttr.$machine.config.mcl.secrets.services" --apply builtins.attrNames | tr -d '[]"'); do
        service=$s
        secretsFolder="$machineFolder/secrets/$service"
        echo "Re-encripting secrets for service $s"
        if [ "$vm" == true ]; then
          RULES="$(nix eval --raw ".#$configurationsAttr.$machine-vm.config.mcl.secrets.services.$service.nix-file")"
        else
          RULES="$(nix eval --raw ".#$configurationsAttr.$machine.config.mcl.secrets.services.$service.nix-file")"
        fi
        (
          cd "$secretsFolder"
          "${agenix}/bin/agenix -r"
        )
      done
    else
      (
        cd "$secretsFolder"
        if [ "$reEncrypt" == true ]; then
          "${agenix}/bin/agenix" -r
        else
          "${agenix}/bin/agenix" -e "$secret.age"
        fi
      )
    fi
  '';
}
