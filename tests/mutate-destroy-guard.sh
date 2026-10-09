#!/usr/bin/env bash
#
# tests/mutate-destroy-guard.sh — does destroy-guard.sh actually CATCH a weakened guard?
#
# 🔑 "35 tests pass" is a count, not a claim. This weakens the guard one way at a time and
# requires the suite to go RED each time. A mutation that SURVIVES names a hole in the
# tests, not in the guard.
#
# ⚠️ EACH MUTATION RUNS IN ITS OWN PRISTINE COPY. Mutating one working tree in sequence
# means the second mutation lands on the first one's output — I read my own side effects as
# the module's state once already (tf-aws-ecr#3, 2026-10-08) and nearly filed a working
# harness as broken.
#
# Every mutation PRINTS the line it changed. A harness that is silent on success is a
# harness you cannot tell apart from a harness that did nothing.
#
# Usage: tests/mutate-destroy-guard.sh

# shellcheck disable=SC2016  # every single-quoted string here is a sed or perl PROGRAM;
# $entry and $candidate are the guard's variables and must reach sed unexpanded.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
workflow_rel=".github/workflows/tf-destroy.yml"

killed=0
survived=0
survivors=()

# 🔴 DECLARED COUNT. M22's call once contained `${{` inside a double-quoted
# string, which bash reads as a bad substitution — so the call never executed,
# nothing printed, and the run reported "23 killed, 0 survived" while LOOKING
# completely healthy. A mutation that silently never runs is the same class of
# failure as a sed that changes nothing, and the harness could not see it.
# Keep this in step with the mutate/mutate_prog calls below.
EXPECTED_MUTATIONS=27

tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

# mutate      <name> <sed-expression> <why it must be caught>
# mutate_prog <name> <program> <program-arg…> — for a mutation a line edit cannot express
#
# Reordering two steps is not a line edit, and a mutation you cannot express is a mutation
# you quietly stop running — so there are two front doors onto the same body.
mutate() {
  _mutate "$1" "$3" sed -i.bak "$2"
}

mutate_prog() {
  local name="$1" why="$2"
  shift 2
  _mutate "$name" "$why" "$@"
}

# _mutate <name> <why> <program> <program-arg…> — the file path is appended as the last arg
_mutate() {
  local name="$1" why="$2"
  shift 2
  # One temp tree per mutation, removed by the EXIT trap at the bottom of this file. A
  # `trap … RETURN` here looks tidier and is wrong: a RETURN trap is not scoped to the
  # function that set it, so it fires again in the caller where $work is already gone.
  local work
  work="$(mktemp -d "$tmproot/mutant.XXXXXX")"

  mkdir -p "$work/.github/workflows" "$work/tests"
  cp "$root/$workflow_rel" "$work/$workflow_rel"
  cp "$here/destroy-guard.sh" "$work/tests/destroy-guard.sh"
  cp "$here/workspace-guard.sh" "$work/tests/workspace-guard.sh"

  "$@" "$work/$workflow_rel"
  rm -f "$work/$workflow_rel.bak"

  local diff_out
  diff_out="$(diff "$root/$workflow_rel" "$work/$workflow_rel" || true)"
  if [ -z "$diff_out" ]; then
    printf '⚠️  NO-OP  %s\n        the mutation changed nothing — the anchor has moved and this mutation tested nothing\n' "$name"
    survived=$((survived + 1))
    survivors+=("$name (no-op)")
    return
  fi

  printf '— %s\n' "$name"
  printf '%s\n' "$diff_out" | sed 's/^/        /'

  # BOTH suites: a mutation to either guard must be caught by something, and a
  # harness that only runs one of them would report the other as unkillable.
  local out out2 rc rc2
  out="$(cd "$work" && bash tests/destroy-guard.sh 2>&1)"
  rc=$?
  out2="$(cd "$work" && bash tests/workspace-guard.sh 2>&1)"
  rc2=$?
  if [ "$rc" -eq 0 ] && [ "$rc2" -ne 0 ]; then
    rc=$rc2
    out=$out2
  fi
  if [ "$rc" -ne 0 ]; then
    printf '  ✅ KILLED (exit %s) — %s\n' "$rc" "$why"
    printf '%s\n' "$out" | grep -E '^(❌ FAIL|FATAL)' | head -4 | sed 's/^/        /'
    killed=$((killed + 1))
  else
    printf '  🔴 SURVIVED — the suite passed a weakened guard. %s\n' "$why"
    survived=$((survived + 1))
    survivors+=("$name")
  fi
  echo
}

echo "══ mutating the destroy guard ══════════════════════════════════════════════════════"
echo

mutate "M1 · prefix match instead of exact match" \
  's|if \[ "$entry" = "$candidate" \]; then|if case "$candidate" in "$entry"*) true ;; *) false ;; esac; then|' \
  "a child of an allowed path must not be destroyable"

mutate "M2 · the empty allow-list no longer fails closed" \
  's|refuse "destroyable_directories is empty|: "destroyable_directories is empty|' \
  "an empty allow-list must make NOTHING destroyable"

mutate "M3 · the traversal check is dropped" \
  '/A traversal cannot be matched/s/refuse/: /' \
  "terraform/test/../prod must not be matched against an allow-list"

mutate "M4 · a glob entry becomes a silent non-match instead of an error" \
  '/Globs are NOT supported/s/refuse/: /' \
  "a caller who wrote tf/* must be TOLD, not quietly refused"

mutate "M5 · the comparison folds case" \
  's|if \[ "$entry" = "$candidate" \]; then|if [ "$(printf %s "$entry" \| tr A-Z a-z)" = "$(printf %s "$candidate" \| tr A-Z a-z)" ]; then|' \
  "Linux paths are case-sensitive; folding case admits a path that does not exist"

mutate "M6 · an absolute working_directory is accepted" \
  '/is absolute. Paths are relative/s/refuse/: /' \
  "an absolute path escapes the repository the allow-list describes"

mutate "M7 · the guard exits 0 before any check" \
  's|^\( *\)set -euo pipefail|\1set -euo pipefail\n\1exit 0|' \
  "the most direct weakening of all — the guard must not be a no-op"

mutate "M8 · the guard body grows a GitHub expression" \
  's|candidate="$(norm "${CANDIDATE:-}")"|candidate="$(norm "${{ inputs.working_directory }}")"|' \
  "the test must FATAL rather than run bytes the workflow does not run"

mutate "M9 · the GUARD BEGIN marker is removed" \
  '/# >>> GUARD BEGIN/d' \
  "the extractor must fail closed when it cannot see the guard"

# ── M10–M13 attack the WIRING, which every case above is blind to ────────────────────────

mutate "M10 · ALLOW_LIST is mapped to the wrong input" \
  's|ALLOW_LIST: ${{ inputs.destroyable_directories }}|ALLOW_LIST: ${{ inputs.working_directory }}|' \
  "the guard would compare the target against itself and allow everything — and all 35 logic cases still pass"

mutate "M11 · CANDIDATE is no longer passed in at all" \
  '/CANDIDATE: ${{ inputs.working_directory }}/d' \
  "the guard would check an empty string on every run"

mutate "M12 · the allow-list becomes optional" \
  '/^      destroyable_directories:$/,/^      aws_region:$/s/required: true/required: false/' \
  "an allow-list a caller can omit is not a control"

mutate "M13 · the saved plan is discarded and the destroy is re-evaluated" \
  's|terraform apply -input=false destroy.tfplan|terraform destroy -input=false -auto-approve|' \
  "the uploaded artifact must be what actually ran"

# ── M15–M19 attack the two guards added in r2 ───────────────────────────────────────────

mutate "M15 · the default-branch ref check is dropped" \
  '/The destroy allow-list is read from the caller/s/refuse/: /' \
  "workflow_dispatch runs at any ref, so an unreviewed branch could add tf/aws-bootstrap to the allow-list"

mutate "M16 · an unknown default branch is assumed to be main" \
  's|if \[ -z "${DEFAULT_BRANCH:-}" \]; then|DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"; if false; then|' \
  "a repo whose default branch is master or trunk would be guessed at"

mutate "M17 · the workspace count check is dropped" \
  's|if \[ "$count" -ne 1 \] \|\| \[ "$(printf .%s. "$names" \| tr -d . .)" != "default" \]; then|if false; then|' \
  "one allow-list entry would authorise every environment in a workspace-per-env stack"

mutate "M18 · TF_WORKSPACE is ignored" \
  's|if \[ -n "${TF_WORKSPACE:-}" \] && \[ "$TF_WORKSPACE" != "default" \]; then|if false; then|' \
  "TF_WORKSPACE moves the target away from the state the allow-list authorised"

mutate "M19 · a failed workspace list is treated as fine" \
  's|if ! raw="$(terraform workspace list 2>&1)"; then|raw="$(terraform workspace list 2>\&1 \|\| true)"; if false; then|' \
  "not being able to establish the target is not permission to destroy it"

# These two insert a LINE, which sed cannot do portably in a multi-line match,
# so they go through perl like M14.
mutate_prog "M20 · the destroy PLAN step becomes continue-on-error" \
  "a soft plan step hands the apply a plan file written by a FAILED plan, and prevent_destroy then protects nobody" \
  perl -0pi -e 's/( +)- name: Terraform Plan \(destroy\)\n/$1- name: Terraform Plan (destroy)\n$1  continue-on-error: true\n/'

mutate_prog "M21 · the destroy APPLY step becomes continue-on-error" \
  "a destroy that fails must fail the job" \
  perl -0pi -e 's/( +)- name: Terraform Apply \(the saved destroy plan\)\n/$1- name: Terraform Apply (the saved destroy plan)\n$1  continue-on-error: true\n/'

# PROOF's three survivors of my first (grep-based) version of the hard-step
# assertion. Each is a different way to soften a step without writing the
# string `continue-on-error: true`.
mutate_prog "M22 · continue-on-error in EXPRESSION form on the plan step" \
  'a denylist of spellings is not a control; the expression form is the same softening' \
  perl -0pi -e 's/( +)- name: Terraform Plan \(destroy\)\n/$1- name: Terraform Plan (destroy)\n$1  continue-on-error: \$\{\{ true \}\}\n/'

mutate_prog "M23 · if: always() on the APPLY step" \
  "the apply would run even though the plan failed, against a plan file written by that failed plan" \
  perl -0pi -e 's/( +)- name: Terraform Apply \(the saved destroy plan\)\n/$1- name: Terraform Apply (the saved destroy plan)\n$1  if: always()\n/'

mutate_prog "M24 · the plan command swallows its own exit code" \
  "|| true makes the step succeed on a refused plan, so prevent_destroy stops the plan and nothing stops the apply" \
  perl -0pi -e 's/(run: terraform plan -destroy -input=false -no-color -out=destroy\.tfplan)/$1 || true/'

# PROOF r3: both of these are actionlint-valid and PyYAML puts the key ON the
# step, so an extractor that stops at a blank or a comment never sees them.
mutate_prog "M25 · a BLANK line, then continue-on-error on the plan step" \
  'YAML does not end a step at a blank line, and the first extractor did' \
  perl -0pi -e 's/(        working-directory: \$\{\{ inputs\.working_directory \}\}\n)(\n      # The binary plan)/$1\n        continue-on-error: true\n$2/'

mutate_prog "M26 · a step-indented COMMENT, then if: always() on the apply step" \
  'a comment does not end a step either' \
  perl -0pi -e 's/( +)- name: Terraform Apply \(the saved destroy plan\)\n/$1- name: Terraform Apply (the saved destroy plan)\n$1# keep going even if the plan refused\n$1  if: always()\n/'

# 🔴 PROOF r4's survivor: a SECOND apply step. Both content pins still pass,
# because each only says "the step with this name has this body". Only the
# ordered step-list pin can see it.
mutate_prog "M27 · a SECOND apply step is appended" \
  'two pinned blocks do not stop a third step being added' \
  perl -0pi -e 's/(        run: terraform apply -input=false destroy\.tfplan\n        working-directory: \$\{\{ inputs\.working_directory \}\}\n)/$1\n      - name: Terraform Apply again, whatever happened\n        if: always()\n        run: terraform apply -input=false destroy.tfplan\n        working-directory: \$\{\{ inputs.working_directory \}\}\n/'

mutate_prog "M14 · checkout is hoisted above the guard" \
  "a refused run must never reach a checkout or a credential" \
  perl -0pi -e 's/^ {6}- uses: actions\/checkout\@v4\n//m; s/^( {4}steps:\n)/$1      - uses: actions\/checkout\@v4\n/m'

echo "══ result ══════════════════════════════════════════════════════════════════════════"
printf '%s killed, %s survived\n' "$killed" "$survived"

ran=$((killed + survived))
if [ "$ran" -ne "$EXPECTED_MUTATIONS" ]; then
  printf '🔴 %s mutations ran, %s declared — one never executed, so this sweep proves less than it claims.\n' \
    "$ran" "$EXPECTED_MUTATIONS"
  exit 1
fi
if [ "$survived" -ne 0 ]; then
  printf 'SURVIVORS (each one is a gap in tests/destroy-guard.sh):\n'
  printf '  - %s\n' "${survivors[@]}"
  exit 1
fi
