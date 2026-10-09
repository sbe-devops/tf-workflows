#!/usr/bin/env bash
#
# tests/environment-input.sh — the `environment` input must be WIRED, in both
# workflows, and the report step must run before any credential exists.
#
# 🔑 WHY STATIC ASSERTIONS AND NOT A RUN. What ADR-0046 Amendment 4 needs is that
# the JOB runs in a GitHub Environment, which is a property of the job's
# definition — there is no runtime behaviour to exercise. The failure mode is a
# declaration that drifts: an input added and never referenced, a job key
# pointing at the wrong input, or the report step sliding below the credential
# step where it can no longer explain an AccessDenied.
#
# That class is exactly what the destroy guard's wiring assertions caught
# (mapping ALLOW_LIST to the wrong input passed every behavioural case), so it
# gets the same treatment.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0
fail=0

check() {
  local label="$1" file="$2" expr="$3" why="$4"
  if grep -qE -- "$expr" "$here/../.github/workflows/$file"; then
    printf '✅ %s · %s\n' "$file" "$label"
    pass=$((pass + 1))
  else
    printf '❌ FAIL  %s · %s\n        %s\n        no line matches: %s\n' "$file" "$label" "$why" "$expr"
    fail=$((fail + 1))
  fi
}

# order <file> <earlier-pattern> <later-pattern> <why>
order() {
  local file="$1" earlier="$2" later="$3" why="$4" a b path
  path="$here/../.github/workflows/$file"
  a="$(grep -nE -- "$earlier" "$path" | head -1 | cut -d: -f1)"
  b="$(grep -nE -- "$later" "$path" | head -1 | cut -d: -f1)"
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then
    printf '✅ %s · the environment report precedes the credential step\n' "$file"
    pass=$((pass + 1))
  else
    printf '❌ FAIL  %s · ordering (report=%s, credentials=%s)\n        %s\n' "$file" "${a:-?}" "${b:-?}" "$why"
    fail=$((fail + 1))
  fi
}

# Every workflow that assumes a role must be able to carry the claim.
# ⚠️ tf-destroy.yml is included and may be ABSENT on this branch (it arrives with
# tf-workflows#6) — the loop skips what is not there rather than failing, so this
# suite does not depend on the merge order of two open PRs.
for wf in tf-apply.yml tf-plan.yml tf-destroy.yml; do
  [ -f "$here/../.github/workflows/$wf" ] || continue

  check "declares an environment input" "$wf" \
    '^      environment:$' \
    "without the input, a caller cannot put the job in an Environment at all: environment is not a valid key on a uses: job"

  check "the input is a string defaulting to empty" "$wf" \
    '^        default: ""$' \
    "a required environment would break every existing caller on the version bump"

  check "the job key reads that input" "$wf" \
    '^    environment: \$\{\{ inputs\.environment \}\}$' \
    "an input nothing references is a declaration, not a control"
done

# 🔑 THE REPORT STEP IS ASSERTED ONLY WHERE IT EXISTS YET. tf-destroy.yml gets
# the same step, but it is open as tf-workflows#6 and under review — pushing to
# it would void that review, so the step and its assertion land together
# afterwards. Writing the assertion now would mean this suite goes RED the moment
# #6 merges, which is a test that breaks on someone else's merge order rather
# than on a defect.
for wf in tf-apply.yml tf-plan.yml; do
  check "the report step passes the input through env:" "$wf" \
    '^          GH_ENVIRONMENT: \$\{\{ inputs\.environment \}\}$' \
    "the report would otherwise describe a different value than the job runs in"

  check "and warns when there is no environment" "$wf" \
    '::warning title=No GitHub Environment::' \
    "a silent empty environment is the AccessDenied nobody can diagnose"

  # Anchored on the step NAMES. An unanchored match hits the comment that
  # mentions the credential step, which is how this assertion first reported a
  # false failure — the same comment-vs-code trap as tests/destroy-guard.sh.
  order "$wf" '^      - name: Report the GitHub Environment' '^      - name: Configure AWS credentials' \
    "the report exists to explain a credential failure, so it must be above it"
done

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
