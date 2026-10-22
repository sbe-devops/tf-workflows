#!/usr/bin/env bash
#
# tests/mutate-checkov.sh — every assertion in tests/checkov-sees-modules.sh (C*) and
# tests/checkov-fetch.sh (F*) must be able to fail. Each mutation breaks ONE property on
# a pristine copy of the workflows; the named test must then fail, with that property's
# message (WHY) in its output.

# shellcheck disable=SC2016  # the anchors are workflow text: $vars and ${{ }} stay literal
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$here/.."
WORK="$(mktemp -d "${TMPDIR:-/tmp}/checkov-mutate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
EXPECTED=24
ran=0 killed=0 bad=0

# mutate <id> <test> <why> <description> <file> <old> <new>
mutate() {
  local id="$1" test="$2" why="$3" desc="$4" file="$5" old="$6" new="$7" copy="$WORK/$1"
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
  then printf '%-4s %-62s HARNESS DEFECT (anchor)\n' "$id" "$desc"; bad=$((bad + 1)); return; fi
  if "$here/$test" "$copy" > "$copy.log" 2>&1; then
    printf '%-4s %-62s SURVIVED\n' "$id" "$desc"
  elif ! grep -qF -- "$why" "$copy.log"; then
    printf '%-4s %-62s KILLED FOR THE WRONG REASON\n' "$id" "$desc"; bad=$((bad + 1))
  else
    printf '%-4s %-62s killed\n' "$id" "$desc"; killed=$((killed + 1))
  fi
}

echo "== control"
for t in checkov-sees-modules.sh checkov-fetch.sh; do
  "$here/$t" "$ROOT" > "$WORK/control-$t.log" 2>&1 || { echo "CONTROL FAILED: $t"; cat "$WORK/control-$t.log"; exit 1; }
done
echo "control passed"

S=checkov-sees-modules.sh F=checkov-fetch.sh
DIG='ghcr.io/bridgecrewio/checkov@sha256:3cc125b5337717b7303dbddd4e79374c120687b5ff6a24f9abdad56b562469f3'

echo "-- holds nothing"
mutate C1 $S "no step uses bridgecrewio/checkov-action" "the third-party action is back (a step before init)" tf-plan.yml \
  '      - name: Terraform Init\n' '      - uses: bridgecrewio/checkov-action@6f26dc90000b74feb589a906cdfae540f5119895\n\n      - name: Terraform Init\n'
mutate C2 $S "pinned by DIGEST" "the image by its (mutable) tag" tf-plan.yml "$DIG" 'ghcr.io/bridgecrewio/checkov:3.3.29'
mutate C3 $S "exactly the pinned one" "checkov gets the network (--network none dropped)" tf-plan.yml 'docker run --rm --network none -v' 'docker run --rm -v'
mutate C4 $S "exactly the pinned one" "the working dir mounted writable (:ro dropped)" tf-plan.yml '/tf:ro" -w /tf' '/tf" -w /tf'
mutate C5 $S "exactly the pinned one" "results uploaded to Prisma (--bc-api-key)" tf-plan.yml ' --soft-fail -o cli\n\n      - name: Terraform Init' ' --soft-fail -o cli --bc-api-key x\n\n      - name: Terraform Init'
mutate C6 $S "keys are exactly" "PROOF's exposure: the token handed to checkov (env GITHUB_PAT)" tf-plan.yml \
  '        id: checkov\n' '        id: checkov\n        env:\n          GITHUB_PAT: ${{ steps.module-token.outputs.token }}\n'
mutate C7 $S "keys are exactly" "PROOF's api-key mutant, as a with: key" tf-module-ci.yml \
  '        id: checkov\n' '        id: checkov\n        with:\n          api-key: x\n'
mutate C8 $S "used in exactly ONE step" "the token in the fetch step's env too" tf-plan.yml \
  '        id: checkov-modules\n' '        id: checkov-modules\n        env:\n          T: ${{ steps.module-token.outputs.token }}\n'
mutate C9 $S "one checkov image digest across both files" "the two files on different digests" tf-module-ci.yml \
  "$DIG" 'ghcr.io/bridgecrewio/checkov@sha256:720c295c099ed947e5f211ad5325d2165f1e8f58318b29c53feef9103c20c68c'
echo "-- sees, gates nothing"
mutate C10 $S "the token, then OUR fetch step, then checkov" "checkov before the fetch (blind again)" tf-plan.yml \
  '        id: checkov-modules\n' '        id: checkov-modules-renamed\n'
mutate C11 $S "report-only even if it crashes" "a checkov crash turns the consumer red" tf-plan.yml \
  '        id: checkov\n        working-directory: ${{ inputs.working_directory }}\n        continue-on-error: true\n' '        id: checkov\n        working-directory: ${{ inputs.working_directory }}\n        continue-on-error: false\n'
mutate C12 $S "exactly the pinned one" "module-ci's checkov gates (--soft-fail dropped)" tf-module-ci.yml ' --soft-fail -o cli' ' -o cli'
echo "-- the fetch's behaviour"
mutate F1 $F "4. a .git survived" "clones keep .git (remote URL in the tree)" tf-plan.yml 'rm -rf "$tmp/.git"; mv' 'mv'
mutate F2 $F "3. followed a module's examples/" "examples/ followed" tf-plan.yml " -not -path '*/examples/*'" ''
mutate F3 $F "2. the nested module b was not fetched" "no recursion (one round)" tf-plan.yml 'for _ in 1 2 3 4 5 6; do' 'for _ in 1; do'
mutate F4 $F "the step exited" "a missing module fails the step" tf-plan.yml '          exit 0\n\n      # The image by DIGEST' '          [ "$nm" -eq 0 ]\n\n      # The image by DIGEST'
mutate F5 $F "5. a failed fetch left its destination" "a failed fetch is moved into place anyway" tf-plan.yml 'rm -rf "$tmp"; missed=' 'mv "$tmp" "$d"; missed='
mutate F6 $F "6. run 2 re-fetched" "a re-run fetches over present modules" tf-plan.yml '          [ -e "$d" ] && continue\n' ''
echo "-- traversal (INFRA on #11)"
mutate F7 $F "7. " "the component allow-list removed" tf-plan.yml 'if ! [[ $org =~ $seg && $repo =~ $seg && $ref =~ $seg ]]; then' 'if false; then'
mutate F8 $F "7. " "the allow-list admits \".\" and \"..\"" tf-plan.yml "seg='^[A-Za-z0-9][A-Za-z0-9_.-]*\$'" "seg='^[A-Za-z0-9_.-]+\$'"
mutate F9 $F "7. the step removes something other than" "425f34b's shape: rm -rf of the module-built path on a failure" tf-plan.yml 'rm -rf "$tmp"; missed=' 'rm -rf "$tmp" "$d"; missed='
mutate F10 $F "8. the SHA-pinned module was not fetched" "425f34b's clone -b (a commit SHA can't be fetched)" tf-plan.yml \
  '          if GIT_LFS_SKIP_SMUDGE=1 git -C "$tmp" -c core.hooksPath=/dev/null init -q \\\n' '          if rmdir "$tmp" && git clone -q --depth 1 -b "$ref" "https://github.com/$org/$repo.git" "$tmp" && false \\\n'
mutate F11 $F "9. no warning for the registry source" "sources it doesn't fetch go unreported (blind, silently)" tf-plan.yml \
  '      blind="$blind $src"' '      :'
mutate F12 $F "9. a PROVIDER source (required_providers) was reported as a module" "every source = line is read, providers included" tf-plan.yml \
  '              inmod {\n' '              1 {\n'

echo "ran $ran (expected $EXPECTED), killed $killed, harness defects $bad"
[ "$ran" -eq "$EXPECTED" ] && [ "$bad" -eq 0 ] && [ "$killed" -eq "$ran" ] || exit 1
echo "all $ran mutations killed"
