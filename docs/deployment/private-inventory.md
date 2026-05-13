# M0 Private Infrastructure Inventory

This file intentionally records concrete private details observed during the M0
audit. Do not copy these names into generic deployment docs, schemas, examples,
or reusable agent instructions.

## Observed Private Details

- Primary named production server in current docs and commands: `solunska`.
- Concrete machine configuration path observed: `machines/server/solunska-server`.
- GPU server naming pattern observed: `gpu-server-002`.
- Existing Attic service domain: `cache.metacraft-labs.com`.
- Existing Cachix Deploy workspace/cache reference in operator docs:
  `metacraft-private-infrastructure`.
- Current agent token file path for Cachix Deploy: `/etc/cachix-agent.token`.
- Current Cachix Deploy metrics service workspace:
  `metacraft-private-infrastructure`.
- Current Cachix Deploy metrics token secret:
  `cachix-deploy-metrics/auth-token`.

## Current Private Deploy Prior Art

- `infra/Justfile` has `deploy-solunska`, which delegates to direct remote
  switch for the Solunska server.
- `infra/Justfile` has `deploy-machine-cachix`, which writes a per-machine
  Cachix Deploy spec and runs `cachix deploy activate --agent <machine>`.
- `infra/Justfile` has `push-cachix-deploy-spec` and `deploy-cachix-spec` for
  multi-agent Cachix Deploy specs.
- `infra/services/cachix-deploy/default.nix` enables `services.cachix-agent`
  and writes the Cachix agent token to `/etc/cachix-agent.token`.
- `infra/services/monitoring/cachix-deploy-metrics/default.nix` enables
  `services.cachix-deploy-metrics`, binds it on `0.0.0.0`, reads its auth token
  from the age secret path for `cachix-deploy-metrics/auth-token`, sets the
  Cachix workspace, and discovers agent names from server machine directories.
- `infra/services/attic/default.nix` configures Attic behind nginx at
  `cache.metacraft-labs.com`, permits large uploads only from the Tailnet, and
  uses an age-managed environment file.
- `infra/modules/default-server-config/virtualisation.nix` enables Incus on
  default servers, but no dedicated Incus/LXC rehearsal CLI with `--check-env`,
  `--check-runtime`, or `--dry-run` was found.
