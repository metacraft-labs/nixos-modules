# Testing OpenTofu / Terraform Configurations

This document describes the available strategies for testing OpenTofu
configurations, from lightweight static checks to fully offline mock-based
tests. The examples use Cloudflare as a concrete provider, but all
techniques apply to any provider.

> **Terranix note:** When using Terranix (Nix → HCL), generate `.tf.json`
> files first (`terranix`), then run the same `tofu validate` / `tofu test`
> pipeline. Test files (`.tftest.hcl`) are written in native HCL regardless
> of whether the main configuration uses Terranix.

## Layers of Testing

| Layer         | Tool                          | Credentials needed | What it catches                              |
| ------------- | ----------------------------- | ------------------ | -------------------------------------------- |
| **Validate**  | `tofu validate`               | None               | Syntax errors, type mismatches, missing args |
| **Lint**      | TFLint                        | None               | Best-practice violations, deprecated usage   |
| **Security**  | Checkov / trivy               | None               | Misconfigurations, policy violations         |
| **Unit test** | `tofu test` + `mock_provider` | None               | Logic, variable wiring, conditionals         |
| **Plan**      | `tofu plan`                   | Yes                | Provider-side validation, drift detection    |
| **Apply**     | `tofu apply`                  | Yes                | Real provisioning (CI on merge to main)      |

The first four layers run fully offline and never touch a real API.

---

## 1. Static Validation — `tofu validate`

The built-in validator checks syntax and basic semantic correctness:

```bash
tofu init -backend=false   # initialize providers without a backend
tofu validate
```

This catches missing required arguments, incorrect types, broken
references, and other structural errors. It does not need API credentials
and should run on every commit (pre-commit hook or CI).

## 2. Linting — TFLint

[TFLint](https://github.com/terraform-linters/tflint) is a pluggable
static analysis tool. It can catch provider-specific mistakes via rule
plugins (AWS, GCP, Azure). There is no Cloudflare-specific plugin yet, but
the generic rules still catch common issues like unused variables, deprecated
syntax, and naming convention violations.

```bash
tflint --init
tflint
```

Configure rules in `.tflint.hcl` at the repo root.

## 3. Security Scanning — Checkov / trivy

These tools scan `.tf` files for misconfigurations and policy violations
(public buckets, missing encryption, overly broad IAM, etc.):

```bash
checkov -d .
# or
trivy config .
```

Both run fully offline against the HCL source.

## 4. Unit Testing with Mock Providers — `tofu test`

This is the most powerful offline testing tool. OpenTofu's built-in test
framework (`.tftest.hcl` files) supports **mock providers** that replace
real API calls with auto-generated or explicit fake data.

### How it works

- **`mock_provider`** replaces a provider entirely — no API calls, no
  credentials.
- **`mock_resource`** / **`mock_data`** inside a `mock_provider` let you
  supply custom default values for specific resource or data source types.
- **`override_resource`** / **`override_data`** / **`override_module`**
  surgically replace individual resource instances while keeping the rest
  of the configuration intact.
- **`run`** blocks define individual test cases that execute either
  `plan` or `apply` (against the mock) and evaluate `assert` conditions.
- Tests are run with: `tofu test`

### Auto-generated values

When mocking, computed attributes that you do not explicitly set are
auto-generated:

| Type    | Default value                   |
| ------- | ------------------------------- |
| String  | Random 8-character alphanumeric |
| Number  | `0`                             |
| Boolean | `false`                         |
| List    | Empty `[]`                      |
| Map     | Empty `{}`                      |
| Object  | Recursively generated sub-attrs |

You can override these with `defaults` in `mock_resource` / `mock_data`
blocks or with `values` in `override_resource` / `override_data` blocks.

### Example: testing a Cloudflare DNS record module

```hcl
# tests/dns.tftest.hcl

mock_provider "cloudflare" {
  mock_resource "cloudflare_dns_record" {
    defaults = {
      id       = "mock-record-id"
      hostname = "test.blocksense.network"
    }
  }
}

variables {
  zone_id = "fake-zone-id"
  account_id = "fake-account-id"
}

run "creates_a_record" {
  command = plan

  variables {
    name  = "api"
    type  = "A"
    value = "1.2.3.4"
  }

  assert {
    condition     = cloudflare_dns_record.this.name == "api"
    error_message = "Expected record name to be 'api'"
  }

  assert {
    condition     = cloudflare_dns_record.this.type == "A"
    error_message = "Expected record type to be 'A'"
  }
}

run "creates_cname_record" {
  command = plan

  variables {
    name  = "www"
    type  = "CNAME"
    value = "blocksense.network"
  }

  assert {
    condition     = cloudflare_dns_record.this.type == "CNAME"
    error_message = "Expected record type to be 'CNAME'"
  }
}
```

Run with:

```bash
tofu test
```

### Example: overriding a specific resource

When you want to mock only one resource (e.g. an expensive or
side-effect-heavy one) while keeping the real provider for the rest:

```hcl
# tests/r2.tftest.hcl

override_resource {
  target = cloudflare_r2_bucket.data_store
  values = {
    id       = "mock-bucket-id"
    name     = "data-store"
    location = "WEUR"
  }
}

run "bucket_has_correct_location" {
  command = plan

  assert {
    condition     = cloudflare_r2_bucket.data_store.location == "WEUR"
    error_message = "Expected bucket in Western Europe"
  }
}
```

### Example: overriding an entire module

```hcl
override_module {
  target = module.dns
  outputs = {
    zone_id    = "fake-zone-id"
    nameservers = ["ns1.example.com", "ns2.example.com"]
  }
}

run "downstream_uses_correct_zone" {
  command = plan

  assert {
    condition     = module.dns.zone_id == "fake-zone-id"
    error_message = "Zone ID not propagated"
  }
}
```

### Shared mock data files

For reusable mock defaults across multiple test files, create
`.tfmock.hcl` files and reference them via `source`:

```hcl
# testing/cloudflare/cloudflare.tfmock.hcl
mock_resource "cloudflare_dns_record" {
  defaults = {
    id       = "mock-record-id"
    hostname = "mock.blocksense.network"
  }
}

mock_resource "cloudflare_r2_bucket" {
  defaults = {
    id       = "mock-bucket-id"
    location = "WEUR"
  }
}
```

Then in your test file:

```hcl
mock_provider "cloudflare" {
  source = "./testing/cloudflare"
}
```

### Plan-only mode (no apply)

For unit tests that should never create state, use `command = plan` in
every `run` block. You can also disable refresh to avoid any API calls:

```hcl
run "test" {
  command = plan
  plan_options {
    refresh = false
  }
  # ...
}
```

### Known limitations

- Mock providers do not know the real schema's expected formats, so
  auto-generated string values are random and may not match real-world
  patterns (e.g. ARN formats, URLs). Use explicit `defaults` when
  downstream logic depends on the shape of a value.
- There is a [known issue](https://github.com/cloudflare/terraform-provider-cloudflare/issues/6387)
  with mocking some complex Cloudflare data sources (e.g.
  `cloudflare_rulesets`) due to nested schema types. Simple resources
  like `cloudflare_dns_record` and `cloudflare_r2_bucket` work fine.
- `for_each` on `import` blocks cannot be combined with config generation.
- Repeated/dynamic blocks in mocked resources accept a single set of
  defaults applied to all instances — you cannot vary values per instance.

## 4b. IaC Policy-as-Code (Denylist)

Beyond general security scanning (Checkov/trivy), we enforce a **denylist**
that specifically blocks HCL constructs which execute code at plan time.
This is critical in the agentic workflow because PR plan jobs run with
real (read-only) credentials.

### Blocked constructs

| Construct                      | Risk                                      |
| ------------------------------ | ----------------------------------------- |
| `data "external"`              | Runs an arbitrary local program           |
| `provisioner "local-exec"`     | Executes shell commands on the CI runner  |
| `provisioner "remote-exec"`    | Executes commands on remote hosts         |
| `resource "null_resource"`     | Typically used with exec provisioners     |
| Providers not in the allowlist | Only providers on the project's allowlist |

### Enforcement: grep-based CI check

The simplest approach — a grep step in CI that fails if forbidden
constructs are found:

```bash
if grep -rE \
  '(data\s+"external"|provisioner\s+"(local-exec|remote-exec)"|resource\s+"null_resource")' \
  cloudflare/; then
  echo "Forbidden HCL constructs detected."
  exit 1
fi
```

### Enforcement: OPA/conftest (advanced)

For richer policy logic, use [conftest](https://www.conftest.dev/) with
OPA policies that parse HCL and reject forbidden blocks:

```bash
conftest test --policy policy/ cloudflare/
```

See the [Agent Development Methodology](Terraform-Agent-Development-Methodology.md#iac-denylist-policy)
for details on how this integrates into the CI pipeline.

## 5. Plan with Real Credentials — `tofu plan`

A real `tofu plan` (with valid `CLOUDFLARE_API_TOKEN`) is the final
pre-apply check. It contacts the Cloudflare API to validate the
configuration against the actual state of the world and shows exactly what
would change.

In CI, run `tofu plan` on every PR and post the output as a PR comment so
reviewers can see the proposed infrastructure diff.

## 6. Apply — `tofu apply`

Only run on merge to `main`, gated behind CI. See the consuming
repository's access token guide for project-specific CI setup.

---

## Recommended CI Pipeline

```
PR opened / updated
  |
  +--> tofu validate
  +--> tflint
  +--> tofu test          (mock providers, fully offline)
  +--> tofu plan           (real credentials, output posted to PR)
  |
merge to main
  |
  +--> tofu apply -auto-approve
```

## Useful Links

- [OpenTofu `test` command](https://opentofu.org/docs/cli/commands/test/)
- [OpenTofu mock providers](https://opentofu.org/docs/language/tests/mocking/) (if available) / [Terraform mock providers](https://developer.hashicorp.com/terraform/language/tests/mocking)
- [Terranix — Nix to Terraform JSON](https://terranix.org/)
- [TFLint](https://github.com/terraform-linters/tflint)
- [Checkov](https://www.checkov.io/)
- [Agent Development Methodology](Terraform-Agent-Development-Methodology.md)
