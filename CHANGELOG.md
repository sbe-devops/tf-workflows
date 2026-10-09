# Changelog

All notable changes to `tf-workflows` are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This repo uses [semver](https://semver.org/).

---

## [Unreleased]

### Added

- **`tf-module-ci.yml`'s `terraform test` gate now detects both test syntaxes and fails when zero runs execute.** Two ways the gate shipped in `v0.11.0`'s predecessor could pass without testing anything (PROOF, review round 2 — which arrived after that PR had merged):

  · **`*.tftest.json` was not detected at all.** A JSON-only suite was skipped and the job went **green on no tests**. Detection now matches `*.tftest.hcl` **and** `*.tftest.json`.

  · **`-maxdepth 2` found more than `terraform test` runs, not less.** `examples/foo.tftest.hcl` was detected, terraform ignored it, and the run executed **zero** tests and still exited 0 — printing `Success! 0 passed, 0 failed.` Detection is now depth-unlimited *on purpose*: a test file anywhere means the module **intends** tests, and the new assertion reports it when terraform does not run them, rather than detection quietly deciding which paths count.

  🔴 **New step: `Assert the tests actually executed`.** It parses the run summary and **fails when `passed + failed == 0`**, when no summary can be found at all, and when no output was captured. The PR comment gains a third state — `❌ files found, zero runs executed` — because rendering that as a pass is the defect and rendering it as a skip would hide it.

  *Why it matters beyond this repo:* the original comment claimed `-maxdepth 2` covered "exactly" what terraform runs. It was wrong in both directions, and nothing could have caught it, because **the gate's failure mode was to pass.** `tests/` + `ci.yml` now run both gates' own bytes and 6 mutations against them.

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
