# Company-agnostic standalone GitHub Actions **secrets** engine.
#
# Unlike the full governance engine (terraform/github/governance.nix, which maps
# an org inventory of repos/teams/branch-protection), this engine manages ONLY
# Actions secrets from rendered, GitHub-encrypted payloads. Two uses, following
# the principle that the bootstrap root holds only Layer 0 and everything else
# is normal:
#
#   * a NORMAL terraform/ root for ordinary per-repo application secrets, riding
#     the standard terraform-ci matrix (credential_mode = github-app) so any
#     secret change is plan-comment-apply like every other resource; and
#   * the small Layer-0 bootstrap/ root holding only the chicken-and-egg secrets
#     the pipeline itself authenticates with (the CI App credentials and the CI
#     agenix key), which the pipeline must not be able to rewrite.
#
# Consumers supply their reviewed manifest + rendered managedDoc/payloadDoc; this
# emits the github provider, the S3 backend, and one github_actions_secret per
# managed, rendered, repository-scoped payload. Attribute shape matches
# governance.nix exactly (key_id + value_encrypted) so state is compatible.
{
  githubOwner,
  stateKey,
  githubProviderVersion ? "~> 6.0",
  managedDoc ? {
    version = 1;
    providerIds = [ ];
  },
  payloadDoc ? {
    version = 1;
    payloads = { };
  },
}:
let
  inherit (builtins)
    attrValues
    elem
    filter
    listToAttrs
    map
    replaceStrings
    ;

  resourceKey = value: "secret_${replaceStrings [ "/" ":" "." ] [ "_" "_" "_" ] value}";

  managedIds = managedDoc.providerIds or [ ];
  payloads = payloadDoc.payloads or { };

  # Only payloads that are (a) enforced-managed, (b) repository-scoped
  # github_actions_secret. Organization/environment/dependabot secrets and the
  # Layer-0 bootstrap secrets stay with their respective roots.
  wanted = filter (
    p:
    (elem p.providerId managedIds)
    && (p.providerResource or "") == "github_actions_secret"
    && (p.scope or "repository") == "repository"
  ) (attrValues payloads);

  repositorySecretResources = listToAttrs (
    map (p: {
      name = resourceKey p.providerId;
      value = {
        repository = p.repository;
        secret_name = p.name;
        key_id = p.keyId;
        value_encrypted = p.valueEncrypted;
      };
    }) wanted
  );
in
{
  terraform = {
    required_version = ">= 1.8.0";
    backend.s3 = { };
    required_providers = {
      github = {
        source = "integrations/github";
        version = githubProviderVersion;
      };
    };
  };

  # Token comes from the github-app credential mode (GITHUB_TOKEN in the env),
  # minted per-run by the reusable-terraform-ci workflow. No token in config.
  provider.github = [ { owner = githubOwner; } ];

  resource.github_actions_secret = repositorySecretResources;

  output.managed_secret_count = {
    value = builtins.length wanted;
    description = "Number of repository Actions secrets managed by this root.";
  };
}
