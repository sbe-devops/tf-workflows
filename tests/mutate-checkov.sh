#!/usr/bin/env bash
#
# tests/mutate-checkov.sh — every assertion in tests/checkov-sees-modules.sh must be
# able to fail. Each mutation breaks ONE property on a pristine copy of the workflows;
# the test must then fail, with that property's message (WHY) in its output.

set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$here/.."
WORK="$(mktemp -d "${TMPDIR:-/tmp}/checkov-mutate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
EXPECTED=8
ran=0 killed=0 bad=0

# mutate <id> <why> <description> <file> <old> <new>
mutate() {
  local id="$1" why="$2" desc="$3" file="$4" old="$5" new="$6" copy="$WORK/$1"
  ran=$((ran + 1))
  mkdir -p "$copy/.github/workflows" && cp "$ROOT"/.github/workflows/*.yml "$copy/.github/workflows/"
  if ! python3 - "$copy/.github/workflows/$file" "$old" "$new" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2].encode().decode("unicode_escape"), sys.argv[3].encode().decode("unicode_escape")
t = open(p).read()
if t.count(old) != 1:
    sys.exit(f"anchor found {t.count(old)} times")
open(p, "w").write(t.replace(old, new))
PY
  then printf '%-3s %-58s HARNESS DEFECT (anchor)\n' "$id" "$desc"; bad=$((bad + 1)); return; fi
  if "$here/checkov-sees-modules.sh" "$copy" > "$copy.log" 2>&1; then
    printf '%-3s %-58s SURVIVED\n' "$id" "$desc"
  elif ! grep -qF -- "$why" "$copy.log"; then
    printf '%-3s %-58s KILLED FOR THE WRONG REASON\n' "$id" "$desc"; bad=$((bad + 1))
  else
    printf '%-3s %-58s killed\n' "$id" "$desc"; killed=$((killed + 1))
  fi
}

echo "== control"
"$here/checkov-sees-modules.sh" "$ROOT" > "$WORK/control.log" 2>&1 || { echo "CONTROL FAILED"; cat "$WORK/control.log"; exit 1; }
echo "control passed"

PIN='bridgecrewio/checkov-action@6f26dc90000b74feb589a906cdfae540f5119895 # v12.3134.0 (checkov 3.3.29)'
mutate C1 "not the 2022 pin" "tf-plan back on v12.1347.0" tf-plan.yml "$PIN" 'bridgecrewio/checkov-action@v12.1347.0'
mutate C2 "pinned to a full commit SHA" "tf-module-ci on a moving tag" tf-module-ci.yml "$PIN" 'bridgecrewio/checkov-action@v12'
mutate C3 "soft_fail stays true" "tf-plan's checkov gates (soft_fail false)" tf-plan.yml \
  '          soft_fail: true\n          output_format: cli\n          download' '          soft_fail: false\n          output_format: cli\n          download'
mutate C4 "soft_fail stays true" "tf-module-ci's checkov gates (soft_fail removed)" tf-module-ci.yml \
  '          soft_fail: true\n' ''
mutate C5 "checkov downloads external modules" "no module download (root .tf only)" tf-plan.yml \
  '          download_external_modules: true\n' ''
# shellcheck disable=SC2016  # ${{ }} is a GitHub expression, deliberately unexpanded
mutate C6 "gets the module token as github_pat" "the token isn't handed to checkov" tf-plan.yml \
  '          github_pat: ${{ steps.module-token.outputs.token }}\n' ''
# C7: the real block moved back above the token step, verbatim (FB-08's order).
c7() {
  local id=C7 why="comes BEFORE checkov" desc="checkov moved back above the token (FB-08's order)" copy="$WORK/C7"
  ran=$((ran + 1))
  mkdir -p "$copy/.github/workflows" && cp "$ROOT"/.github/workflows/*.yml "$copy/.github/workflows/"
  if ! python3 - "$copy/.github/workflows/tf-plan.yml" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read()
a = t.index("      - name: Generate token for private modules\n")
c = t.index("      # Checkov runs AFTER the module token")
e = t.index("      - name: Terraform Init\n")
open(p, "w").write(t[:a] + t[c:e] + t[a:c] + t[e:])
PY
  then printf '%-3s %-58s HARNESS DEFECT (anchor)\n' "$id" "$desc"; bad=$((bad + 1)); return; fi
  if "$here/checkov-sees-modules.sh" "$copy" > "$copy.log" 2>&1; then
    printf '%-3s %-58s SURVIVED\n' "$id" "$desc"
  elif ! grep -qF -- "$why" "$copy.log"; then
    printf '%-3s %-58s KILLED FOR THE WRONG REASON\n' "$id" "$desc"; bad=$((bad + 1))
  else
    printf '%-3s %-58s killed\n' "$id" "$desc"; killed=$((killed + 1))
  fi
}
c7
mutate C8 "one checkov-action pin across both files" "the two files on different SHAs" tf-module-ci.yml \
  "$PIN" 'bridgecrewio/checkov-action@29be5868bfa968f099ae80169f61f42887494b8f # v12.3133.0'

echo "ran $ran (expected $EXPECTED), killed $killed, harness defects $bad"
[ "$ran" -eq "$EXPECTED" ] && [ "$bad" -eq 0 ] && [ "$killed" -eq "$ran" ] || exit 1
echo "all $ran mutations killed"
