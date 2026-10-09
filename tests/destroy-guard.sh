#!/usr/bin/env bash
#
# tests/destroy-guard.sh — the destroy allow-list guard, tested against its own bytes.
#
# 🔑 WHY IT IS SHAPED THIS WAY. `tf-destroy.yml` is a reusable workflow, so its guard runs
# only inside a real destroy run. A test that REIMPLEMENTED the guard would prove that the
# copy works; this one extracts the lines between `# >>> GUARD BEGIN` and `# <<< GUARD END`
# in the workflow and executes those exact bytes. There is no second copy to drift.
#
# 🔴 THE EXTRACTOR FAILS CLOSED. If the markers are missing, the body is suspiciously
# short, or the guard has grown a `${{ … }}` GitHub context (which would make the bytes
# un-runnable outside Actions), this script ERRORS. A test that silently stops testing is
# the failure mode it exists to prevent.
#
# Usage: tests/destroy-guard.sh        (exit 0 = every case behaved as asserted)

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workflow="$here/../.github/workflows/tf-destroy.yml"

[ -f "$workflow" ] || { echo "FATAL: $workflow not found"; exit 2; }

# ── extract ───────────────────────────────────────────────────────────────────────────────
raw="$(awk '
  /# >>> GUARD BEGIN/ { inside = 1; next }
  /# <<< GUARD END/   { inside = 0; next }
  inside             { print }
' "$workflow")"

[ -n "$raw" ] || { echo "FATAL: guard markers not found in $workflow — the extractor cannot see the guard, so nothing below is tested"; exit 2; }

# Strip the YAML block indentation using the FIRST line's indent, so nested shell
# indentation survives.
indent="$(printf '%s\n' "$raw" | sed -n '1s/^\([[:space:]]*\).*/\1/p')"
guard="$(printf '%s\n' "$raw" | sed "s/^${indent}//")"

lines="$(printf '%s\n' "$guard" | wc -l | tr -d ' ')"
if [ "$lines" -lt 25 ]; then
  echo "FATAL: the extracted guard is only $lines lines — that is not the guard, it is a fragment"
  exit 2
fi
# shellcheck disable=SC2016  # matching the LITERAL characters ${{ is the whole point
case "$guard" in
  *'${{'*)
    echo "FATAL: the guard body contains a GitHub expression (\${{ … }}). Keep every context in the step's env: block, or this test stops running the same bytes the workflow runs."
    exit 2
    ;;
esac
printf 'extracted %s lines of guard from %s\n\n' "$lines" "${workflow#"$here/../"}"

# ── harness ───────────────────────────────────────────────────────────────────────────────
pass=0
fail=0

# run_guard <candidate> <allow-list> [caller-ref] [default-branch]
#
# The ref pair defaults to a valid default-branch call, so every case below
# isolates the thing it names. The ref check has its own section.
run_guard() {
  CANDIDATE="$1" ALLOW_LIST="$2" \
    CALLER_REF="${3-refs/heads/main}" DEFAULT_BRANCH="${4-main}" \
    bash -c "$guard" 2>&1
}

# refuses <name> <candidate> <allow-list> [expected substring in the message]
refuses() {
  local name="$1" candidate="$2" allow="$3" expect="${4:-}" out rc
  # Unset-only defaults: an explicitly EMPTY ref or default branch is a case,
  # not a missing argument, and `${5:-x}` would have silently substituted it.
  out="$(run_guard "$candidate" "$allow" "${5-refs/heads/main}" "${6-main}")"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '❌ FAIL  %s\n        ALLOWED what must be refused (exit 0): candidate=%s\n' "$name" "$candidate"
    fail=$((fail + 1))
    return
  fi
  if [ -n "$expect" ] && ! printf '%s' "$out" | grep -qF -- "$expect"; then
    printf '❌ FAIL  %s\n        refused, but the message does not explain why.\n        wanted: %s\n        got:    %s\n' "$name" "$expect" "$out"
    fail=$((fail + 1))
    return
  fi
  printf '✅ refused  %s\n' "$name"
  pass=$((pass + 1))
}

# allows <name> <candidate> <allow-list>
allows() {
  local name="$1" candidate="$2" allow="$3" out rc
  out="$(run_guard "$candidate" "$allow")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '❌ FAIL  %s\n        REFUSED what must be allowed (exit %s): %s\n' "$name" "$rc" "$out"
    fail=$((fail + 1))
    return
  fi
  printf '✅ allowed  %s\n' "$name"
  pass=$((pass + 1))
}

# A realistic caller allow-list: two lower stacks, listed exactly.
ALLOW_FITBOOKS='terraform/test
terraform/poc'

# A client's real directory layout, where the two paths that must NEVER be destroyable are
# the ones that would take every other stack's state and every OIDC role with them.
ALLOW_MODULES='tf/aws-vpc
tf/aws-rds'

echo "── THE ASK: a bootstrap path is REFUSED ─────────────────────────────────────────────"
refuses "tf/aws-bootstrap (state bucket + lock table) is not on the list" \
  "tf/aws-bootstrap" "$ALLOW_MODULES" "is not on this caller's destroy allow-list"
refuses "tf/aws-github-oidc (every CI role) is not on the list" \
  "tf/aws-github-oidc" "$ALLOW_MODULES" "is not on this caller's destroy allow-list"
refuses "terraform/prod is not on the list" \
  "terraform/prod" "$ALLOW_FITBOOKS" "is not on this caller's destroy allow-list"

echo
echo "── fail closed ─────────────────────────────────────────────────────────────────────"
refuses "an empty allow-list makes nothing destroyable" \
  "terraform/test" "" "nothing is destroyable"
refuses "a whitespace-only allow-list is still empty" \
  "terraform/test" "$(printf '  \n\t\n')" "nothing is destroyable"
refuses "an empty working_directory" \
  "" "$ALLOW_FITBOOKS" "working_directory is empty"
refuses "a whitespace-only working_directory" \
  "   " "$ALLOW_FITBOOKS" "working_directory is empty"

echo
echo "── the match is EXACT, not a prefix and not a suffix ───────────────────────────────"
refuses "a parent of an allowed path (would take both stacks)" \
  "terraform" "$ALLOW_FITBOOKS" "is not on this caller"
refuses "a child of an allowed path" \
  "terraform/test/modules/vpc" "$ALLOW_FITBOOKS" "is not on this caller"
refuses "a path that merely starts the same" \
  "terraform/test-prod" "$ALLOW_FITBOOKS" "is not on this caller"
refuses "a path that merely ends the same" \
  "other/terraform/test" "$ALLOW_FITBOOKS" "is not on this caller"
refuses "case differs — Linux paths are case-sensitive and so is this" \
  "Terraform/Test" "$ALLOW_FITBOOKS" "is not on this caller"

echo
echo "── traversal and absolute paths are refused, never resolved ────────────────────────"
refuses "traversal out of an allowed path" \
  "terraform/test/../prod" "$ALLOW_FITBOOKS" 'contains ".."'
refuses "traversal that lands back on an allowed path" \
  "terraform/poc/../test" "$ALLOW_FITBOOKS" 'contains ".."'
refuses "bare .." \
  ".." "$ALLOW_FITBOOKS" 'contains ".."'
refuses "an absolute path" \
  "/terraform/test" "$ALLOW_FITBOOKS" "is absolute"
refuses "an absolute path to somewhere else entirely" \
  "/etc" "$ALLOW_FITBOOKS" "is absolute"

echo
echo "── globs are an ERROR, on either side, so nobody concludes patterns work ───────────"
refuses "a glob in the candidate" \
  "terraform/*" "$ALLOW_FITBOOKS" "contains a glob character"
refuses "a glob entry in the allow-list" \
  "terraform/test" 'terraform/*' "Globs are NOT supported"
refuses "a glob entry is reported even when another entry matches" \
  "terraform/test" 'terraform/test
tf/*' "Globs are NOT supported"
refuses "a ? wildcard entry" \
  "terraform/test" 'terraform/tes?' "Globs are NOT supported"
refuses "a bracket-expression entry" \
  "terraform/test" 'terraform/[tp]est' "Globs are NOT supported"
refuses "an absolute allow-list entry" \
  "terraform/test" '/terraform/test' "is absolute"
refuses "a traversal in an allow-list entry" \
  "terraform/test" 'terraform/poc/../test' 'contains ".."'

echo
echo "── and the allow path, which is what makes the refusals mean something ─────────────"
allows "an exact match on the first entry"  "terraform/test" "$ALLOW_FITBOOKS"
allows "an exact match on the last entry"   "terraform/poc"  "$ALLOW_FITBOOKS"
allows "./ prefix normalised on the candidate"  "./terraform/test" "$ALLOW_FITBOOKS"
allows "trailing slash normalised on the candidate" "terraform/test/" "$ALLOW_FITBOOKS"
allows "./ prefix normalised on the entry"   "terraform/test" './terraform/test'
allows "trailing slash normalised on the entry" "terraform/test" 'terraform/test/'
allows "surrounding whitespace on the entry" "terraform/test" '   terraform/test   '
allows "CRLF line endings in the allow-list" "terraform/poc" "$(printf 'terraform/test\r\nterraform/poc\r\n')"
allows "blank lines in the allow-list"       "terraform/poc" "$(printf 'terraform/test\n\n\nterraform/poc\n')"
allows "no trailing newline on the last entry" "terraform/poc" "$(printf 'terraform/test\nterraform/poc')"
allows "a single-entry allow-list"           "tf/aws-vpc" "tf/aws-vpc"

echo
echo "── the allow-list is only a control at the ref where changing it needs review ──────"
# 🔴 PROOF r2: `workflow_dispatch` runs at ANY ref, and the allow-list is read
# from the caller's file AT THAT REF — so a branch that adds tf/aws-bootstrap to
# it needs no review, just a push and a dispatch.
refuses "a feature branch, even with the path allow-listed" \
  "terraform/test" "$ALLOW_FITBOOKS" "not at refs/heads/main" "refs/heads/patch/sneak-bootstrap" "main"
refuses "a tag" \
  "terraform/test" "$ALLOW_FITBOOKS" "not at refs/heads/main" "refs/tags/v1.0.0" "main"
refuses "a PR merge ref" \
  "terraform/test" "$ALLOW_FITBOOKS" "not at refs/heads/main" "refs/pull/7/merge" "main"
refuses "the default branch of a DIFFERENT name than the ref" \
  "terraform/test" "$ALLOW_FITBOOKS" "not at refs/heads/trunk" "refs/heads/main" "trunk"
refuses "an unknown default branch is not assumed to be main" \
  "terraform/test" "$ALLOW_FITBOOKS" "cannot determine this repository's default branch" "refs/heads/main" ""
refuses "an empty caller ref" \
  "terraform/test" "$ALLOW_FITBOOKS" "not at refs/heads/main" " " "main"
# …and a repo whose default branch is not `main` still works on its own default.
allows_at_ref() {
  local name="$1" ref="$2" def="$3" out rc
  out="$(run_guard "terraform/test" "$ALLOW_FITBOOKS" "$ref" "$def")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '❌ FAIL  %s\n        REFUSED (exit %s): %s\n' "$name" "$rc" "$out"
    fail=$((fail + 1))
    return
  fi
  printf '✅ allowed  %s\n' "$name"
  pass=$((pass + 1))
}
allows_at_ref "the default branch, main"   "refs/heads/main"   "main"
allows_at_ref "the default branch, master" "refs/heads/master" "master"
allows_at_ref "the default branch, trunk"  "refs/heads/trunk"  "trunk"

echo
echo "── the wiring, which the guard's own bytes CANNOT see ──────────────────────────────"
# 🔑 Everything above proves the guard LOGIC. None of it would notice ALLOW_LIST being
# mapped to the wrong input, or the guard being moved below `configure-aws-credentials`,
# because both live in the YAML around the body rather than in the body. A reusable
# workflow cannot be run end-to-end from here, so these are asserted statically.

# Comments mention the shapes they forbid, which is the point of a comment. Assert against
# the EXECUTABLE lines only, or every explanation of a banned command reads as the command.
stripped="$(mktemp)"
trap 'rm -f "$stripped"' EXIT
grep -vE '^[[:space:]]*#' "$workflow" > "$stripped"

# asserts <name> <grep-expression> <why>
asserts() {
  local name="$1" expr="$2" why="$3"
  if grep -qE -- "$expr" "$stripped"; then
    printf '✅ wired    %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '❌ FAIL  %s\n        %s\n        no line matches: %s\n' "$name" "$why" "$expr"
    fail=$((fail + 1))
  fi
}

# denies <name> <grep-expression> <why>
denies() {
  local name="$1" expr="$2" why="$3"
  if grep -qE -- "$expr" "$stripped"; then
    printf '❌ FAIL  %s\n        %s\n        matched: %s\n' "$name" "$why" "$(grep -nE -- "$expr" "$stripped" | head -1)"
    fail=$((fail + 1))
  else
    printf '✅ absent   %s\n' "$name"
    pass=$((pass + 1))
  fi
}

asserts "CALLER_REF comes from github.ref" \
  '^ +CALLER_REF: \$\{\{ github\.ref \}\}$' \
  "the ref check would otherwise read an empty string and refuse everything, or nothing and refuse nothing"
asserts "DEFAULT_BRANCH comes from the event payload" \
  '^ +DEFAULT_BRANCH: \$\{\{ github\.event\.repository\.default_branch \}\}$' \
  "hard-coding main here would be a guess about every consumer's repo"
asserts "the workspace guard exists and runs after init" \
  '^ +- name: Refuse a workspace layout the allow-list cannot describe$' \
  "T1: a directory-keyed allow-list cannot describe (directory x workspace)"
asserts "CANDIDATE comes from inputs.working_directory" \
  '^ +CANDIDATE: \$\{\{ inputs\.working_directory \}\}$' \
  "the guard would otherwise check a different string than the one terraform runs in"
asserts "ALLOW_LIST comes from inputs.destroyable_directories" \
  '^ +ALLOW_LIST: \$\{\{ inputs\.destroyable_directories \}\}$' \
  "every case above would still pass with this mapped to the wrong input"
asserts "destroyable_directories is a required input" \
  '^ +destroyable_directories:$' \
  "an optional allow-list is one a caller can forget"

# `required: true` on the allow-list, read from the input's own block rather than from
# anywhere in the file.
if awk '
  /^      destroyable_directories:$/ { inblock = 1; next }
  inblock && /^      [a-z_]+:$/      { inblock = 0 }
  inblock && /^        required: true$/ { found = 1 }
  END { exit (found ? 0 : 1) }
' "$workflow"; then
  printf '✅ wired    destroyable_directories declares required: true\n'
  pass=$((pass + 1))
else
  printf '❌ FAIL  destroyable_directories is not declared required: true\n'
  fail=$((fail + 1))
fi

# The guard must run before anything that costs a credential or a checkout.
guard_line="$(grep -n 'Refuse a working_directory' "$workflow" | head -1 | cut -d: -f1)"
for after in 'uses: actions/checkout@v4' 'Configure AWS credentials' 'Terraform Init'; do
  line="$(grep -n -- "$after" "$workflow" | head -1 | cut -d: -f1)"
  if [ -n "$guard_line" ] && [ -n "$line" ] && [ "$guard_line" -lt "$line" ]; then
    printf '✅ ordered  the guard precedes "%s"\n' "$after"
    pass=$((pass + 1))
  else
    printf '❌ FAIL  the guard does not precede "%s" (guard=%s, step=%s)\n        a refused run must never hold a credential\n' "$after" "${guard_line:-?}" "${line:-?}"
    fail=$((fail + 1))
  fi
done

asserts "the destroy is PLANNED to a file" \
  'terraform plan -destroy .*-out=destroy\.tfplan' \
  "a teardown that is not planned to a file cannot be uploaded as evidence"
asserts "and the APPLY applies that saved plan" \
  'terraform apply -input=false destroy\.tfplan' \
  "applying anything else re-evaluates what a human already read"
# 🔴 THE DESTROY PLAN AND APPLY STEPS ARE PINNED AS LITERALS, not checked for
# the absence of one bad spelling. Measured on tf-aws-bootstrap#2:
# `terraform plan -destroy` against a `prevent_destroy` resource exits 1 AND
# STILL WRITES THE PLAN FILE, which `terraform show` renders as a destroy with
# "planned the following actions, but then encountered a problem". So the only
# thing stopping the apply is the plan step failing the job.
#
# ⚠️ MY FIRST VERSION GREPPED FOR `continue-on-error: true` AND PROOF BROKE IT
# IN THREE WAYS (r2): `continue-on-error: ${{ true }}`, `if: always()` on the
# apply, and `run: … || true` on the plan. A denylist of the spellings I thought
# of is not a control — the same lesson as the trust grader's operators, and as
# `tf-aws-ecr`'s goldens. So this is an ALLOW-LIST: the block must be EXACTLY
# these lines, and anything added to it fails, without anyone predicting what.
assert_step_block() {
  local label="$1" expected="$2" got
  # The step's own lines: from its `- name:` up to the next step, comment or
  # blank line at step indentation. Trailing whitespace is stripped so the
  # comparison is about content, not editors.
  # 🔴 THE EXTRACTOR ENDS WHERE *YAML* ENDS THE STEP, not at the first blank or
  # comment. PROOF r3 broke the first version two ways, both actionlint-valid
  # and both parsed by PyYAML as keys ON the step:
  #   · a BLANK line, then `continue-on-error: true`  (plan)
  #   · a step-indented `# …`, then `if: always()`    (apply)
  # Stopping early meant the pin compared the first three lines and shrugged at
  # whatever followed. So: blanks and comments are SKIPPED and collection
  # continues; the block ends only at the next step or at a dedent.
  got="$(printf '%s' "$expected" | head -1 | { read -r first; awk -v first="$first" '
    index($0, first)   { inblock = 1; print; next }
    !inblock           { next }
    /^      - name: /  { exit }            # the next step
    /^[[:space:]]*$/   { next }            # blank: skip, keep looking
    /^[[:space:]]*#/   { next }            # comment: skip, keep looking
    /^        [^ ]/    { print; next }     # a key of THIS step (8 spaces)
    { exit }                               # dedent: the steps list is over
  ' "$workflow"; })"
  if [ "$got" = "$expected" ]; then
    printf '✅ pinned   %s is exactly the expected block\n' "$label"
    pass=$((pass + 1))
  else
    printf '❌ FAIL  %s does not match the pinned block\n' "$label"
    printf '        expected:\n%s\n        got:\n%s\n' "$expected" "${got:-<nothing>}"
    fail=$((fail + 1))
  fi
}

# shellcheck disable=SC2016  # the ${{ … }} in these literals is YAML the
# workflow contains, not a shell expansion — expanding it would defeat the pin.
# 🔑 THESE LITERALS ARE THE INVARIANT. A reviewer reading a diff here is reading
# exactly what will run against a real state file. Changing the command is
# allowed; changing it WITHOUT changing this literal is not.
assert_step_block "the destroy PLAN step" '      - name: Terraform Plan (destroy)
        run: terraform plan -destroy -input=false -no-color -out=destroy.tfplan
        working-directory: ${{ inputs.working_directory }}'

# shellcheck disable=SC2016  # same: YAML, not a shell expansion
assert_step_block "the destroy APPLY step" '      - name: Terraform Apply (the saved destroy plan)
        run: terraform apply -input=false destroy.tfplan
        working-directory: ${{ inputs.working_directory }}'

denies "no bare 'terraform destroy' anywhere" \
  'terraform destroy' \
  "a bare destroy bypasses the plan artifact entirely"
denies "no --auto-approve on a destroy" \
  'destroy.*-auto-approve|-auto-approve.*destroy' \
  "the saved plan is the approval; -auto-approve would make the artifact decorative"

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
