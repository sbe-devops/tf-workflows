# Changelog

All notable changes to `tf-workflows` are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This repo uses [semver](https://semver.org/).

---

## [Unreleased]

### Added

- **`tf-destroy.yml`** — reusable teardown for a **lower** environment: plan the destroy to a file, upload both the binary plan and its `terraform show` rendering as a 90-day artifact, then apply **that saved plan**. Never a bare `terraform destroy -auto-approve`, so the artifact is what actually ran rather than a second evaluation of it.

  **Why:** ADR-0045 Amendment 1 defines the lower-environment deliverable as change + teardown + stand-up, all through CI. This repo had a plan path and an apply path and **no destroy path**, so every teardown was a laptop holding enforcer credentials. Fitbooks adopts first.

  🔴 **The control is a caller-owned allow-list, and it fails closed.** `destroyable_directories` is a **required** input listed in the caller's own PR-gated workflow file; only an **exact** path match is destroyable, and an empty list makes nothing destroyable. ⇒ `tf/aws-bootstrap` (state bucket + lock table) and `tf/aws-github-oidc` (every CI role) are unreachable unless someone adds them in a reviewed PR. **A denylist would be destroyable-by-default, which is why there isn't one.**

  **The guard runs first — before `actions/checkout` and before any AWS credential exists**, so a refused run never holds a credential. A parent or child of a listed path, any `..`, any absolute path, and any glob are all refused. `..` is **refused rather than resolved**, because resolving it would make the guard, not the caller, the thing that decides what a path means. A glob in the allow-list is a **hard error naming globs** rather than a silent non-match: exact matching would refuse `tf/*` anyway, but a caller who believes patterns work will "fix" it by widening something else.

  **No `fmt -check`**, unlike `tf-apply.yml`: formatting gates what you are about to create, and blocking a teardown on cosmetics strands live resources until someone edits the stack.

- **`tf-destroy.yml` gained two more guards and an `environment` input (review round 2).**

  🔴 **The ref check (PROOF).** `workflow_dispatch` runs the workflow at whatever ref the dispatcher names, and the allow-list is read from the caller's file **at that ref** — so a branch that adds `tf/aws-bootstrap` to it needs no review, just a push and a dispatch. **Anything other than the default branch is refused**, and an undeterminable default branch is refused too rather than assumed to be `main` (a repo on `master` or `trunk` would otherwise be guessed at in whichever direction the guess went).

  🔴 **The workspace guard (INFRA, T1).** The allow-list is keyed on a **directory**; Terraform state is keyed on **(directory × workspace)**. For a workspace-per-environment stack, one entry therefore authorised **every** environment in that directory — and a fresh `init` selects `default`, so the run would have destroyed whatever lives in `default` while the operator was thinking of `staging`. **Any layout with more than the `default` workspace is now refused**, as is a non-`default` selection, a `TF_WORKSPACE` override, and a `workspace list` that fails. It refuses rather than selecting, because picking a workspace from a directory-keyed allow-list is a guess. *It runs after `init` because `workspace list` reads the backend; everything checkable before a credential exists already was.*

  **`environment` input (PROOF).** `jobs.<id>.environment` is **not valid on a `uses:` reusable-workflow call**, so the README's original `environment: teardown` example was not a thing Actions accepts — a caller cannot add a reviewer gate to a reusable workflow from outside. The gate is now an input the workflow applies to its own job. ⚠️ **Empty means no gate**, and that was measured rather than assumed: a throwaway branch called this workflow with the input omitted (run `37977151072`) and `Set up job` succeeded, so an empty environment expression resolves to no environment rather than failing the job.

  **README (INFRA, T2):** names the self-managing-backend case concretely — Fitbooks' `terraform/tst/bootstrap` holds the state bucket and lock table **every other stack's state lives in**, so destroying it removes the ability to plan, apply or destroy any of them, and the destroy's own state is in the bucket it is deleting. Also records that **the first real caller will fail on IAM** until the enforcer trust admits `tf-destroy.yml` by `job_workflow_ref` (INFRA's).

- **`tests/` + `ci.yml` — this repo now runs CI on itself, for the first time.** `tests/destroy-guard.sh` **extracts the guard's own bytes out of `tf-destroy.yml` and executes them** (58 assertions: allow-list matching, traversal, globs, the ref check, and the wiring), so there is no second copy of the logic to drift from. The extractor **fails closed** if the markers move, if the body shrinks, or if the guard grows a `${{ … }}` expression that would make the bytes un-runnable. 11 further assertions cover what the bytes cannot see: which input feeds which variable, that the guard precedes checkout/credentials/`init`, and that the apply applies the saved plan.

  `tests/workspace-guard.sh` does the same for the workspace guard against a **stubbed `terraform`** (11 cases), and `tests/mutate-destroy-guard.sh` weakens a guard **19 ways and requires a suite to go red each time**, printing the diff it applied — a harness that is silent on success cannot be told apart from one that did nothing. **Mapping `ALLOW_LIST` to the wrong input passes all 35 logic cases and is caught only by the wiring assertions**, which is the clearest argument for keeping both halves.

  **One live refusal is measured** — a throwaway branch dispatched the workflow at `tf/aws-bootstrap` (run `37977151072`, branch deleted) and every step after the guard shows `skipped`: no checkout, no credentials, no `init`, no plan. ⚠️ **What it did not prove:** it refused on the **ref** check, since a probe branch is by definition not the default branch, so the **allow-list** refusal is still shell-tested rather than observed live. A `uses:` job cannot be `continue-on-error`, so an in-repo "expect this to fail" job would just be a red check.

- `tf-module-ci.yml` now runs **`terraform test`** when the module ships `*.tftest.hcl` files, and **fails the job** when they fail. Auto-detected (`find . -maxdepth 2 -name '*.tftest.hcl'`), which covers both the module root and the default `tests/` directory — no new input, because the presence of the files is the opt-in. A module with no tests **skips** the step and is unaffected; the PR comment renders that as `⏭️ no *.tftest.hcl` rather than as a pass or a fail.

  **Why:** `tf-aws-ecr#3` shipped 1,239 lines of trust-policy test — a 491-line native suite, two golden policy documents, and a mutation harness whose weakenings `terraform test` catches *even when the golden is regenerated to agree* — and **this workflow ran none of it.** The PR went green on `fmt`/TFLint/Checkov/`validate` alone, so a later commit could have reverted the trust policy to its wide-open form unnoticed.

  **It also closes a second gap that was easy to miss:** a variable `validation` block fires at **plan** time with real values, not at `terraform validate`, so a module's own input guards were never exercised either. `terraform test` is the only step in this workflow that reaches either one.

  ⚠️ **Tests must mock their providers.** This job holds no AWS credentials by design, so a `run` block that reaches a real provider will fail — correctly, because it needs `mock_provider`, not secrets.

- README now documents `tf-module-ci.yml`, which shipped in `v0.10.0` and was never added to the Workflows section or the Inputs table.

### Fixed
- README now says that **`app_id` became an input rather than a secret in `v0.9.0`**. The Secrets table and the usage examples describe the `v0.8.1` contract they pin, which reads as current — a caller on `v0.10.1` following the Secrets table would pass an undeclared secret and fail. The examples' pins are untouched here; this only states which contract they show.

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
