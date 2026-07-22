# Company-agnostic GitHub governance engine.
#
# Maps a declarative governance model (repositories, teams, memberships, branch
# protection, Actions variables, issue labels) plus a secret manifest and the
# GitHub-encrypted payloads rendered by `github-governance-secrets-render` into
# `github_*` Terraform resources, and exposes the same rich `output` block the
# bootstrap helper reads. Nothing company-specific is hardcoded: the consumer
# supplies its own `governance` / `manifest` data and the resolved managed and
# payload documents. See `terraform/github/README.md` for the thin-caller shape.
{
  awsAccountId,
  awsRegion,
  githubOwner,
  githubAccessCheckRepository ? "${githubOwner}/infra",
  githubBootstrapStateKey,
  governance,
  manifest,
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
    attrNames
    concatStringsSep
    elem
    filter
    foldl'
    hasAttr
    length
    listToAttrs
    map
    replaceStrings
    sort
    throw
    ;

  optionalAttrs = cond: attrs: if cond then attrs else { };
  optionalField = attrs: name: if hasAttr name attrs then { ${name} = attrs.${name}; } else { };
  resourceKey = value: "secret_${replaceStrings [ "/" ":" "." ] [ "_" "_" "_" ] value}";
  governanceResourceKey =
    value:
    replaceStrings
      [
        "/"
        ":"
        "."
        "-"
        " "
        "|"
        "("
        ")"
        ","
      ]
      [
        "_"
        "_"
        "_"
        "_"
        "_"
        "_"
        "_"
        "_"
        "_"
      ]
      value;
  repositoryResourceName = repository: governanceResourceKey "repo:${repository}";
  teamDataName = teamSlug: governanceResourceKey "team:${teamSlug}";
  terraformRef = ref: "\${${ref}}";
  listToResourceAttrs =
    values: keyFn: valueFn:
    listToAttrs (
      map (value: {
        name = governanceResourceKey (keyFn value);
        value = valueFn value;
      }) values
    );

  requestedPayloads = payloadDoc.payloads or { };

  eligibleSecrets = filter (secret: secret.manageWithTerraform or false) manifest.secrets;
  manifestProviderIds = map (secret: secret.providerId) eligibleSecrets;
  managedProviderIds = managedDoc.providerIds or [ ];
  unknownManagedIds = filter (providerId: !(elem providerId manifestProviderIds)) managedProviderIds;
  unknownPayloadIds = filter (providerId: !(elem providerId manifestProviderIds)) (
    attrNames requestedPayloads
  );
  missingPayloadIds = filter (providerId: !(hasAttr providerId requestedPayloads)) managedProviderIds;
  manifestOrganizationSecrets = filter (secret: secret.scope == "organization") eligibleSecrets;
  manifestRepositorySecrets = filter (secret: secret.scope == "repository") eligibleSecrets;
  manifestEnvironmentSecrets = filter (secret: secret.scope == "environment") eligibleSecrets;
  managedSecrets =
    if unknownManagedIds != [ ] then
      throw "unknown managed GitHub secret ids: ${concatStringsSep ", " unknownManagedIds}"
    else
      filter (secret: elem secret.providerId managedProviderIds) eligibleSecrets;
  secretPayloads =
    if unknownPayloadIds != [ ] then
      throw "unknown GitHub secret payload ids: ${concatStringsSep ", " unknownPayloadIds}"
    else if missingPayloadIds != [ ] then
      throw "missing GitHub secret payload ids: ${concatStringsSep ", " missingPayloadIds}"
    else
      requestedPayloads;

  organizationSecrets = filter (secret: secret.scope == "organization") managedSecrets;
  repositorySecrets = filter (secret: secret.scope == "repository") managedSecrets;
  environmentSecrets = filter (secret: secret.scope == "environment") managedSecrets;

  withPayload =
    secret: attrs:
    let
      payload = secretPayloads.${secret.providerId};
    in
    attrs
    // {
      key_id = payload.keyId;
      value_encrypted = payload.valueEncrypted;
    };

  organizationSecretResources = listToAttrs (
    map (secret: {
      name = resourceKey secret.providerId;
      value = withPayload secret (
        {
          secret_name = secret.name;
          visibility = secret.visibility;
        }
        // optionalAttrs (secret ? selectedRepositoryIds) {
          selected_repository_ids = secret.selectedRepositoryIds;
        }
      );
    }) organizationSecrets
  );

  repositorySecretResources = listToAttrs (
    map (secret: {
      name = resourceKey secret.providerId;
      value = withPayload secret {
        repository = secret.repository;
        secret_name = secret.name;
      };
    }) repositorySecrets
  );

  environmentSecretResources = listToAttrs (
    map (secret: {
      name = resourceKey secret.providerId;
      value = withPayload secret {
        repository = secret.repository;
        environment = secret.environment;
        secret_name = secret.name;
      };
    }) environmentSecrets
  );

  sortedRepoNames = sort (a: b: a < b) (map (repo: repo.name) governance.repositories);

  repositoryResources = listToResourceAttrs governance.repositories (repo: "repo:${repo.name}") (
    repo:
    {
      name = repo.name;
      visibility = repo.visibility;
      has_issues = repo.hasIssues;
      has_projects = repo.hasProjects;
      has_wiki = repo.hasWiki;
      has_discussions = repo.hasDiscussions;
      allow_forking = repo.allowForking;
      archived = repo.archived;
      is_template = repo.isTemplate;
      web_commit_signoff_required = repo.webCommitSignoffRequired;
      lifecycle = {
        ignore_changes = [
          # GitHub no longer uses this provider field, but imported state can
          # still contain the historical value.
          "has_downloads"
        ];
      };
    }
    // optionalField repo "description"
    // optionalField repo "topics"
    // optionalAttrs (repo ? homepageUrl) { homepage_url = repo.homepageUrl; }
    // optionalAttrs (repo ? allowAutoMerge) { allow_auto_merge = repo.allowAutoMerge; }
    // optionalAttrs (repo ? allowMergeCommit) { allow_merge_commit = repo.allowMergeCommit; }
    // optionalAttrs (repo ? allowSquashMerge) { allow_squash_merge = repo.allowSquashMerge; }
    // optionalAttrs (repo ? allowUpdateBranch) { allow_update_branch = repo.allowUpdateBranch; }
    // optionalAttrs (repo ? deleteBranchOnMerge) { delete_branch_on_merge = repo.deleteBranchOnMerge; }
  );

  branchDefaultResources =
    listToResourceAttrs governance.repositories (repo: "branch-default:${repo.name}")
      (repo: {
        repository = repo.name;
        branch = repo.defaultBranch;
      });

  # Teams are managed as resources when governance.teams is provided; otherwise
  # they are referenced as data sources (backward-compatible with consumers that
  # only grant to pre-existing teams).
  managedTeams = governance.teams or [ ];
  managedTeamSlugs = listToAttrs (
    map (team: {
      name = team.slug;
      value = true;
    }) managedTeams
  );
  teamKey = teamSlug: governanceResourceKey "team:${teamSlug}";
  teamRef =
    teamSlug:
    if managedTeamSlugs ? ${teamSlug} then
      terraformRef "github_team.${teamKey teamSlug}.id"
    else
      terraformRef "data.github_team.${teamDataName teamSlug}.id";

  teamResources = listToAttrs (
    map (team: {
      name = teamKey team.slug;
      value = {
        name = team.name;
        privacy = team.privacy;
      }
      // optionalField team "description"
      // optionalAttrs (team ? parentTeamSlug) { parent_team_id = teamRef team.parentTeamSlug; };
    }) managedTeams
  );

  teamMembershipResources =
    listToResourceAttrs (governance.teamMemberships or [ ])
      (m: "team-membership:${m.teamSlug}:${m.username}")
      (m: {
        team_id = teamRef m.teamSlug;
        username = m.username;
        role = m.role;
      });

  runnerGroupResources =
    listToResourceAttrs (governance.runnerGroups or [ ]) (rg: "runner-group:${rg.name}")
      (
        rg:
        {
          name = rg.name;
          visibility = rg.visibility;
        }
        // optionalAttrs (rg ? allowsPublicRepositories) {
          allows_public_repositories = rg.allowsPublicRepositories;
        }
        // optionalAttrs (rg ? restrictedToWorkflows) {
          restricted_to_workflows = rg.restrictedToWorkflows;
        }
      );

  customRoleResources =
    listToResourceAttrs (governance.customRepositoryRoles or [ ]) (role: "custom-role:${role.name}")
      (
        role:
        {
          name = role.name;
          base_role = role.baseRole;
          permissions = role.permissions;
        }
        // optionalField role "description"
      );

  # Referenced team slugs that are not managed still need a data source.
  referencedTeamSlugs = attrNames (
    listToAttrs (
      map
        (slug: {
          name = slug;
          value = true;
        })
        (
          (map (grant: grant.teamSlug) governance.teamRepositories)
          ++ (map (m: m.teamSlug) (governance.teamMemberships or [ ]))
        )
    )
  );
  teamDataSources = listToAttrs (
    map (teamSlug: {
      name = teamDataName teamSlug;
      value = {
        slug = teamSlug;
      };
    }) (filter (slug: !(managedTeamSlugs ? ${slug})) referencedTeamSlugs)
  );

  membershipResources =
    listToResourceAttrs governance.memberships (member: "member:${member.username}")
      (member: {
        username = member.username;
        role = member.role;
      });

  repositoryCollaboratorResources =
    listToResourceAttrs governance.outsideCollaborators
      (collaborator: "repo-collaborator:${collaborator.repository}:${collaborator.username}")
      (collaborator: {
        repository = collaborator.repository;
        username = collaborator.username;
        permission = collaborator.permission;
      });

  teamRepositoryResources =
    listToResourceAttrs governance.teamRepositories
      (grant: "team-repository:${grant.teamSlug}:${grant.repository}")
      (grant: {
        team_id = teamRef grant.teamSlug;
        repository = grant.repository;
        permission = grant.permission;
      });

  branchProtectionResources =
    listToResourceAttrs governance.branchProtections
      (branch: "branch-protection:${branch.repository}:${branch.pattern}")
      (
        branch:
        {
          repository_id = terraformRef "github_repository.${repositoryResourceName branch.repository}.node_id";
          pattern = branch.pattern;
          enforce_admins = branch.enforceAdmins;
          allows_deletions = branch.allowsDeletions;
          allows_force_pushes = branch.allowsForcePushes;
          required_linear_history = branch.requiredLinearHistory;
          require_conversation_resolution = branch.requireConversationResolution;
          require_signed_commits = branch.requireSignedCommits;
          lock_branch = branch.lockBranch;
        }
        // optionalAttrs (branch ? requiredStatusChecks) {
          required_status_checks = [
            {
              strict = branch.requiredStatusChecks.strict;
              contexts = branch.requiredStatusChecks.contexts;
            }
          ];
        }
        // optionalAttrs (branch ? requiredPullRequestReviews) {
          required_pull_request_reviews = [
            {
              dismiss_stale_reviews = branch.requiredPullRequestReviews.dismissStaleReviews;
              require_code_owner_reviews = branch.requiredPullRequestReviews.requireCodeOwnerReviews;
              require_last_push_approval = branch.requiredPullRequestReviews.requireLastPushApproval;
              required_approving_review_count = branch.requiredPullRequestReviews.requiredApprovingReviewCount;
            }
          ];
        }
      );

  repositoryEnvironmentResources =
    listToResourceAttrs governance.repositoryEnvironments
      (environment: "environment:${environment.repository}:${environment.environment}")
      (
        environment:
        {
          repository = environment.repository;
          environment = environment.environment;
          can_admins_bypass = environment.canAdminsBypass;
          wait_timer = environment.waitTimer;
        }
        // optionalAttrs (environment ? deploymentBranchPolicy) {
          deployment_branch_policy = [
            {
              protected_branches = environment.deploymentBranchPolicy.protectedBranches;
              custom_branch_policies = environment.deploymentBranchPolicy.customBranchPolicies;
            }
          ];
        }
      );

  actionsRepositoryPermissionResources =
    listToResourceAttrs governance.actionsRepositoryPermissions
      (permissions: "actions-repository-permissions:${permissions.repository}")
      (permissions: {
        repository = permissions.repository;
        enabled = permissions.enabled;
        allowed_actions = permissions.allowedActions;
        sha_pinning_required = permissions.shaPinningRequired;
      });

  actionsVariableResources =
    listToResourceAttrs governance.actionsVariables
      (variable: "actions-variable:${variable.repository}:${variable.name}")
      (variable: {
        repository = variable.repository;
        variable_name = variable.name;
        value = variable.value;
      });

  issueLabelResources =
    listToResourceAttrs governance.issueLabels (label: "label:${label.repository}:${label.name}")
      (
        label:
        {
          repository = label.repository;
          name = label.name;
          color = label.color;
        }
        // optionalField label "description"
      );

  organizationResources = {
    github_actions_organization_permissions.default = {
      enabled_repositories = governance.organization.actionsPermissions.enabledRepositories;
      allowed_actions = governance.organization.actionsPermissions.allowedActions;
      sha_pinning_required = governance.organization.actionsPermissions.shaPinningRequired;
    };
  };

  governanceResources =
    organizationResources
    // optionalAttrs (membershipResources != { }) { github_membership = membershipResources; }
    // optionalAttrs (repositoryResources != { }) { github_repository = repositoryResources; }
    // optionalAttrs (branchDefaultResources != { }) { github_branch_default = branchDefaultResources; }
    // optionalAttrs (repositoryCollaboratorResources != { }) {
      github_repository_collaborator = repositoryCollaboratorResources;
    }
    // optionalAttrs (teamResources != { }) { github_team = teamResources; }
    // optionalAttrs (teamMembershipResources != { }) {
      github_team_membership = teamMembershipResources;
    }
    // optionalAttrs (teamRepositoryResources != { }) {
      github_team_repository = teamRepositoryResources;
    }
    // optionalAttrs (runnerGroupResources != { }) {
      github_actions_runner_group = runnerGroupResources;
    }
    // optionalAttrs (customRoleResources != { }) {
      github_organization_custom_role = customRoleResources;
    }
    // optionalAttrs (branchProtectionResources != { }) {
      github_branch_protection = branchProtectionResources;
    }
    // optionalAttrs (repositoryEnvironmentResources != { }) {
      github_repository_environment = repositoryEnvironmentResources;
    }
    // optionalAttrs (actionsRepositoryPermissionResources != { }) {
      github_actions_repository_permissions = actionsRepositoryPermissionResources;
    }
    // optionalAttrs (actionsVariableResources != { }) {
      github_actions_variable = actionsVariableResources;
    }
    // optionalAttrs (issueLabelResources != { }) { github_issue_label = issueLabelResources; };

  countAttrs = attrs: length (attrNames attrs);
  countTopics = foldl' (sum: repo: sum + length (repo.topics or [ ])) 0 governance.repositories;

  resources =
    governanceResources
    // optionalAttrs (organizationSecretResources != { }) {
      github_actions_organization_secret = organizationSecretResources;
    }
    // optionalAttrs (repositorySecretResources != { }) {
      github_actions_secret = repositorySecretResources;
    }
    // optionalAttrs (environmentSecretResources != { }) {
      github_actions_environment_secret = environmentSecretResources;
    };
in
{
  terraform = {
    required_version = ">= 1.8.0";
    backend.s3 = { };
    required_providers.github = {
      source = "integrations/github";
      version = "~> 6.0";
    };
  };

  provider.github = {
    owner = githubOwner;
  };

  resource = resources;

  output = {
    expected_aws_account_id = {
      value = awsAccountId;
      description = "Expected AWS account ID for the S3 backend used by this bootstrap layer.";
    };

    aws_region = {
      value = awsRegion;
      description = "AWS region for the S3 backend used by this bootstrap layer.";
    };

    github_owner = {
      value = githubOwner;
      description = "GitHub organization governed by this bootstrap layer.";
    };

    github_access_check_repository = {
      value = githubAccessCheckRepository;
      description = "Repository used by the bootstrap helper to validate GitHub token access.";
    };

    github_bootstrap_state_key = {
      value = githubBootstrapStateKey;
      description = "S3 key for the manually applied GitHub governance Terraform state file.";
    };

    governance_inventory_source = {
      value = governance.snapshot.source;
      description = "Reviewed inventory snapshot used to seed the non-secret GitHub governance model.";
    };

    github_governance_repository_count = {
      value = length governance.repositories;
      description = "GitHub repositories emitted by the governance model.";
    };

    github_governance_repository_names = {
      value = sortedRepoNames;
      description = "GitHub repositories emitted by the governance model.";
    };

    github_governance_membership_count = {
      value = countAttrs membershipResources;
      description = "Organization membership resources emitted by the governance model.";
    };

    github_governance_branch_default_count = {
      value = countAttrs branchDefaultResources;
      description = "Default branch resources emitted by the governance model.";
    };

    github_governance_outside_collaborator_count = {
      value = countAttrs repositoryCollaboratorResources;
      description = "Direct outside collaborator resources emitted by the governance model.";
    };

    github_governance_team_repository_count = {
      value = countAttrs teamRepositoryResources;
      description = "Team repository grant resources emitted by the governance model.";
    };

    github_governance_branch_protection_count = {
      value = countAttrs branchProtectionResources;
      description = "Branch protection resources emitted by the governance model.";
    };

    github_governance_environment_count = {
      value = countAttrs repositoryEnvironmentResources;
      description = "Repository Environment resources emitted by the governance model.";
    };

    github_governance_actions_repository_permissions_count = {
      value = countAttrs actionsRepositoryPermissionResources;
      description = "Repository Actions permission resources emitted by the governance model.";
    };

    github_governance_actions_variable_count = {
      value = countAttrs actionsVariableResources;
      description = "Repository Actions variable resources emitted by the governance model.";
    };

    github_governance_issue_label_count = {
      value = countAttrs issueLabelResources;
      description = "Issue label resources emitted by the governance model.";
    };

    github_governance_repository_topic_count = {
      value = countTopics;
      description = "Repository topics modeled through github_repository.topics.";
    };

    github_governance_deferred_resource_count = {
      value = length governance.deferredResources;
      description = "Inventory rows intentionally not emitted by this root yet.";
    };

    github_governance_deferred_resource_names = {
      value = map (resource: "${resource.type}:${resource.name}") governance.deferredResources;
      description = "Deferred inventory rows that need explicit follow-up before Terraform management.";
    };

    secret_manifest_count = {
      value = length eligibleSecrets;
      description = "Total GitHub Actions secrets declared in the governance manifest.";
    };

    secret_manifest_organization_secret_count = {
      value = length manifestOrganizationSecrets;
      description = "Organization-scoped GitHub Actions secrets declared in the governance manifest.";
    };

    secret_manifest_repository_secret_count = {
      value = length manifestRepositorySecrets;
      description = "Repository-scoped GitHub Actions secrets declared in the governance manifest.";
    };

    secret_manifest_environment_secret_count = {
      value = length manifestEnvironmentSecrets;
      description = "Environment-scoped GitHub Actions secrets declared in the governance manifest.";
    };

    secret_manifest_ids = {
      value = manifestProviderIds;
      description = "Provider ids for every GitHub Actions secret declared in the manifest.";
    };

    github_secret_managed_candidate_count = {
      value = length managedProviderIds;
      description = "GitHub Actions secret provider ids requested for Terraform management.";
    };

    github_secret_managed_candidate_ids = {
      value = managedProviderIds;
      description = "Provider ids requested for Terraform-managed GitHub Actions secret resources.";
    };

    github_secret_payload_count = {
      value = length (attrNames secretPayloads);
      description = "GitHub-encrypted secret payloads currently available to Terraform.";
    };

    github_secret_payload_ids = {
      value = attrNames secretPayloads;
      description = "Provider ids that currently have GitHub-encrypted payloads.";
    };

    github_secret_managed_count = {
      value = length managedSecrets;
      description = "GitHub Actions secret resources emitted by Terraform from the governance manifest.";
    };

    github_secret_managed_ids = {
      value = map (secret: secret.providerId) managedSecrets;
      description = "Provider ids emitted as GitHub Actions secret resources.";
    };

    github_organization_secret_count = {
      value = length organizationSecrets;
      description = "Organization GitHub Actions secret resources emitted by Terraform.";
    };

    github_repository_secret_count = {
      value = length repositorySecrets;
      description = "Repository GitHub Actions secret resources emitted by Terraform.";
    };

    github_environment_secret_count = {
      value = length environmentSecrets;
      description = "Environment GitHub Actions secret resources emitted by Terraform.";
    };
  };
}
# Only emit the `data` block when there are team data sources; an empty
# `data = { }` is invalid Terraform JSON (relevant to a pre-inventory skeleton).
// optionalAttrs (teamDataSources != { }) {
  data.github_team = teamDataSources;
}
