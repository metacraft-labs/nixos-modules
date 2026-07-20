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
