# Backend Assumptions

The current implementation is intentionally Cachix-specific. Later milestones
should move these assumptions behind backend interfaces while keeping production
behavior unchanged until a replacement is proven.

## Current Cachix Coupling

- Cache URLs are derived from a Cachix cache name using
  `https://<cache>.cachix.org`.
- Cache status checks expect Cachix narinfo availability before activation.
- CI setup receives `CACHIX_CACHE`, `CACHIX_AUTH_TOKEN`, substituters, and
  trusted public keys.
- Build outputs are pushed with `cachix push`.
- Deploy requests are submitted with `cachix deploy activate`.
- The deploy spec shape is `agents.<name> = <store path>`.
- Target identity is the Cachix Deploy agent name.
- Target activation is delegated to `cachix-agent`.
- Activation is asynchronous from the workflow point of view.
- Target-side restore and switch errors are not represented as first-class
  workflow phases.
- Cache-push authentication and deploy activation authentication are separate
  tokens but both are Cachix concepts.

## Backend Abstractions Needed Later

- Cache address and trust material: cache name, substituter URL, public key, and
  upload endpoint.
- Closure prefill operation: push or copy a complete system closure and report
  count, total bytes, and failures.
- Cache availability probe: verify every required root and closure object is
  substitutable.
- Activation request: submit desired state for a target and record request id.
- Target apply transport: Cachix agent, SSH forced command, or target-side pull
  agent.
- Target status reader: obtain restore, switch, health-check, rollback, and
  final generation status.
- Credential model: upload token, activation token, SSH principal, manifest
  signing key, and target read/write status credentials.
- Retry and supersession policy: latest desired deployment wins per target.
