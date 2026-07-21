# Shared GitHub Terraform library

Company-agnostic Terranix helpers for managing GitHub via Terraform/OpenTofu.
Consumers supply their own data (repositories, policy, credentials); this
directory ships only the reusable logic. Pairs with the reusable Terraform CI
workflow (`.github/workflows/reusable-terraform-ci.yml`) and the plan policy in
`scripts/tofu-plan-policy.py`.

## `branch-protection.nix` — branch-protection rulesets

Renders `github_repository_ruleset` resources from a **branch-protection
policy** plus per-repository configuration. It standardizes on repository
rulesets (not classic branch protection), which is what lets a single
wildcard rule protect _every_ branch.

The policy is org-agnostic and best kept as shared data (for Metacraft this is
`metacraft-dev-guidelines/policies/branch-protection-policy.json`, consumed as a
`flake = false` input — no flake needed in the source repo). The policy fixes
_which branch classes gate on CI_; the caller passes each repository's concrete
required-check contexts.

### Usage

```nix
let
  branchProtection = import ./branch-protection.nix { inherit lib; };
in
branchProtection.mkRulesets {
  policy = builtins.fromJSON (builtins.readFile
    "${inputs.dev-guidelines}/policies/branch-protection-policy.json");
  repositories = {
    "my-product" = {
      repoClass = "product";                      # product | spec | infra | product-adapted-fork
      checks = {
        dev = [ "ci / build" "ci / test" ];       # concrete required-check contexts
        stable = [ "release" ];
      };
    };
    "my-infra" = {
      repoClass = "infra";
      checks.live = [ "terraform / plan" "lint" ];
    };
  };
}
```

`mkRulesets` returns `{ resource.github_repository_ruleset = { ... }; }`,
mergeable into a Terranix root that also declares the `github` provider.

### What it emits

- **One baseline ruleset per repository** targeting `~ALL` branches, blocking
  force pushes and deletions (`non_fast_forward` / `deletion`) — this is the
  "every branch protected from force push" universal rule.
- **One ruleset per applicable branch class** (matched by `repoClass`) that
  gates on CI: `required_status_checks` with the repo's contexts, plus
  `pull_request` review when the class requires it. Classes that require
  neither (e.g. `agents`) emit no extra ruleset and rely on the baseline — so
  `agents` is protected from force-push but does **not** gate on CI, matching
  the branching policy.

### Validate offline

```bash
nix-instantiate --eval --strict --json example/config.nix > example/config.tf.json
cd example && tofu init -backend=false && tofu validate
```

The example is validated against the real `integrations/github` provider
schema (`tofu validate` → `Success`). A real consumer swaps the fixture for the
shared policy file and its own repository list.

## `tf-bootstrap.nix` — CI-enabling GitHub Layer-0 root

The GitHub counterpart of the AWS `tf-bootstrap.nix`: a value-independent module
rendering the minimal GitHub facts the CI/CD pipeline depends on to run — the
reviewer team, the deploy Environment, the AWS OIDC role-ARN Actions variables,
the Terraform safety labels, and branch protection for the deploy branch. Each
consumer's `bootstrap/github/<name>/default.nix` is a thin caller:

```nix
{ ... }:
import "${inputs.nixos-modules}/terraform/github/tf-bootstrap.nix" {
  awsAccountId = "…";
  namePrefix = "…-prod";               # state key derives: bootstrap/github/<namePrefix>.tfstate
  githubOwner = "…";                   # githubRepo defaults to "infra", protectedBranch to "live"
  reviewerTeam = {
    name = "infra";
    slug = "infra";
    description = "Maintainers for … infrastructure.";
    initialMaintainer = "…";           # the bootstrap admin username
  };
  requiredStatusCheckContexts = [ "…" ];   # the repo's real CI check contexts
}
```

Broader org governance (repositories, memberships, org secrets) is the separate
[`governance.nix`](#governancenix--github-governance-engine) engine — this module
is only the per-repo settings that unblock the pipeline. See
[`tf-bootstrap.example.nix`](./tf-bootstrap.example.nix) and
[`tests/test-bootstrap-render.sh`](./tests/test-bootstrap-render.sh). Verifying an
extraction is a no-op is the same `nix eval --json | jq -S` diff as the AWS module.

## `governance.nix` — GitHub governance engine

Maps a declarative **governance model** (repositories, memberships, teams,
branch protection, Environments, Actions permissions/variables, issue labels)
plus a **secret manifest** and the GitHub-encrypted **payloads** rendered by
`github-governance-secrets-render` into `github_*` Terraform resources, and
exposes the rich `output` block the bootstrap helper reads. It is the engine
behind each org's `bootstrap/github/<name>-governance-prod` root.

Everything company-specific is a parameter; the machinery (name sanitizers,
list→resource mappers, the secret-manifest validation that throws on unknown or
missing managed/payload ids) is org-agnostic. A consumer's `root.nix` becomes a
thin caller that resolves its local generated documents and passes its own data:

```nix
{ managedFile ? ./secrets/managed.generated.nix, payloadFile ? ./secrets/payloads.generated.nix, ... }:
{ ... }:
import "${inputs.nixos-modules}/terraform/github/governance.nix" {
  awsAccountId = "…";
  awsRegion = "us-east-1";
  githubOwner = "…";                                   # githubAccessCheckRepository defaults to <owner>/infra
  githubBootstrapStateKey = "bootstrap/github/…-governance-prod.tfstate";
  governance = import ./governance.nix;                 # the org inventory model (per-company data)
  manifest = import ./secrets/manifest.nix;             # the secret registry (per-company data)
  managedDoc = if builtins.pathExists managedFile then import managedFile else { providerIds = [ ]; };
  payloadDoc = if builtins.pathExists payloadFile then import payloadFile else { payloads = { }; };
}
```

The `governance` and `manifest` documents stay in each infra repo — they are the
org's inventory and secret facts. Only the mapper is shared. See
[`governance.example.nix`](./governance.example.nix) for a minimal renderable
model and [`tests/test-render.sh`](./tests/test-render.sh) for the offline check.

Verifying an extraction is a no-op is the same as for the AWS module: render the
original `root.nix` and the thin caller with identical data and `diff` the
`nix eval --json | jq -S` output — empty diff == zero plan diff == safe.

## Import-phase tooling

Company-agnostic tools for adopting an existing GitHub org into Terraform (the
one-time [import phase](../../docs/Terraform-Import-Phase.md)). None hardcode an
org — owner / root-config / repo-root are parameters.

- **`github-inventory`** — read-only inventory of the org (repos, branch
  protection, Environments, Actions vars/permissions, labels, team grants) into
  `.result/` as raw JSON + a redacted `inventory.md`. Secret values are never
  read. `--owner <org>` (or `GITHUB_OWNER`), `--all-repos`.
- **`github-governance-import-blocks`** — credential-free generator that reads a
  repo's reviewed `bootstrap/<root-config>/governance.nix` and emits OpenTofu
  `import {}` blocks. `--owner`, `--root-config`, `--root-dir`, `--scope`. Output
  stays under `.result/` and is never committed.
- **`github-governance-import-ci`** — the CI harness (plan / gated apply) that
  runs the generator + plan and **refuses any non-import action** (≥1 import, 0
  add/change/destroy/replace; typed confirm for apply). Driven by env
  (`GOVERNANCE_ROOT_CONFIG`, `GOVERNANCE_ROOT`, `GOVERNANCE_RESULT_ROOT`,
  `BACKEND_CONFIG_FILE`, `GOVERNANCE_TOKEN_PATH`).

## `github-bootstrap` — GitHub Layer-0 driver

Org-admin driver for the GitHub side of Layer 0: the CI-enabling repo settings
(the `production` Environment, deploy-branch protection, OIDC role-ARN Actions
variables, CODEOWNERS) and the org governance root. Human-applied, out-of-band —
never through the pipeline it enables, because the pipeline depends on these
settings and secrets to run.

Subcommands: `plan` / `apply` / `outputs`, plus the targeted
`governance-app-secrets-{plan,apply}` (writes the two `GH_GOVERNANCE_APP_*` org
secrets so governance CI can authenticate). Like `aws-bootstrap` it guards the
AWS account owning the shared S3 state backend via STS, verifies the GitHub
token can administer the target repo, and hardcodes nothing company-specific:

```bash
github-bootstrap plan github/<name> --root-dir <repo>
```

The backend file derives from the config (`backends/<config-slug>.hcl`,
overridable via `GITHUB_BOOTSTRAP_BACKEND_FILE`); the org for the governance
secret targets is read from the rendered outputs.
