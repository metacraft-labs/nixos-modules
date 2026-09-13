# Reusable, company-agnostic Terraform (terranix) engine that brings an
# organization's GitHub Actions spending BUDGET under management.
#
# WHY THIS EXISTS: the `integrations/github` provider has NO budget /
# spending-limit resource, and GitHub's legacy "spending limit" API was
# replaced by the Budgets subsystem on the enhanced billing platform. Budgets
# are therefore managed through the GitHub Budgets REST API
# (`/organizations/{org}/settings/billing/budgets`, header
# `X-GitHub-Api-Version: 2026-03-10`) driven from Terraform via the third-party
# `magodo/restful` provider, which gives a real CRUD lifecycle + drift
# detection + import (unlike a `null_resource`/curl shim).
#
# This module is GENERAL: no company/org names, tokens, or budget IDs are baked
# in. A concrete consumer (e.g. infra's `terraform/github-budgets/<env>`) calls
# it with the org->budget map and the name of the terraform variable that
# carries a billing-scoped token. Same toolkit-vs-policy split the other shared
# terraform engines use (see actions-secrets.nix).
#
# USAGE (from a concrete terranix root):
#
#   { ... }:
#   import "${nixos-modules}/terraform/github/actions-budgets.nix" {
#     budgets = {
#       "metacraft-labs"     = { id = "852e9d35-…"; };   # existing → import
#       "blocksense-network" = { id = "fc1603e0-…"; };   # existing → import
#       "agent-harbor"       = { id = null;         };   # create once migrated
#     };
#   }
#
# The token reaches the provider through a terraform variable (default
# `github_billing_token`). Point the root's metadata.json at an agenix token
# exported as `TF_VAR_<tokenVar>` (credential_mode = "agenix-token") so the
# value is NEVER written to a tfvars file, the plan, or state. The token must be
# an org admin / billing manager credential (classic PAT `admin:org`, or a
# fine-grained token / GitHub App install token with org "Administration" or
# billing write). `GITHUB_TOKEN` cannot manage budgets.
{
  # attrset: orgLogin -> { id = <existing budget uuid | null>; amount ? 0; preventFurtherUsage ? true; productSku ? "actions"; }
  budgets,
  # Terraform variable name carrying the billing-scoped token. The concrete
  # root's metadata.json must set credentials_env_name = "TF_VAR_<this>".
  tokenVar ? "github_billing_token",
  # GitHub API host. Override for GHES.
  apiBaseUrl ? "https://api.github.com",
  # Budgets API version header. Pin it — the schema is versioned.
  apiVersion ? "2026-03-10",
  # magodo/restful provider version constraint.
  restfulVersion ? "~> 0.25",
  # Whether the root uses the shared S3 backend (true) or is offline/local.
  useS3Backend ? true,
}:
# Returns a plain terranix config attrset (only builtins used, so it composes
# like actions-secrets.nix — the concrete root is just
# `{ ... }: import ./this { params }`).
let
  # Per-org effective settings with defaults.
  norm = org: cfg: {
    inherit org;
    id = cfg.id or null;
    amount = cfg.amount or 0;
    preventFurtherUsage = cfg.preventFurtherUsage or true;
    productSku = cfg.productSku or "actions";
  };
  orgs = builtins.attrValues (builtins.mapAttrs norm budgets);

  # One restful_resource per org. `path` is the org's budgets collection; a POST
  # creates the budget and returns its `id`; `read_path` then GETs the single
  # budget by that id. The resource's terraform `id` (used for `terraform
  # import`) is exactly that resolved read path — i.e.
  #   /organizations/<org>/settings/billing/budgets/<budget-uuid>
  # which is why the import commands below use the full path, not the bare uuid.
  budgetResource = e: {
    name = builtins.replaceStrings [ "-" ] [ "_" ] e.org;
    value = {
      path = "/organizations/${e.org}/settings/billing/budgets";

      create_method = "POST";
      update_method = "PATCH";
      # Read a single budget by the id returned from the create response.
      read_path = "$(path)/$(body.id)";

      # The declarative budget. `budget_type=ProductPricing` + `sku=actions`
      # covers every Actions SKU; `budget_amount=0` + `prevent_further_usage`
      # is the hard-stop $0 cap (GitHub refuses to START further paid usage).
      body = {
        budget_amount = e.amount;
        prevent_further_usage = e.preventFurtherUsage;
        budget_scope = "organization";
        budget_entity_name = "";
        budget_type = "ProductPricing";
        budget_product_sku = e.productSku;
        budget_alerting = {
          will_alert = false;
          alert_recipients = [ ];
        };
      };

      # These are sent on create/update but NOT tracked for drift: GitHub's GET
      # representation of the budget metadata (entity name / alerting envelope)
      # is not guaranteed to echo the write shape byte-for-byte, and we only
      # care that scope/type/sku/amount/prevent_further_usage stay pinned. This
      # keeps the post-import plan clean. If a real import shows drift on a
      # tracked field (e.g. GitHub returns a capitalized scope), move that field
      # here too and re-plan.
      write_only_attrs = [ "budget_entity_name" "budget_alerting" ];
    };
  };
in
{
  terraform = {
    required_version = ">= 1.8.0";
    required_providers.restful = {
      source = "magodo/restful";
      version = restfulVersion;
    };
  } // (if useS3Backend then { backend.s3 = { }; } else { });

  # Billing-scoped token, injected via TF_VAR_<tokenVar> by the CI/operator
  # path. Never persisted to tfvars or the plan; state stores no token because
  # the provider block reads it at runtime only.
  variable.${tokenVar} = {
    type = "string";
    sensitive = true;
    description = "Org admin / billing-manager GitHub token used to manage Actions spending budgets via the Budgets REST API.";
  };

  provider.restful = {
    base_url = apiBaseUrl;
    security = {
      http.token = {
        token = "\${var.${tokenVar}}";
        scheme = "Bearer";
      };
    };
    header = {
      "Accept" = "application/vnd.github+json";
      "X-GitHub-Api-Version" = apiVersion;
    };
  };

  resource.restful_resource = builtins.listToAttrs (
    builtins.map budgetResource orgs
  );
}
