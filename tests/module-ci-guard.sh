#!/usr/bin/env bash
#
# tests/module-ci-guard.sh — tf-module-ci.yml's two test gates, run as their own bytes.
#
# 🔑 BOTH DEFECTS PROOF FOUND WERE "GREEN BY NOT LOOKING", so both arms here are
# about a check that cannot fail:
#   · detection matched only `*.tftest.hcl`, so a JSON-only suite was skipped
#     and the job passed having run nothing;
#   · `terraform test` prints "Success! 0 passed, 0 failed." and exits 0 when the
#     files sit where it does not look, so the gate went green on zero runs.
#
# Same extraction contract as tests/destroy-guard.sh: the lines between the
# markers in the workflow are what runs here, and the extractor FAILS CLOSED.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workflow="$here/../.github/workflows/tf-module-ci.yml"
[ -f "$workflow" ] || { echo "FATAL: $workflow not found"; exit 2; }

extract() {
  awk -v b="# >>> $1 BEGIN" -v e="# <<< $1 END" '
    index($0, b) { inside = 1; next }
    index($0, e) { inside = 0; next }
    inside       { print }
  ' "$workflow"
}

dedent() {
  local raw="$1" indent
  indent="$(printf '%s\n' "$raw" | sed -n '1s/^\([[:space:]]*\).*/\1/p')"
  printf '%s\n' "$raw" | sed "s/^${indent}//"
}

detect_raw="$(extract DETECT)"
runs_raw="$(extract 'RUNS GUARD')"
[ -n "$detect_raw" ] || { echo "FATAL: DETECT markers not found — nothing below tests detection"; exit 2; }
[ -n "$runs_raw" ]   || { echo "FATAL: RUNS GUARD markers not found — nothing below tests the zero-runs gate"; exit 2; }
detect="$(dedent "$detect_raw")"
runs="$(dedent "$runs_raw")"
# shellcheck disable=SC2016  # matching the LITERAL characters ${{ is the point
case "$detect$runs" in
  *'${{'*) echo "FATAL: a guard body interpolates a GitHub expression; keep contexts in env:"; exit 2 ;;
esac
printf 'extracted detection (%s lines) and the runs gate (%s lines)\n\n' \
  "$(printf '%s\n' "$detect" | wc -l | tr -d ' ')" "$(printf '%s\n' "$runs" | wc -l | tr -d ' ')"

pass=0
fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ── arm 1 · detection ───────────────────────────────────────────────────────────────────
# run_detect <relative-file-paths…> → prints the found= line
run_detect() {
  local dir="$tmp/mod.$RANDOM"
  mkdir -p "$dir"
  local f
  for f in "$@"; do
    mkdir -p "$dir/$(dirname "$f")"
    : > "$dir/$f"
  done
  ( cd "$dir" && GITHUB_OUTPUT="$dir/out" bash -c "$detect" >/dev/null 2>&1; cat "$dir/out" 2>/dev/null )
}

detects() {
  local name="$1" want="$2"
  shift 2
  local got
  got="$(run_detect "$@" | grep -E '^found=' | tail -1)"
  if [ "$got" = "found=$want" ]; then
    printf '✅ detect   %s → %s\n' "$name" "$got"
    pass=$((pass + 1))
  else
    printf '❌ FAIL  %s\n        got %s, want found=%s\n        files: %s\n' "$name" "${got:-<none>}" "$want" "$*"
    fail=$((fail + 1))
  fi
}

echo "── detection: both syntaxes, any depth ────────────────────────────────────────────"
detects "a JSON-only suite is NOT skipped"        true  "tests/main.tftest.json"
detects "the HCL case still works"                true  "tests/main.tftest.hcl"
detects "a test file at the module root"          true  "main.tftest.hcl"
detects "both syntaxes together"                  true  "tests/a.tftest.hcl" "tests/b.tftest.json"
detects "a suite deeper than terraform looks"     true  "tests/unit/deep/a.tftest.hcl"
detects "a suite where terraform will ignore it"  true  "examples/basic/a.tftest.hcl"
detects "a module with no tests at all"           false "main.tf" "variables.tf"
detects "a near-miss name is not a test file"     false "tests/main.tftest.hcl.bak" "tests/tftest.hcl"

# ── arm 2 · the zero-runs gate ──────────────────────────────────────────────────────────
# run_runs <terraform-test-output>
run_runs() {
  local out="$tmp/tftest.$RANDOM.out"
  printf '%s\n' "$1" > "$out"
  TFTEST_OUT="$out" bash -c "$runs" 2>&1
}

runs_fails() {
  local name="$1" out="$2" expect="$3" got rc
  got="$(run_runs "$out")"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '❌ FAIL  %s\n        PASSED output that must fail the gate:\n        %s\n' "$name" "$out"
    fail=$((fail + 1))
    return
  fi
  if ! printf '%s' "$got" | grep -qF -- "$expect"; then
    printf '❌ FAIL  %s\n        failed, but not for the stated reason\n        wanted: %s\n        got:    %s\n' "$name" "$expect" "$got"
    fail=$((fail + 1))
    return
  fi
  printf '✅ refused  %s\n' "$name"
  pass=$((pass + 1))
}

runs_passes() {
  local name="$1" out="$2" got rc
  got="$(run_runs "$out")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '❌ FAIL  %s\n        FAILED output that must pass (exit %s): %s\n' "$name" "$rc" "$got"
    fail=$((fail + 1))
    return
  fi
  printf '✅ accepted %s\n' "$name"
  pass=$((pass + 1))
}

echo
echo "── the zero-runs gate: a suite that executes nothing is not a passing suite ───────"
runs_fails "terraform found the files but ran nothing" \
  'tests/main.tftest.hcl... in progress
tests/main.tftest.hcl... tearing down

Success! 0 passed, 0 failed.' "executed ZERO runs"
runs_fails "no summary line at all" \
  'Terraform has no test files' "could not find a run summary"
runs_fails "empty output" \
  '' "could not find a run summary"
runs_fails "a summary-shaped line that is not one" \
  'Error: some passed, some failed' "could not find a run summary"

# 🔑 A MISSING OUTPUT FILE AND AN UNREADABLE SUMMARY ARE DIFFERENT DIAGNOSES, and
# that is the only thing the file-existence check buys — without it, grep on a
# missing file yields an empty summary and the operator is told the output had no
# summary when in fact there was no output. The mutation sweep reported that
# check as surviving until this case existed, which was correct of it: an
# unkillable guard is dead weight unless something asserts what it adds.
runs_fails_missing_file() {
  local got rc
  got="$(TFTEST_OUT="$tmp/does-not-exist.out" bash -c "$runs" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '❌ FAIL  a missing output file passed the gate\n'
    fail=$((fail + 1))
  elif ! printf '%s' "$got" | grep -qF "no terraform test output was captured"; then
    printf '❌ FAIL  a missing output file is diagnosed as a missing SUMMARY\n        got: %s\n' "$got"
    fail=$((fail + 1))
  else
    printf '✅ refused  a missing output file, named as such\n'
    pass=$((pass + 1))
  fi
}
runs_fails_missing_file

echo
echo "── and the outcomes it must not touch ────────────────────────────────────────────"
runs_passes "a real pass"    'Success! 5 passed, 0 failed.'
runs_passes "a real failure" 'Failure! 0 passed, 3 failed.'
runs_passes "mixed"          'Failure! 4 passed, 1 failed.'
# 🔑 The LAST summary is the operative one: terraform prints a per-file summary
# before the overall one, so reading the first would see 0 on a multi-file suite
# whose first file is empty.
runs_passes "the last summary wins over an earlier zero" \
  'tests/a.tftest.hcl... pass
Success! 0 passed, 0 failed.
tests/b.tftest.hcl... pass
Success! 3 passed, 0 failed.'

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
