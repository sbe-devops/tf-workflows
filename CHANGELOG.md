# Changelog

All notable changes to `tf-workflows` are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This repo uses [semver](https://semver.org/).

---

## [Unreleased]

### Added

- **`tf-plan.yml` and `tf-apply.yml` accept an `environment` input**, and both report the Environment they are running in before assuming a role. `tf-destroy.yml` got the same input in #6.

  **Why:** ADR-0046 Amendment 4 makes one live check the gate — every GitHub-OIDC role in an upper account must pin the `environment` claim to a named GitHub Environment. A token carries that claim only when its **job** runs in one, and 🔴 **`jobs.<id>.environment` is not a valid key on a `uses:` reusable-workflow call**, so a caller cannot put these jobs in an Environment from outside. **Without these inputs, no caller can satisfy Amendment 4 at all.**

  ⚠️ **The Environment name is one string duplicated across two repositories** — this input, and the enforcer trust in the consumer's `tf-aws-github-oidc` stack. Omitting it, or a typo, yields `Not authorized to perform sts:AssumeRoleWithWebIdentity` — **the same message as "not opted in", "wrong branch", and "Environment does not exist"**. So each job now echoes the resolved Environment *before* the credential step and emits a `::warning` when there is none. Fail-closed either way; this is what makes it diagnosable.

  🔴 **Open question, flagged rather than decided:** `tf-plan.yml` runs on `pull_request`, so an Environment with **required reviewers** makes every PR plan wait on a human. An Environment can exist without protection rules and still produce the claim, so the structural check can be met without gating PRs — but which way a consumer should go is a policy call, not a workflow one.

- `tf-module-ci.yml` now runs **`terraform test`** when the module ships `*.tftest.hcl` files, and **fails the job** when they fail. Auto-detected (`find . -maxdepth 2 -name '*.tftest.hcl'`), which covers both the module root and the default `tests/` directory — no new input, because the presence of the files is the opt-in. A module with no tests **skips** the step and is unaffected; the PR comment renders that as `⏭️ no *.tftest.hcl` rather than as a pass or a fail.

  **Why:** `tf-aws-ecr#3` shipped 1,239 lines of trust-policy test — a 491-line native suite, two golden policy documents, and a mutation harness whose weakenings `terraform test` catches *even when the golden is regenerated to agree* — and **this workflow ran none of it.** The PR went green on `fmt`/TFLint/Checkov/`validate` alone, so a later commit could have reverted the trust policy to its wide-open form unnoticed.

  **It also closes a second gap that was easy to miss:** a variable `validation` block fires at **plan** time with real values, not at `terraform validate`, so a module's own input guards were never exercised either. `terraform test` is the only step in this workflow that reaches either one.

  ⚠️ **Tests must mock their providers.** This job holds no AWS credentials by design, so a `run` block that reaches a real provider will fail — correctly, because it needs `mock_provider`, not secrets.

- README now documents `tf-module-ci.yml`, which shipped in `v0.10.0` and was never added to the Workflows section or the Inputs table.

### Known gaps, not changed here

- **TFLint findings do not fail the build.** `tflint` runs with `continue-on-error: true` and, unlike `fmt` and `validate`, has no corresponding `Fail if …` step — so its result is reported in the PR comment and otherwise advisory. Checkov is explicitly `soft_fail: true`. Deliberately left alone: making either blocking is a behaviour change across every `tf-aws-*` consumer and belongs in its own decision, not in a release that adds a different gate.

---

## [v0.10.0] - 2026-07-20

### Added

- `tf-module-ci.yml` — reusable CI for TF **module** repos (`tf-aws-*`), as opposed to consumer/project repos. Validates the module in isolation with no backend/state/AWS credentials needed: `terraform fmt -check`, TFLint, Checkov (soft-fail), `terraform init -backend=false`, `terraform validate`. Every SBE TF module currently ships with only `release-drafter.yml` and no actual CI -- this is the gap-fill, starting with `tf-aws-vpc` and `tf-aws-eks-argocd-capability`.

---

## [v0.8.1] - 2026-05-08

### Fixed

- `terraform init -upgrade` replaces plain `terraform init` in both `tf-plan.yml` and `tf-apply.yml` so pinned module sources are always re-fetched from the declared `?ref=` tag rather than the runner cache.

---

## [v0.8.0] - 2026-05-06

### Changed

- GitHub App token is now generated **inside** the reusable workflow using `actions/create-github-app-token`. Callers pass `app_id` and `app_private_key` as secrets instead of a pre-generated token.
- Removed the `module_token` secret from both workflows. The v0.7.0 pattern of generating a token in the calling workflow and passing it via job outputs was broken — GitHub redacts masked secret values before they leave a job, so the token arrived empty.

### Migration from v0.7.0

Replace the calling-workflow token-generation step and `secrets.module_token` with the two App credential secrets:

```yaml
secrets:
  app_id: ${{ secrets.SBE_DEVOPS_APP_ID }}
  app_private_key: ${{ secrets.SBE_DEVOPS_APP_PRIVATE_KEY }}
```

---

## [v0.7.0] - 2026-05-06

### Changed

- Moved GitHub App token generation into the calling workflow. Reusable workflow accepted a `module_token` secret.

Note: this pattern was superseded by v0.8.0 due to GitHub secret-masking behavior.

---

## [v0.6.1] - 2026-05-06

### Fixed

- Corrected GitHub App step conditional — mapped `secrets.app_id` to a job-level `APP_ID` env var and switched step `if:` conditions to reference `env.APP_ID`. The `secrets` context is invalid in step `if:` expressions and caused a workflow schema error.

---

## [v0.6.0] - 2026-05-06

### Changed

- Replaced PAT-based private module access with GitHub App credentials (`app_id` + `app_private_key` secrets). Tokens are short-lived, require no expiry management, and satisfy the CC6.1 short-lived credential requirement.

---

## [v0.5.0] - 2026-05-06

### Added

- `app_id` and `app_private_key` secrets accepted by both workflows. When present, configures git URL rewrite so `terraform init` can fetch private `sbe-devops` module repos.

---

## [v0.4.0] - 2026-05-06

### Added

- `terraform validate` step added to `tf-plan.yml` after `terraform init`, before `terraform plan`.

---

## [v0.3.0] - 2026-05-06

### Fixed

- Pinned `bridgecrewio/checkov-action` to `v12.1347.0` to prevent unexpected upstream changes.

---

## [v0.2.0] - 2026-05-05

### Changed

- Removed GitHub Environment reviewer gates from the plan and apply jobs. Environment protection is now the caller's responsibility, applied in the calling workflow (e.g., via `environment: prod` on the calling job).

---

## [v0.1.0] - 2026-05-05

### Added

- Initial `tf-plan.yml`: fmt check, TFLint, Checkov, `terraform init`, validate, plan, PR comment.
- Initial `tf-apply.yml`: fmt check, `terraform init`, `terraform apply -auto-approve`.
- OIDC-based AWS credential exchange in both workflows via `aws-actions/configure-aws-credentials`.
- `working_directory`, `aws_region`, `role_arn`, `terraform_version` inputs in both workflows.
- `tflint_version` input in `tf-plan.yml`.
