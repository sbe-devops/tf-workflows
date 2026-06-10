# tf-workflows

Reusable GitHub Actions workflows for SBE Terraform plan and apply. Every SBE client engagement calls these workflows from their project repo rather than duplicating CI logic. The workflows handle format checking, linting, static analysis, OIDC-based AWS credential exchange, and plan output as PR comments.

Both workflow files live in `.github/workflows/` and are consumed via GitHub's `uses:` reusable-workflow syntax. No secrets are embedded in the workflow YAML — security lives in IAM trust policies (OIDC) and scoped repository secrets.

---

## Workflows

### `tf-plan.yml`

Runs on pull requests. Performs the following steps in order:

1. Checks out the calling repo
2. Exchanges a GitHub OIDC token for short-lived AWS credentials via the IAM planner role
3. Installs the requested Terraform version
4. Runs `terraform fmt -check -recursive` (non-blocking; result reported in PR comment)
5. Installs and runs TFLint (non-blocking; result reported)
6. Runs a Checkov scan via `bridgecrewio/checkov-action` with `soft_fail: true` (non-blocking; result reported)
7. If `app_id` is provided, generates a short-lived GitHub App token and configures git credentials for private `sbe-devops` Terraform module repos
8. Runs `terraform init -upgrade` then `terraform validate`
9. Runs `terraform plan -out=tfplan`
10. Posts a summary table (format / TFLint / validate / plan outcomes) as a PR comment
11. Fails the job if the plan step itself failed

Intended trigger: `on: pull_request` targeting `main`.

### `tf-apply.yml`

Runs on merge to `main` (lower environments) or `workflow_dispatch` (production). Steps:

1. Checks out the calling repo
2. Exchanges OIDC token for short-lived AWS credentials via the IAM enforcer role
3. Installs the requested Terraform version
4. Runs `terraform fmt -check -recursive` (blocking — apply is gated on clean formatting)
5. If `app_id` is provided, generates a GitHub App token and configures private module access
6. Runs `terraform init -upgrade`
7. Runs `terraform apply -auto-approve`

Intended triggers: `on: push` to `main` for test/dev; `on: workflow_dispatch` with a GitHub Environment reviewer gate for production.

---

## Usage

### Calling `tf-plan.yml`

```yaml
# .github/workflows/tf-plan.yml  (in your project repo)
name: Terraform Plan

on:
  pull_request:
    branches: [main]

jobs:
  plan-test:
    permissions:
      id-token: write
      contents: read
      pull-requests: write
    uses: sbe-devops/tf-workflows/.github/workflows/tf-plan.yml@v0.8.1
    with:
      working_directory: terraform/test
      role_arn: arn:aws:iam::123456789012:role/your-project-terraform-planner
      aws_region: us-east-1
      terraform_version: "1.9.0"
    secrets:
      app_id: ${{ secrets.SBE_DEVOPS_APP_ID }}
      app_private_key: ${{ secrets.SBE_DEVOPS_APP_PRIVATE_KEY }}
```

### Calling `tf-apply.yml` (test environment — auto on merge)

```yaml
# .github/workflows/tf-apply-test.yml  (in your project repo)
name: Terraform Apply — test

on:
  push:
    branches: [main]

jobs:
  apply-test:
    permissions:
      id-token: write
      contents: read
    uses: sbe-devops/tf-workflows/.github/workflows/tf-apply.yml@v0.8.1
    with:
      working_directory: terraform/test
      role_arn: arn:aws:iam::123456789012:role/your-project-terraform-enforcer
      aws_region: us-east-1
      terraform_version: "1.9.0"
    secrets:
      app_id: ${{ secrets.SBE_DEVOPS_APP_ID }}
      app_private_key: ${{ secrets.SBE_DEVOPS_APP_PRIVATE_KEY }}
```

### Calling `tf-apply.yml` (production — manual dispatch with reviewer gate)

```yaml
# .github/workflows/tf-apply-prod.yml  (in your project repo)
name: Terraform Apply — prod

on:
  workflow_dispatch:

jobs:
  apply-prod:
    environment: prod          # GitHub Environment with required reviewers configured
    permissions:
      id-token: write
      contents: read
    uses: sbe-devops/tf-workflows/.github/workflows/tf-apply.yml@v0.8.1
    with:
      working_directory: terraform/prod
      role_arn: arn:aws:iam::123456789012:role/your-project-terraform-enforcer
      aws_region: us-east-1
      terraform_version: "1.9.0"
    secrets:
      app_id: ${{ secrets.SBE_DEVOPS_APP_ID }}
      app_private_key: ${{ secrets.SBE_DEVOPS_APP_PRIVATE_KEY }}
```

---

## Inputs

| Workflow | Input | Type | Required | Default | Description |
|---|---|---|:---:|---|---|
| `tf-plan.yml` | `working_directory` | `string` | yes | — | Path to the Terraform root module (relative to the repo root) |
| `tf-plan.yml` | `role_arn` | `string` | yes | — | IAM role ARN to assume — must be the planner role |
| `tf-plan.yml` | `aws_region` | `string` | no | `us-east-1` | AWS region passed to `aws-actions/configure-aws-credentials` |
| `tf-plan.yml` | `terraform_version` | `string` | no | `latest` | Terraform version for `hashicorp/setup-terraform` |
| `tf-plan.yml` | `tflint_version` | `string` | no | `latest` | TFLint version for `terraform-linters/setup-tflint` |
| `tf-apply.yml` | `working_directory` | `string` | yes | — | Path to the Terraform root module (relative to the repo root) |
| `tf-apply.yml` | `role_arn` | `string` | yes | — | IAM role ARN to assume — must be the enforcer role |
| `tf-apply.yml` | `aws_region` | `string` | no | `us-east-1` | AWS region passed to `aws-actions/configure-aws-credentials` |
| `tf-apply.yml` | `terraform_version` | `string` | no | `latest` | Terraform version for `hashicorp/setup-terraform` |

---

## Secrets

| Workflow | Secret | Required | Description |
|---|---|:---:|---|
| `tf-plan.yml` | `app_id` | no | GitHub App ID for reading private `sbe-devops` Terraform module repos. Omit if all modules are public. |
| `tf-plan.yml` | `app_private_key` | no | GitHub App private key corresponding to `app_id`. |
| `tf-apply.yml` | `app_id` | no | GitHub App ID for reading private `sbe-devops` Terraform module repos. Omit if all modules are public. |
| `tf-apply.yml` | `app_private_key` | no | GitHub App private key corresponding to `app_id`. |

Both secrets are optional but coupled — if `app_id` is present the workflow generates a short-lived token and configures git credentials; if absent the private-module steps are skipped entirely.

Store the values in the project repo as `SBE_DEVOPS_APP_ID` and `SBE_DEVOPS_APP_PRIVATE_KEY` and pass them through as shown in the usage examples. Do not generate the token in the calling workflow and pass it as a pre-built value — GitHub redacts masked secrets before they leave a job, so the token arrives empty in the reusable workflow.

---

## Permissions required

The calling job must declare every permission the reusable workflow's job uses. Permissions do not inherit automatically through a `uses:` boundary.

| Permission | Required for | Applies to |
|---|---|---|
| `id-token: write` | OIDC token exchange with AWS | Both workflows |
| `contents: read` | `actions/checkout` | Both workflows |
| `pull-requests: write` | Posting the plan summary comment | `tf-plan.yml` only |

For `tf-apply.yml` callers, `pull-requests: write` is not needed and should be omitted.

---

## Compliance posture

These workflows are part of the SBE SOC 2 Type II control baseline (ADR-0003).

| SOC 2 Control | Mechanism |
|---|---|
| **CC1.4** — Audit evidence | Every plan and apply execution is a permanent, immutable GitHub Actions run log. Checkov and TFLint output is captured in the same run. Plan comments on PRs create a reviewable record at the change-approval layer. |
| **CC6.1** — Logical access | AWS credentials are obtained via OIDC — no long-lived access keys. The planner role is constrained to read-only operations; the enforcer role is constrained to write. Neither role's credentials are ever stored or logged. |
| **CC8.1** — Change management | Production applies require `workflow_dispatch` and a GitHub Environment with required reviewers. No production change can run automatically on push. Combined with branch protection on `main`, every production apply has a documented approval trail. |

The GitHub App pattern for private module access (rather than a PAT) satisfies CC6.1's short-lived credential requirement: tokens are scoped to the workflow run and expire automatically.

---

## Versioning

This repo follows [semver](https://semver.org/): `vMAJOR.MINOR.PATCH`. MAJOR increments on breaking input, output, or permission changes. MINOR increments on backward-compatible additions. PATCH increments on bug fixes.

Pin to a release tag in every consumer — never `@main`:

```yaml
uses: sbe-devops/tf-workflows/.github/workflows/tf-plan.yml@v0.8.1
```

To upgrade: update the `@v...` tag in your caller workflow.

Releases at [sbe-devops/tf-workflows/releases](https://github.com/sbe-devops/tf-workflows/releases). Cutting procedure and **fail-forward** rule are documented in [SBE GitHub Actions standards](https://github.com/sbe-devops/standards/blob/main/github-actions.md#versioning).

---

## References

- [SBE GitHub Actions standards](https://github.com/sbe-devops/standards/blob/main/github-actions.md)
- [SBE Terraform standards](https://github.com/sbe-devops/standards/blob/main/terraform.md)
- [GitHub — Reusable workflows](https://docs.github.com/en/actions/sharing-automations/reusing-workflows)
- [GitHub — Workflow syntax reference](https://docs.github.com/en/actions/writing-workflows/workflow-syntax-for-github-actions)
- [GitHub — Permissions in workflows](https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/controlling-permissions-for-github_token)
- [GitHub — Environments and reviewer gates](https://docs.github.com/en/actions/managing-workflow-runs-and-deployments/managing-deployments/managing-environments-for-deployment)
- [GitHub — OIDC hardening for AWS](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
- [GitHub Apps vs PATs](https://docs.github.com/en/apps/creating-github-apps/about-creating-github-apps/about-creating-github-apps)
- [AWS OIDC identity provider](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html)
- [hashicorp/setup-terraform action](https://github.com/hashicorp/setup-terraform)
- [bridgecrewio/checkov-action](https://github.com/bridgecrewio/checkov-action)
- [terraform-linters/setup-tflint](https://github.com/terraform-linters/setup-tflint)
