#!/usr/bin/env bash
#
# tests/validate-directory.sh — tf-module-ci.yml's `validate_directory` input.
#
# 🔑 TWO PROPERTIES, and both are about not changing what the other consumers get:
#   · WIRING (static): only validate, its own init and the loads-module guard
#     run in <working_directory>/<validate_directory>. The root is ALWAYS
#     initialised (`terraform test` runs there; PROOF on #13), and fmt, tflint,
#     checkov and the test steps stay there. The default is "." — so for the 18
#     consumers that never set it, the same commands run in the same directory.
#   · THE GUARD (its own bytes, against directory fixtures): a validate_directory
#     that does not load the module must FAIL, or validate goes green having read
#     none of the module's code.
#
# The real-terraform half (an aliased module that fails at its root and passes
# via its example) is the `module-ci-*` jobs in ci.yml, on tests/fixtures/module-ci.
#
# Same extraction contract as tests/module-ci-guard.sh: the lines between the
# markers in the workflow are what runs here, and the extractor FAILS CLOSED.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workflow="$here/../.github/workflows/tf-module-ci.yml"
[ -f "$workflow" ] || { echo "FATAL: $workflow not found"; exit 2; }

pass=0
fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ok()  { printf '✅ %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '❌ FAIL  %s\n        %s\n' "$1" "$2"; fail=$((fail + 1)); }

# step_dir <step name> → that step's working-directory value, or <none>
step_dir() {
  awk -v want="      - name: $1" '
    $0 == want                    { inside = 1; next }
    inside && /^      - /         { exit }
    inside && /^        working-directory: / {
      sub(/^        working-directory: /, ""); print; found = 1; exit
    }
    END { if (!found) print "<none>" }
  ' "$workflow"
}

# step_has <step name> <ERE> → 0 when a line of that step matches
step_has() {
  awk -v want="      - name: $1" '
    $0 == want            { inside = 1; next }
    inside && /^      - / { exit }
    inside                { print }
  ' "$workflow" | grep -qE -- "$2"
}

# step_line <step name> → its line number, or empty
step_line() {
  grep -nxF -- "      - name: $1" "$workflow" | head -1 | cut -d: -f1
}

# shellcheck disable=SC2016  # the literal ${{ … }} text IS what is asserted
root_dir='${{ inputs.working_directory }}'
# shellcheck disable=SC2016
validate_dir='${{ inputs.working_directory }}/${{ inputs.validate_directory }}'

echo "── wiring: what moves, what stays ─────────────────────────────────────────────────"

if awk '/^      validate_directory:$/ { inside = 1; next }
        inside && /^      [a-z_]+:$/  { exit }
        inside && /^        default: "\."$/ { found = 1 }
        END { exit !found }' "$workflow"; then
  ok "validate_directory is declared, defaulting to \".\""
else
  bad "validate_directory is declared, defaulting to \".\"" \
    "any other default moves validation for every consumer that never set the input"
fi

for step in "Terraform Init (validate_directory)" "Assert validate loads the module" "Terraform Validate"; do
  got="$(step_dir "$step")"
  if [ "$got" = "$validate_dir" ]; then
    ok "'$step' runs in <working_directory>/<validate_directory>"
  else
    bad "'$step' runs in <working_directory>/<validate_directory>" "got: $got"
  fi
done

# The module's own code is what these read. Moved to an example, fmt and tflint
# would check the example, checkov would scan the example, and the tests would
# never be found.
# 🔴 "Terraform Init" is in this list because `terraform test` runs at the root
# and needs its providers: moved to the validate directory, the test step failed
# "unknown provider" (PROOF on #13).
for step in "Terraform Format Check" "TFLint Init" "TFLint" "Checkov Scan" \
            "Terraform Init" "Detect Terraform tests" "Terraform Test"; do
  got="$(step_dir "$step")"
  if [ "$got" = "$root_dir" ]; then
    ok "'$step' stays at <working_directory>"
  else
    bad "'$step' stays at <working_directory>" "got: $got"
  fi
done

# The validate directory's own init is skipped at the default, where the root
# init already covers it.
if step_has "Terraform Init (validate_directory)" "^        if: inputs\.validate_directory != '\.'\$"; then
  ok "the validate directory's init runs only when it is not the root"
else
  bad "the validate directory's init runs only when it is not the root" \
    "want: if: inputs.validate_directory != '.'"
fi

init="$(step_line "Terraform Init")"
vinit="$(step_line "Terraform Init (validate_directory)")"
guard="$(step_line "Assert validate loads the module")"
validate="$(step_line "Terraform Validate")"
tftest="$(step_line "Terraform Test")"
if [ -n "$init" ] && [ -n "$vinit" ] && [ -n "$guard" ] && [ -n "$validate" ] && [ -n "$tftest" ] \
   && [ "$init" -lt "$tftest" ] && [ "$vinit" -lt "$guard" ] && [ "$guard" -lt "$validate" ]; then
  ok "root init precedes the tests; validate-dir init precedes the guard (it reads init's manifest), which precedes validate"
else
  bad "step order" "init=${init:-?} vinit=${vinit:-?} guard=${guard:-?} validate=${validate:-?} test=${tftest:-?}"
fi

if step_has "Assert validate loads the module" '^        continue-on-error:'; then
  bad "the guard is hard" "continue-on-error on the guard makes a validate of the wrong directory decorative again"
else
  ok "the guard is hard (no continue-on-error)"
fi

# shellcheck disable=SC2016
if step_has "Assert validate loads the module" '^          MODULE_ROOT: \$\{\{ github\.workspace \}\}/\$\{\{ inputs\.working_directory \}\}$'; then
  ok "the guard compares against the module root, <workspace>/<working_directory>"
else
  bad "the guard compares against the module root" "MODULE_ROOT must be \${{ github.workspace }}/\${{ inputs.working_directory }}"
fi

echo
echo "── the guard's own bytes ──────────────────────────────────────────────────────────"

raw="$(awk -v b="# >>> LOADS MODULE BEGIN" -v e="# <<< LOADS MODULE END" '
  index($0, b) { inside = 1; next }
  index($0, e) { inside = 0; next }
  inside       { print }
' "$workflow")"
[ -n "$raw" ] || { echo "FATAL: LOADS MODULE markers not found — nothing below tests the guard"; exit 2; }
indent="$(printf '%s\n' "$raw" | sed -n '1s/^\([[:space:]]*\).*/\1/p')"
guard_body="$(printf '%s\n' "$raw" | sed "s/^${indent}//")"
# shellcheck disable=SC2016  # matching the LITERAL characters ${{ is the point
case "$guard_body" in
  *'${{'*) echo "FATAL: the guard body interpolates a GitHub expression; keep contexts in env:"; exit 2 ;;
esac

# A module root with an example beside it, as tf-aws-static-site has.
mod="$tmp/ws/module"
mkdir -p "$mod/examples/basic" "$mod/examples/other" "$mod/examples/empty" "$tmp/ws/elsewhere"
ln -s "$mod" "$tmp/ws/module-link"

# manifest <dir> <Dir…> → writes .terraform/modules/modules.json the way init does
manifest() {
  local dir="$1" json='{"Modules":[{"Key":"","Source":"","Dir":"."}' d
  shift
  for d in "$@"; do
    json="$json,{\"Key\":\"m\",\"Source\":\"$d\",\"Dir\":\"$d\"}"
  done
  mkdir -p "$dir/.terraform/modules"
  printf '%s]}\n' "$json" > "$dir/.terraform/modules/modules.json"
}
manifest "$mod/examples/basic" "../.."
manifest "$mod/examples/other" "../../../elsewhere"
mkdir -p "$mod/examples/remote/.terraform/modules/m"
manifest "$mod/examples/remote" ".terraform/modules/m"
manifest "$mod/examples/only-self"

# run_guard <module root as given> <validate dir, relative to the module root>
run_guard() {
  ( cd "$mod/$2" && MODULE_ROOT="$1" VALIDATE_DIRECTORY="$2" bash -c "$guard_body" 2>&1 )
}

accepts() {
  local name="$1" got rc
  got="$(run_guard "$2" "$3")"
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$got" | grep -qF -- "$4"; then
    ok "accepted  $name"
  else
    bad "accepted  $name" "exit $rc, want 0 with \"$4\"; got: $got"
  fi
}

refuses() {
  local name="$1" got rc
  got="$(run_guard "$2" "$3")"
  rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$got" | grep -qF -- "$4"; then
    ok "refused   $name"
  else
    bad "refused   $name" "exit $rc, want non-zero with \"$4\"; got: $got"
  fi
}

# The default: <workspace>/. with validate_directory ".". No manifest exists at a
# root that calls no module (measured, terraform 1.15), so this must not need one.
accepts "the default: validate at the module root, no manifest needed" "$mod/." "." "validating the module root itself"
accepts "the module root reached through a symlink" "$tmp/ws/module-link" "." "validating the module root itself"
accepts "an example that calls the module (../..)" "$mod/." "examples/basic" "loads the module at"
refuses "a directory that calls no module at all" "$mod/." "examples/empty" "calls no module"
refuses "an example that calls a different module" "$mod/." "examples/other" "does not call the module"
refuses "an example that calls only a remote module" "$mod/." "examples/remote" "does not call the module"
refuses "a manifest that lists only the example itself" "$mod/." "examples/only-self" "does not call the module"

# A Dir naming a path that is gone (a stale manifest) must not count as a match.
manifest "$mod/examples/other" "../../gone"
refuses "a manifest Dir that no longer exists" "$mod/." "examples/other" "does not call the module"

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
