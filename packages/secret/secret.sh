#!@shell@

export PATH="@binPath@:$PATH"

read -r -d '' HELP_MSG << EOM
NAME\n\
    secret\n\n\
SYNOPSIS\n\
    secret [OPTION]\n\n\
EXAMPLE\n\
    secret --machine=mymachine --service=myservice --secret=mysecret\n\n\
DESCRIPTION\n\
    Secret is the command made for nix repos to get rid of the secret.nix when\n\
    you are using agenix. Secret must be used with mcl-secrets and mcl-host-info\n\
    modules from nixos-modules repository to work properly.\n\n\

    By default, secrets are stored in machines/\${HOST}/secrets/service/\n\
    if this directory exists, unless otherwise specified.
OPTIONS\n\
    -v|--verbose          - Produce more verbose log messages.\n\
    -f| --secrets-folder  - pecifies the location where secrets are saved.\n\
    -m|--machine          - Machine for which you want to create a secret.\n\
    -S|--service          - Service for which you want to create a secret.\n\
    -s|--secret           - Secret you want to encrypt.\n\
    -V|--vm               - Make secret for the vmVariant.\n\
    -r|--re-encrypt       - Re-encrypt the secret.\n\
    -a|--re-encrypt-all   - Re-encrypt all secrets."
EOM

set -euo pipefail

function nix_eval_machine() {
  target="${1}"
  shift
  if [[ "${vm}" == true ]]; then
    subPath='virtualisation.vmVariant'
  else
    subPath='config'
  fi
  nix eval ${@} ".#nixosConfigurations.${machine}.${subPath}.${target}"
}

function machine_type() {
  [[ "${vm}" == true ]] && echo "vm" || echo "server"
}

function agenix_wrapper() {
  if [[ -z "${secretsFolder}" ]]; then
    local secretsFolder=$(
      nix_eval_machine mcl.secrets.services.${service}.encryptedSecretDir --raw \
        | sed -r 's#/nix/store/[a-z0-9]+-(source|secrets)/?##'
    )
    # If path has no subfolders it must be that of defaults.
    if [[ -z "${secretsFolder}" ]]; then
      local secretsFolder="modules/default-$(machine_type)-config/secrets"
    fi
  fi
  export RULES="$(nix_eval_machine "mcl.secrets.services.${service}.nix-file" --raw)"
  # Provide custom paths to Age identity files.
  if [[ -n "$AGE_IDENTITIES" ]]; then
    export agenixArgs="-i $(echo "${AGE_IDENTITIES}" | sed -z '$ s/\n$//' | tr '\n' ' ' | sed -e 's/ / -i /g')"
  fi
  if [[ "${verbose}" == 'true' ]]; then
    echo -e "{\n  cd ${secretsFolder}/${service};\n  export RULES=${RULES};\n  agenix ${agenixArgs} ${@};\n}" >&2
  fi
  ( # Block necessary to limit scope of directory change.
    cd "${secretsFolder}/${service}";
    exec agenix ${agenixArgs} ${@}
  )
}

machine=""
service=""
secret=""
verbose=false
vm=false
reEncrypt=false
reEncryptAll=false
secretsFolder=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose)           verbose=true;;
        -m|--machine=*)         machine="${1#*=}";;
        -f|--secrets-folder=*)  secretsFolder="${1#*=}";;
        -S|--service=*)         service="${1#*=}";;
        -s|--secret=*)          secret="${1#*=}";;
        -V|--vm)                vm=true;;
        -r|--re-encrypt)        reEncrypt=true;;
        -a|--re-encrypt-all)    reEncryptAll=true;;
        -h|--help)              echo -e "${HELP_MSG}"; exit 0;;
        *)                      echo "Unknown option: $1"; exit 1;;
    esac
    shift
done

if [[ "${reEncryptAll}" == true && -z "${machine}" ]]; then
  echo "You must specify machine"
  exit 1
elif [[ "${reEncrypt}" == true && (-z "${machine}" || -z "${service}") ]]; then
  echo "You must specify machine and service"
  exit 1
elif [[ "${reEncrypt}" == false && "${reEncryptAll}" == false && (-z "${machine}" || -z "$service" || -z "$secret") ]]; then
  echo "You must specify machine, service, and secret"
  exit 1
fi

if [[ "${reEncryptAll}" == true ]]; then
  for service in $(nix_eval_machine "mcl.secrets.services" --apply builtins.attrNames --json | jq -r '.[]'); do
    echo "Re-encripting secrets for: ${service}"
    agenix_wrapper -r
  done
else
  if [[ "${reEncrypt}" == true ]]; then
    agenix_wrapper -r
  else
    agenix_wrapper -e "${secret}.age"
  fi
fi
