# Company-agnostic standalone GitHub Actions **secrets** engine.
#
# Unlike the full governance engine (terraform/github/governance.nix, which is
# the Layer-0 bootstrap root and manages repos/teams/branch-protection alongside
# a few bootstrap secrets), this is a NORMAL terraform/ root that manages ONLY
# repository Actions secrets from the rendered, GitHub-encrypted payloads. It
# rides the standard terraform-ci matrix (credential_mode = github-app), so any
# secret change is plan-comment-apply like every other resource — per the
# principle that the bootstrap root holds only Layer-0, everything else is normal.
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

  resourceKey =
    value: "secret_${replaceStrings [ "/" ":" "." ] [ "_" "_" "_" ] value}";

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
