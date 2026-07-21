# Example caller for governance.nix. A real consumer's governance root
# (bootstrap/github/<name>-governance-prod/root.nix) imports this engine and
# passes its own `governance` inventory model and secret `manifest`, plus the
# resolved managed/payload documents rendered by github-governance-secrets-render.
# This fixture supplies a tiny, org-agnostic model so the engine can be rendered
# offline (Nix eval only) with no credentials and no company literals.
import ./governance.nix {
  awsAccountId = "000000000000";
  awsRegion = "us-east-1";
  githubOwner = "example-org";
  githubBootstrapStateKey = "bootstrap/github/example-governance-prod.tfstate";

  governance = {
    snapshot.source = "example-inventory-snapshot";
    organization.actionsPermissions = {
      enabledRepositories = "all";
      allowedActions = "selected";
      shaPinningRequired = true;
    };
    repositories = [
      {
        name = "infra";
        visibility = "private";
        hasIssues = true;
        hasProjects = false;
        hasWiki = false;
        hasDiscussions = false;
        allowForking = false;
        archived = false;
        isTemplate = false;
        webCommitSignoffRequired = false;
        defaultBranch = "live";
        description = "Infrastructure as code.";
        topics = [ "terraform" ];
      }
    ];
    memberships = [
      {
        username = "example-admin";
        role = "admin";
      }
    ];
    outsideCollaborators = [ ];
    teamRepositories = [
      {
        teamSlug = "infra";
        repository = "infra";
        permission = "admin";
      }
    ];
    branchProtections = [
      {
        repository = "infra";
        pattern = "live";
        enforceAdmins = true;
        allowsDeletions = false;
        allowsForcePushes = false;
        requiredLinearHistory = false;
        requireConversationResolution = true;
        requireSignedCommits = false;
        lockBranch = false;
        requiredStatusChecks = {
          strict = true;
          contexts = [ "ci / build" ];
        };
      }
    ];
    repositoryEnvironments = [
      {
        repository = "infra";
        environment = "production";
        canAdminsBypass = true;
        waitTimer = 0;
      }
    ];
    actionsRepositoryPermissions = [
      {
        repository = "infra";
        enabled = true;
        allowedActions = "selected";
        shaPinningRequired = true;
      }
    ];
    actionsVariables = [
      {
        repository = "infra";
        name = "BACKEND_CONFIG_FILE";
        value = "backends/aws-example-prod.hcl";
      }
    ];
    issueLabels = [
      {
        repository = "infra";
        name = "sensitive-change";
        color = "b60205";
        description = "Touches Layer-0 or secrets.";
      }
    ];
    deferredResources = [ ];
  };

  # One org secret declared but not yet promoted to Terraform management (absent
  # from managedDoc), so the engine renders manifest counts without needing any
  # GitHub-encrypted payloads.
  manifest = {
    version = 1;
    owner = "example-org";
    secrets = [
      {
        providerResource = "github_actions_organization_secret";
        scope = "organization";
        name = "GH_GOVERNANCE_APP_ID";
        providerId = "example-org/GH_GOVERNANCE_APP_ID";
        visibility = "all";
        ageFile = "secrets/actions/org/GH_GOVERNANCE_APP_ID.age";
        manageWithTerraform = true;
      }
    ];
  };
}
