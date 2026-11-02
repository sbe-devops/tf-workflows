#!/usr/bin/env bash
#
# tests/mutate-validate-directory.sh — does validate-directory.sh catch a weakened
# validate_directory?
#
# Same contract as mutate-module-ci.sh: one pristine copy per mutation, the diff
# printed, and a mutation that changes nothing is reported as a NO-OP rather than
# counted as a kill.
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
  cp "$here/validate-directory.sh" "$work/tests/validate-directory.sh"

  perl -0pi -e "$expr" "$work/$rel"
  local diff_out
  diff_out="$(diff "$root/$rel" "$work/$rel")"
  if [ -z "$diff_out" ]; then
    printf '⚠️  NO-OP  %s — the anchor moved and this mutation tested nothing\n' "$name"
    survived=$((survived + 1))
    survivors+=("$name (no-op)")
    return
  fi

  printf -- '— %s\n' "$name"
  printf '%s\n' "$diff_out" | grep -E '^[<>]' | head -4 | sed 's/^/        /'

  local out rc
  out="$(cd "$work" && bash tests/validate-directory.sh 2>&1)"
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

echo "══ mutating tf-module-ci's validate_directory ══════════════════════════════════════"
echo

mutate "V1 · the default moves off the module root" \
  's/(      validate_directory:\n(?:        .*\n)*?        default: )"\."/$1"examples\/basic"/' \
  "every consumer that never set the input would validate an example it may not have"

mutate "V2 · init stays at the root" \
  's/(- name: Terraform Init\n.*\n        working-directory: \$\{\{ inputs\.working_directory \}\})\/\$\{\{ inputs\.validate_directory \}\}/$1/' \
  "validate would run in a directory nothing was initialised in"

mutate "V3 · validate stays at the root" \
  's/(- name: Terraform Validate\n.*\n.*\n        working-directory: \$\{\{ inputs\.working_directory \}\})\/\$\{\{ inputs\.validate_directory \}\}/$1/' \
  "the input would be accepted and do nothing: the aliased module fails exactly as before"

mutate "V4 · tflint follows validate into the example" \
  's/(- name: TFLint\n.*\n.*\n        working-directory: \$\{\{ inputs\.working_directory \}\})/$1\/\$\{\{ inputs.validate_directory \}\}/' \
  "tflint would lint the example and never read the module"

mutate "V5 · the guard is made soft" \
  's/(      - name: Assert validate loads the module\n)/$1        continue-on-error: true\n/' \
  "a validate of the wrong directory would be reported and then passed"

mutate "V6 · the guard moves after validate" \
  's/(      - name: Assert validate loads the module\n(?:        .*\n|\n)*?)(      - name: Terraform Validate\n(?:        .*\n)*)/$2\n$1/' \
  "the guard would run after the step it exists to qualify"

mutate "V7 · the root short-circuit always passes" \
  's/if \[ "\$here" = "\$root" \]; then/if true; then/' \
  "every directory would be called the module root, the manifest never read"

mutate "V8 · a missing manifest is tolerated" \
  's/\[ -f "\$manifest" \] \|\| fail/[ -f "\$manifest" ] || exit 0; false \&\& fail/' \
  "a directory that calls no module would validate green having read none of it"

mutate "V9 · any manifest entry counts as the module" \
  's/            if \[ "\$\(cd "\$dir" && pwd -P\)" = "\$root" \]; then/            if [ -d "\$dir" ]; then/' \
  'the example'"'"'s own "." entry would match, so a different module passes'

mutate "V10 · paths compared without resolving symlinks" \
  's/root="\$\(cd "\$MODULE_ROOT" && pwd -P\)"/root="\$(cd "\$MODULE_ROOT" \&\& pwd)"/' \
  "a module root reached through a symlink would be refused as not the root"

mutate "V11 · a manifest Dir that is gone still counts" \
  's/            \[ -d "\$dir" \] \|\| continue\n            if \[ "\$\(cd "\$dir" && pwd -P\)" = "\$root" \]; then/            if [ "\$(cd "\$dir" 2>\/dev\/null \&\& pwd -P || echo "\$root")" = "\$root" ]; then/' \
  "a stale manifest naming a deleted path would pass as the module"

echo "══ result ══════════════════════════════════════════════════════════════════════════"
printf '%s killed, %s survived\n' "$killed" "$survived"
if [ "$survived" -ne 0 ]; then
  printf '  - %s\n' "${survivors[@]}"
  exit 1
fi
