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

### `tf-destroy.yml`

Tears a **lower** environment down through CI, so teardown is a reviewed, logged, repeatable run
rather than a laptop holding credentials. Steps:

1. 🔴 **Refuses any `working_directory` that is not on the caller's `destroyable_directories`
   allow-list** — before checkout, and before any AWS credential exists
2. Checks out the calling repo
3. Exchanges OIDC for short-lived AWS credentials via the IAM enforcer role
4. Installs the requested Terraform version
5. If `app_id` is provided, generates a GitHub App token and configures private module access
6. Runs `terraform init -upgrade`
7. Runs `terraform plan -destroy -out=destroy.tfplan`
8. Uploads **both** the binary plan and its `terraform show` rendering as a 90-day artifact
9. Runs `terraform apply destroy.tfplan` — **the saved plan**, never a second evaluation

Intended trigger: `on: workflow_dispatch`, ideally behind a GitHub Environment with reviewers.
No `fmt -check`: formatting is a gate on what you are about to create, and blocking a teardown on
cosmetics strands live resources until someone edits the stack.

> ### 🔑 **THE ALLOW-LIST IS THE CONTROL, AND IT BELONGS TO THE CALLER.**
> `destroyable_directories` is **required**, lives in the caller's own PR-gated workflow file, and only
> an **exact** path match is destroyable. ⇒ *`tf/aws-bootstrap` (the state bucket and lock table) and
> `tf/aws-github-oidc` (every CI role) are unreachable unless someone adds them in a reviewed PR.*
> **A denylist has the opposite property — everything is destroyable until someone remembers to add
> it** — which is why there isn't one.

**What the guard refuses, and why each is a refusal rather than a normalisation:**

| shape | result |
|---|---|
| a path absent from the list | **refused** — this is the whole mechanism |
| a **parent or child** of a listed path *(`terraform`, `terraform/test/modules`)* | **refused** — the match is exact, not a prefix |
| `..` anywhere *(`terraform/test/../prod`)* | **refused**, never resolved. *Resolving it would mean the guard decides what a path means instead of the caller* |
| an absolute path | **refused** — paths are relative to the repo root |
| a **glob** in the list *(`tf/*`)* | 🔴 **hard ERROR naming globs.** *Exact matching would refuse it anyway, but silently — and a caller who believes patterns work will "fix" it by widening something else* |
| an empty or whitespace-only list | **refused.** *Fail closed: nothing is destroyable* |
| a call at any ref other than the **default branch** | **refused.** *`workflow_dispatch` runs at whatever ref the dispatcher picks, and the allow-list is read from the caller's file **at that ref** — so on a branch, adding `tf/aws-bootstrap` to it needs no review at all. The allow-list is only a control where changing it needs a reviewed PR* |
| a stack with **more than the `default` workspace** | **refused.** *See below — the allow-list keys on a directory, state keys on (directory × workspace)* |

Only whitespace, a leading `./` and a trailing `/` are normalised, identically on both sides. No case
folding *(Linux paths are case-sensitive)*, no symlink resolution, no glob expansion.

> ### 🔴 **NEVER LIST A STACK THAT MANAGES ITS OWN BACKEND.**
> *Fitbooks' `terraform/tst/bootstrap` is the concrete case: it creates the S3 state bucket and the
> DynamoDB lock table that **every other stack's state lives in**.* **Destroying it does not remove one
> environment — it removes the ability to plan, apply or destroy any of them**, and the destroy's own
> state is in the bucket it is deleting. The same goes for any `tf-aws-github-oidc` stack: that one takes
> the CI roles, so the pipeline cannot be used to put it back.
> ⚠️ **This is the one mistake the allow-list cannot catch for you** — the workflow has no way to know
> which of your directories owns the backend. *`tf-aws-bootstrap` also carries `prevent_destroy` on those
> resources (belt and braces, INFRA), but `prevent_destroy` is in the module, and a caller who removed it
> would be left with only this line.*

**Workspaces: a stack with more than `default` is refused, after `init`.**

| | |
|---|---|
| why | *the allow-list is keyed on a **directory**; Terraform state is keyed on **(directory × workspace)**. For a workspace-per-environment stack, one entry would authorise **every** environment in that directory* |
| and worse | *a fresh `init` selects `default`, so the run would destroy whatever lives in `default` while the operator was thinking of `staging`* |
| why it refuses rather than selecting | *picking a workspace from a directory-keyed allow-list is a guess. The allow-list would have to grow a workspace dimension first* |
| where it runs | **after `init`**, because `terraform workspace list` reads the backend and needs credentials. *Everything checkable before a credential exists already is* |

*Give such a stack one directory per environment, or say so and the allow-list can learn workspaces.*

**It is tested, and the tests are tested** *(`tests/`, run on every PR by `ci.yml`)*. Both suites
**extract the guards' own bytes out of the workflow and execute them**, so there is no second copy of
the logic to drift from, and both extractors **fail closed** if the markers move, the body shrinks, or a
`${{ … }}` appears inside it:

| suite | what it runs | count |
|---|---|---|
| `tests/destroy-guard.sh` | the pre-credential guard: allow-list matching, traversal, globs, the default-branch ref check — plus assertions on the **wiring** those bytes cannot see *(which input feeds which variable, that the guard precedes checkout/credentials/`init`, that the apply applies the saved plan)* | **58** |
| `tests/workspace-guard.sh` | the post-`init` workspace guard, against a **stubbed `terraform`** that reproduces every layout — workspace-per-env, a selected non-default workspace, a backend that errors | **11** |
| `tests/mutate-destroy-guard.sh` | weakens a guard **19 ways** and requires a suite to go red each time, printing the diff it applied | **19 killed, 0 survived** |

🔑 *Mapping `ALLOW_LIST` to the wrong input passes all 35 allow-list cases and is caught **only** by the
wiring assertions — which is why both halves exist.*

**One live refusal is measured, and exactly one.** A throwaway branch dispatched this workflow at
`tf/aws-bootstrap` with the path absent from the allow-list *(run `37977151072`, branch since deleted)*.
The guard refused and **every later step shows `skipped`** — no checkout, no credentials, no `init`, no
plan, no apply.

⚠️ **What that run did NOT prove:** it refused on the **ref** check, because a probe branch is by
definition not the default branch, so the **allow-list** refusal remains shell-tested rather than
observed live. A `uses:` job cannot be marked `continue-on-error`, so an in-repo "expect this to fail"
job would just be a red check; the honest position is that the allow-list path is proven by its own bytes
plus static wiring, and the first allow-list refusal in anger will be the first real caller's.

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

### Calling `tf-destroy.yml` (lower-environment teardown)

```yaml
# .github/workflows/tf-destroy-test.yml  (in your project repo)
name: Terraform Destroy — test

on:
  workflow_dispatch:
    inputs:
      working_directory:
        description: "Which lower stack to tear down"
        required: true
        type: choice
        options:
          - terraform/test
          - terraform/poc

jobs:
  destroy-test:
    permissions:
      id-token: write
      contents: read
    uses: sbe-devops/tf-workflows/.github/workflows/tf-destroy.yml@v0.11.0
    with:
      working_directory: ${{ inputs.working_directory }}
      # 🔴 THE REVIEWER GATE IS AN INPUT, NOT A JOB KEY. `environment:` is not
      # valid on a job that is a `uses:` call, so it is declared inside the
      # reusable workflow and selected from here. Omit it and there is NO
      # reviewer gate — the job runs, measured, rather than failing.
      environment: teardown
      # 🔴 THE ALLOW-LIST. Exact paths, one per line. Anything absent is refused, and
      # adding a line is a reviewed PR to this file.
      destroyable_directories: |
        terraform/test
        terraform/poc
      role_arn: arn:aws:iam::123456789012:role/your-project-terraform-enforcer
      aws_region: us-east-1
      terraform_version: "1.9.0"
      app_id: ${{ vars.SBE_DEVOPS_APP_ID }}
    secrets:
      app_private_key: ${{ secrets.SBE_DEVOPS_APP_PRIVATE_KEY }}
```

> 🔑 **The `choice` list and the allow-list are two different controls, and you want both.** *The
> `choice` stops a typo at dispatch time; the allow-list stops anything else, including a caller
> wired to free-text input, a `push` trigger, or another workflow calling this one. **Only the
> allow-list is enforced inside the reusable workflow**, where a consumer repo cannot edit it.*

⚠️ **Dispatch it from the DEFAULT BRANCH.** A `workflow_dispatch` run uses the workflow file — and
therefore the allow-list — from whichever ref you pick, so the guard refuses anything else. *That is the
difference between a list a reviewer approved and a list the dispatcher wrote.*

> ### 🔴 **THE FIRST CALLER WILL FAIL ON IAM, AND THAT IS EXPECTED.**
> *The enforcer role's trust policy currently admits `tf-apply.yml` by `job_workflow_ref`, which does not
> match `tf-destroy.yml`.* **Until that trust is widened (INFRA owns it), the `Configure AWS credentials`
> step fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity`.**
> ✅ *This is the right order: the guard, the tests and the review land first, and the credential that
> makes it real is granted last. A destroy path that could assume the enforcer role before anyone had
> reviewed the guard would be the wrong way round.*

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
| `tf-destroy.yml` | `working_directory` | `string` | **yes** | — | Root module to **destroy** (relative to the repo root). Must appear verbatim in `destroyable_directories` |
| `tf-destroy.yml` | `destroyable_directories` | `string` | **yes** | — | 🔴 Newline-separated allow-list of root modules this caller may destroy. **Exact paths only** — globs are rejected, not expanded; anything absent is refused |
| `tf-destroy.yml` | `role_arn` | `string` | **yes** | — | IAM role ARN to assume — must be the enforcer role |
| `tf-destroy.yml` | `aws_region` | `string` | no | `us-east-1` | AWS region passed to `aws-actions/configure-aws-credentials` |
| `tf-destroy.yml` | `terraform_version` | `string` | no | `latest` | Terraform version for `hashicorp/setup-terraform` |
| `tf-destroy.yml` | `environment` | `string` | no | `""` | GitHub Environment for the destroy job, for a required-reviewer gate. **Declared here because `environment:` is not valid on a `uses:` job.** Empty means no environment and **no gate** |
| `tf-destroy.yml` | `app_id` | `string` | no | `""` | GitHub App ID for reading private `sbe-devops` module repos. Pass via `with:` using `vars.SBE_DEVOPS_APP_ID` |

---

## Secrets

| Workflow | Secret | Required | Description |
|---|---|:---:|---|
| `tf-plan.yml` | `app_id` | no | GitHub App ID for reading private `sbe-devops` Terraform module repos. Omit if all modules are public. |
| `tf-plan.yml` | `app_private_key` | no | GitHub App private key corresponding to `app_id`. |
| `tf-apply.yml` | `app_id` | no | GitHub App ID for reading private `sbe-devops` Terraform module repos. Omit if all modules are public. |
| `tf-apply.yml` | `app_private_key` | no | GitHub App private key corresponding to `app_id`. |
| `tf-destroy.yml` | `app_private_key` | no | GitHub App private key corresponding to the `app_id` **input**. |

> ⚠️ **`app_id` moved from a secret to an INPUT in `v0.9.0`** *(it is not a credential; the private key
> is)*. **The `app_id` rows above, and the `secrets: app_id:` lines in the usage examples, describe the
> `v0.8.1` contract those examples pin.** *Callers on `v0.9.0` or later pass `app_id` under `with:` —
> `tf-destroy.yml` has never accepted it as a secret, which is why it has no row here.*

Both secrets are optional but coupled — if `app_id` is present the workflow generates a short-lived token and configures git credentials; if absent the private-module steps are skipped entirely.

Store the values in the project repo as `SBE_DEVOPS_APP_ID` and `SBE_DEVOPS_APP_PRIVATE_KEY` and pass them through as shown in the usage examples. Do not generate the token in the calling workflow and pass it as a pre-built value — GitHub redacts masked secrets before they leave a job, so the token arrives empty in the reusable workflow.

---

## Permissions required

The calling job must declare every permission the reusable workflow's job uses. Permissions do not inherit automatically through a `uses:` boundary.

| Permission | Required for | Applies to |
|---|---|---|
| `id-token: write` | OIDC token exchange with AWS | `tf-plan.yml`, `tf-apply.yml`, `tf-destroy.yml` |
| `contents: read` | `actions/checkout` | all workflows |
| `pull-requests: write` | Posting the plan summary comment | `tf-plan.yml` only |

`tf-destroy.yml` needs **no** additional permission for its plan artifact — `actions/upload-artifact`
uses the run's own token.

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
