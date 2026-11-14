#!/usr/bin/env bash
#
# tests/comment-step-guard.sh — a PR results comment is a REPORT, never a gate.
#
# 2026-11-12, tf-aws-mcp-host#1: every check in tf-module-ci passed, then "Post Results to
# PR" got an HTTP 500 from the GitHub API (actions/github-script, retries: 0), and the job
# failed. A transient API error on a comment must neither fail validation nor go unretried.
#
# For every step in every reusable workflow here whose script calls createComment (DERIVED,
# so a new comment step is covered without editing this file), require:
#   · continue-on-error: true   (the "Fail if …" steps are the gate, not the comment);
#   · with: retries: N, N >= 1  (github-script retries 5xx; 4xx stay exempt).
# Then the same checks run against mutated copies, each of which MUST be caught.
#
# Dependency-free, like the other gates here: bash, awk, sed.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wfdir="$here/../.github/workflows"

# Print "<step name>|<continue-on-error>|<retries>" for each step whose body calls
# createComment. A step runs from its `- name:` (or `- uses:`) line to the next one at the
# same indent or shallower, or to a job- or top-level YAML key (indent 0-4). NOT to any
# column-0 line: a github-script body's template strings put text at column 0, and an
# extractor that stopped there found no step at all (measured, the first version).
# YAML comments are skipped, so a comment that mentions createComment counts for nothing.
comment_steps() {
  awk '
    function flush() {
      if (in_step && calls) print name "|" coe "|" retries
      in_step = 0; calls = 0; coe = ""; retries = ""; name = ""
    }
    /^[[:space:]]*- (name|uses):/ {
      ind = match($0, /[^ ]/)
      if (!in_step || ind <= step_ind) { flush(); in_step = 1; step_ind = ind }
    }
    in_step && /^[[:space:]]*- name:/ && match($0, /[^ ]/) == step_ind { sub(/^[[:space:]]*- name:[[:space:]]*/, ""); name = $0 }
    in_step && /^[[:space:]]*continue-on-error:/ { v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); coe = v }
    in_step && /^[[:space:]]*retries:/           { v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); retries = v }
    in_step && !/^[[:space:]]*#/ && /createComment/ { calls = 1 }
    /^( {0,4})[A-Za-z0-9_-]+:([[:space:]]|$)/ { flush() }
    END { flush() }
  ' "$1"
}

# 0 when every comment step in $1 is non-gating and retried; prints the offenders.
check_file() {
  local f="$1" bad=0 found=0 name coe retries
  while IFS='|' read -r name coe retries; do
    found=$((found + 1))
    if [ "$coe" != "true" ]; then echo "    $(basename "$f"): '$name' has continue-on-error '${coe:-unset}', not true"; bad=1; fi
    if ! [[ "$retries" =~ ^[1-9][0-9]*$ ]]; then echo "    $(basename "$f"): '$name' has retries '${retries:-unset}', not >= 1"; bad=1; fi
  done < <(comment_steps "$f")
  echo "$found" > "$tmp/found"
  return $bad
}

tmp="$(mktemp -d)"; trap 'rm -f "$tmp"/*; rmdir "$tmp"' EXIT
fail=0

echo "== the real workflows"
total=0
for f in "$wfdir"/*.yml; do
  if check_file "$f"; then :; else fail=1; fi
  total=$((total + $(cat "$tmp/found")))
done
# Not vacuous: tf-module-ci and tf-plan each post one.
if [ "$total" -lt 2 ]; then echo "  🔴 found $total comment step(s); expected at least 2 (tf-module-ci, tf-plan)"; fail=1
else echo "  ✅ $total comment step(s), each continue-on-error: true and retried"; fi

echo "== mutants (each must be caught)"
mutant() {
  local label="$1" file="$2" sedexpr="$3" m="$tmp/m.yml"
  sed "$sedexpr" "$wfdir/$file" > "$m"
  if cmp -s "$m" "$wfdir/$file"; then echo "  🔴 $label: the mutation changed nothing (anchor miss)"; fail=1; return; fi
  if check_file "$m" >/dev/null; then echo "  🔴 $label: SURVIVED"; fail=1; else echo "  ✅ $label: caught"; fi
}
mutant "module-ci: continue-on-error removed"  tf-module-ci.yml '/name: Post Results to PR/,/script:/{/continue-on-error: true/d;}'
mutant "module-ci: continue-on-error false"    tf-module-ci.yml '/name: Post Results to PR/,/script:/s/continue-on-error: true/continue-on-error: false/'
mutant "module-ci: retries removed"            tf-module-ci.yml '/name: Post Results to PR/,/script:/{/retries:/d;}'
mutant "module-ci: retries 0"                  tf-module-ci.yml '/name: Post Results to PR/,/script:/s/retries: 3/retries: 0/'
mutant "plan: continue-on-error removed"       tf-plan.yml      '/name: Post Plan to PR/,/script:/{/continue-on-error: true/d;}'
mutant "plan: retries removed"                 tf-plan.yml      '/name: Post Plan to PR/,/script:/{/retries:/d;}'
# A NEW comment step with neither setting: covered because the set is derived.
m="$tmp/new.yml"
cat "$wfdir/tf-plan.yml" > "$m"
cat >> "$m" <<'EOF'
  extra:
    runs-on: ubuntu-24.04-arm
    steps:
      - name: Another comment
        uses: actions/github-script@v7
        with:
          script: |
            github.rest.issues.createComment({ owner: 'o', repo: 'r', issue_number: 1, body: 'x' })
EOF
if check_file "$m" >/dev/null; then echo "  🔴 a new unguarded comment step: SURVIVED"; fail=1; else echo "  ✅ a new unguarded comment step: caught"; fi

if [ $fail -ne 0 ]; then echo "🔴 comment-step-guard: FAILED"; exit 1; fi
echo "comment-step-guard: passed"
