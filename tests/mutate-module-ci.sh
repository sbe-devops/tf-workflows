#!/usr/bin/env bash
#
# tests/mutate-module-ci.sh — does module-ci-guard.sh catch a weakened gate?
#
# Same contract as mutate-destroy-guard.sh: one pristine copy per mutation, the
# diff printed, and a mutation that changes nothing is reported as a NO-OP
# rather than counted as a kill.
# shellcheck disable=SC2016  # the single-quoted strings are perl programs

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
rel=".github/workflows/tf-module-ci.yml"

killed=0
survived=0
survivors=()
tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT

mutate() {
  local name="$1" expr="$2" why="$3"
  local work
  work="$(mktemp -d "$tmproot/m.XXXXXX")"
  mkdir -p "$work/.github/workflows" "$work/tests"
  cp "$root/$rel" "$work/$rel"
  cp "$here/module-ci-guard.sh" "$work/tests/module-ci-guard.sh"

  perl -0pi -e "$expr" "$work/$rel"
  local diff_out
  diff_out="$(diff "$root/$rel" "$work/$rel")"
  if [ -z "$diff_out" ]; then
    printf '⚠️  NO-OP  %s — the anchor moved and this mutation tested nothing\n' "$name"
    survived=$((survived + 1))
    survivors+=("$name (no-op)")
    return
  fi

  printf '— %s\n' "$name"
  printf '%s\n' "$diff_out" | grep -E '^[<>]' | head -4 | sed 's/^/        /'

  local out rc
  out="$(cd "$work" && bash tests/module-ci-guard.sh 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '  ✅ KILLED — %s\n' "$why"
    printf '%s\n' "$out" | grep -E '^(❌ FAIL|FATAL)' | head -3 | sed 's/^/        /'
    killed=$((killed + 1))
  else
    printf '  🔴 SURVIVED — %s\n' "$why"
    survived=$((survived + 1))
    survivors+=("$name")
  fi
  echo
}

echo "══ mutating tf-module-ci's test gates ══════════════════════════════════════════════"
echo

mutate "D1 · detection goes back to HCL only" \
  "s/\\\\\\( -name '\\*\\.tftest\\.hcl' -o -name '\\*\\.tftest\\.json' \\\\\\)/-name '*.tftest.hcl'/" \
  "a JSON-only suite would be skipped and the job would pass having run nothing"

mutate "D2 · detection goes back to maxdepth 2" \
  "s/find \\. \\\\\\(/find . -maxdepth 2 \\\\(/" \
  "a suite deeper than terraform looks must still be DETECTED, so the zero-runs gate can report it"

mutate "R1 · the zero-runs check is dropped" \
  's/if \[ "\$\(\(passed \+ failed\)\)" -eq 0 \]; then/if false; then/' \
  '"Success! 0 passed, 0 failed." is the whole defect'

mutate "R2 · a missing summary is treated as fine" \
  's/if \[ -z "\$summary" \]; then/if false; then/' \
  "not being able to tell how many tests ran is not evidence that any did"

mutate "R3 · the FIRST summary is read instead of the last" \
  "s/grep -Eo '\\[0-9\\]\\+ passed, \\[0-9\\]\\+ failed' \"\\\$TFTEST_OUT\" \\| tail -1/grep -Eo '[0-9]+ passed, [0-9]+ failed' \"\\\$TFTEST_OUT\" | head -1/" \
  "terraform prints a per-file summary first, so reading the first sees 0 on a multi-file suite"

mutate "R4 · the captured output file is no longer required" \
  's/\[ -f "\$\{TFTEST_OUT:-\}" \] \|\| fail/[ 1 ] || fail/' \
  "a run with no captured output must not pass the gate"

echo "══ result ══════════════════════════════════════════════════════════════════════════"
printf '%s killed, %s survived\n' "$killed" "$survived"
if [ "$survived" -ne 0 ]; then
  printf '  - %s\n' "${survivors[@]}"
  exit 1
fi
