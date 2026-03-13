REPOMIX_OUT_DIR := env('REPOMIX_OUT_DIR', 'repomix')

image := `nix eval --raw .#ci-image.imageRefUnsafe`

is-podman-available := `if command -v podman &> /dev/null; then echo true; else echo false; fi`
copy-to-docker := if is-podman-available == "true" { "copyToPodman" } else { "copyToDockerDaemon" }
docker-socket := if is-podman-available == "true" { "unix://${XDG_RUNTIME_DIR}/podman/podman.sock" } else { "unix:///var/run/docker.sock" }
do-offline-nix-build := if env("CI", "false") == "false" { "--offline" } else { "" }

show:
  @echo image: {{image}}
  @echo docker-socket: {{docker-socket}}
  @echo copy-to-docker: {{copy-to-docker}}
  @echo container engine: `docker --version 2>&1 | grep -v 'Switching default driver'`

image:
  nix run --accept-flake-config {{do-offline-nix-build}} .#ci-image.{{copy-to-docker}}

exec: image
  docker run -it {{image}}

act workflow_name="ci": image
  #!/usr/bin/env bash
  set -euo pipefail
  if [ ! -f .gh-vars.env ]; then
    echo "ERROR: .gh-vars.env not found"
    echo "Create it with: echo 'CACHIX_CACHE=mcl-public-cache' > .gh-vars.env"
    exit 1
  fi
  if [ ! -f .gh-secrets.env ]; then
    echo "ERROR: .gh-secrets.env not found"
    echo "Create it with your CACHIX_AUTH_TOKEN: echo 'CACHIX_AUTH_TOKEN=...' > .gh-secrets.env"
    exit 1
  fi

  # Map workflow names to their files and job names
  case "{{workflow_name}}" in
    lint)
      workflow_file="reusable-lint"
      job_name="lint"
      ;;
    *)
      workflow_file="{{workflow_name}}"
      job_name="{{workflow_name}}"
      ;;
  esac

  set -x
  DOCKER_HOST="{{docker-socket}}" \
  act workflow_dispatch \
    -W ".github/workflows/${workflow_file}.yml" \
    -j "${job_name}" \
    --var-file './.gh-vars.env' \
    --secret-file './.gh-secrets.env' \
    --concurrent-jobs 1 \
    --pull=false \
    --input "runner=[\"self-hosted\"]" \
    -P self-hosted={{image}}

# Create repomix bundle of shared Terraform infrastructure docs and workflows
REPOMIX_TERRAFORM_SHARED_PATTERNS := replace("""
docs/Terraform-Agent-Development-Methodology.md
docs/Terraform-Testing.md
docs/Terraform-Shared-Infrastructure.status.org
.github/workflows/reusable-terraform*.yml
""", "\n", ",")

repomix-terraform-shared *args:
    mkdir -p {{REPOMIX_OUT_DIR}}
    repomix \
        . \
        --output {{REPOMIX_OUT_DIR}}/Terraform-Shared-Infrastructure.md \
        --style markdown \
        --header-text "Shared Terraform Infrastructure - Reusable CI Workflow, Dev Shell, and Policy Scripts" \
        --include "{{REPOMIX_TERRAFORM_SHARED_PATTERNS}}" \
        {{args}}
