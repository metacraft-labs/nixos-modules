image := `nix eval --raw .#ci-image.imageRefUnsafe`

is-podman-available := `if command -v podman &> /dev/null; then echo true; else echo false; fi`
copy-to-docker := if is-podman-available == "true" { "copyToPodman" } else { "copyToDockerDaemon" }
docker-socket := if is-podman-available == "true" { "unix://${XDG_RUNTIME_DIR}/podman/podman.sock" } else { "unix:///var/run/docker.sock" }

show:
  @echo image: {{image}}
  @echo docker-socket: {{docker-socket}}
  @echo copy-to-docker: {{copy-to-docker}}
  @echo container engine: `docker --version 2>&1 | grep -v 'Switching default driver'`

image:
  nix run --offline .#ci-image.{{copy-to-docker}}

exec: image
  docker run -it {{image}}

act: image
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

  set -x
  DOCKER_HOST="{{docker-socket}}" \
  act workflow_dispatch \
    -W '.github/workflows/ci.yml' \
    -j ci \
    --var-file './.gh-vars.env' \
    --secret-file './.gh-secrets.env' \
    --concurrent-jobs 1 \
    --pull=false \
    -P self-hosted={{image}}
