#!/usr/bin/env bash
#
# tests/checkov-fetch.sh [repo-root] — the "Fetch modules for checkov" step's OWN bytes
# (extracted from tf-plan.yml, not copied), run against fixture stacks with a stub git
# that serves fixture modules. What checkov later sees is exactly what this lays out.
#
#   1. checkov's layout: .external_modules/github.com/<org>/<repo>/<ref> = the repo;
#   2. NESTED modules are fetched too (a module that calls a module), and //subdir
#      sources fetch the repo;
#   3. a module's examples/ and tests/ are NOT followed (they name SSH aliases and
#      fixtures that aren't the stack);
#   4. no .git survives in any clone (no remote URL, so no credential, in the tree);
#   5. a module that can't be fetched is a ::warning naming it, the step exits 0, and
#      the count line says so (checkov is blind to it, and the log shows that);
#   6. idempotent: a second run clones nothing new.

# shellcheck disable=SC2015  # ok/bad never fail, so A && ok || bad is if/else here
set -uo pipefail
root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/checkov-fetch.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
pass=0 fail=0
ok()  { echo "✅ $1"; pass=$((pass + 1)); }
bad() { echo "❌ FAIL  $1"; fail=$((fail + 1)); }

python3 - "$root/.github/workflows/tf-plan.yml" "$WORK/fetch.sh" <<'PY'
import sys, yaml
steps = [s for j in yaml.safe_load(open(sys.argv[1]))["jobs"].values() for s in j.get("steps", [])]
f = [s for s in steps if s.get("id") == "checkov-modules"]
if len(f) != 1:
    sys.exit(f"FATAL: expected one checkov-modules step, found {len(f)}")
open(sys.argv[2], "w").write(f[0]["run"])
PY
[ -s "$WORK/fetch.sh" ] || { echo "FATAL: could not extract the fetch step"; exit 2; }

# The stub git: `git clone -q --depth 1 -b <ref> https://github.com/<org>/<repo>.git <dest>`
# copies $FIX/<org>/<repo>/<ref>/ (with a .git) or fails like git does for a missing repo.
FIX="$WORK/fixtures"; mkdir -p "$WORK/bin"
cat > "$WORK/bin/git" <<'STUB'
#!/usr/bin/env bash
echo "git $*" >> "$CALLS"
[ "$1" = clone ] || exit 0
ref="$6" url="$7" dest="$8"
p="${url#https://github.com/}"; p="${p%.git}"
src="$FIX/$p/$ref"
[ -d "$src" ] || { echo "fatal: repository '$url' not found" >&2; exit 128; }
mkdir -p "$dest" && cp -R "$src/." "$dest/" && mkdir -p "$dest/.git" && echo "[remote] url = $url" > "$dest/.git/config"
STUB
chmod +x "$WORK/bin/git"

mod() { mkdir -p "$FIX/$1/$2"; printf '%b' "$3" > "$FIX/$1/$2/main.tf"; }
mod sbe-devops/tf-aws-a v1.0.0 'module "b" {\n  source = "git::https://github.com/sbe-devops/tf-aws-b.git?ref=v2.0.0"\n}\nresource "aws_s3_bucket" "a" {}\n'
mod sbe-devops/tf-aws-b v2.0.0 'resource "aws_sqs_queue" "b" {}\n'
mkdir -p "$FIX/sbe-devops/tf-aws-b/v2.0.0/examples/x" "$FIX/sbe-devops/tf-aws-b/v2.0.0/tests"
printf 'module "e" {\n  source = "git::https://github.com/sbe-devops/only-in-examples.git?ref=v9"\n}\n' > "$FIX/sbe-devops/tf-aws-b/v2.0.0/examples/x/main.tf"
printf 'module "t" {\n  source = "git::https://github.com/sbe-devops/only-in-tests.git?ref=v9"\n}\n' > "$FIX/sbe-devops/tf-aws-b/v2.0.0/tests/main.tf"
mod sbe-devops/tf-aws-route53 v0.2.0 'resource "aws_route53_zone" "z" {}\n'

stack="$WORK/stack"; mkdir -p "$stack"
cat > "$stack/main.tf" <<'TF'
module "a" {
  source = "git::https://github.com/sbe-devops/tf-aws-a.git?ref=v1.0.0"
}
module "dns" {
  source = "git::https://github.com/sbe-devops/tf-aws-route53.git//modules/env?ref=v0.2.0"
}
module "gone" {
  source = "git::https://github.com/sbe-devops/tf-aws-missing.git?ref=v0.1.0"
}
module "registry" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"
}
TF

run() { ( cd "$stack" && export PATH="$WORK/bin:$PATH" FIX CALLS="$WORK/calls.log" && bash "$WORK/fetch.sh" ) > "$WORK/out" 2>&1; RC=$?; }
: > "$WORK/calls.log"; run
E="$stack/.external_modules/github.com/sbe-devops"
[ "$RC" -eq 0 ] && ok "the step exits 0 even with a module it can't fetch" || bad "the step exited $RC"
[ -f "$E/tf-aws-a/v1.0.0/main.tf" ] && ok "1. checkov's layout: .external_modules/github.com/sbe-devops/tf-aws-a/v1.0.0" || bad "1. tf-aws-a not at checkov's path"
[ -f "$E/tf-aws-b/v2.0.0/main.tf" ] && ok "2. a NESTED module (a calls b) is fetched" || bad "2. the nested module b was not fetched"
[ -f "$E/tf-aws-route53/v0.2.0/main.tf" ] && ok "2. a //subdir source fetches the repo at its ref" || bad "2. the //subdir source was not fetched"
grep -qE 'only-in-(examples|tests)' "$WORK/calls.log" && bad "3. followed a module's examples/ or tests/" || ok "3. a module's examples/ and tests/ are not followed"
[ -z "$(find "$stack/.external_modules" -name .git)" ] && ok "4. no .git in any clone (no remote URL in the tree)" || bad "4. a .git survived: $(find "$stack/.external_modules" -name .git | head -1)"
grep -q '::warning title=checkov is blind to a module::github.com/sbe-devops/tf-aws-missing/v0.1.0' "$WORK/out" \
  && ok "5. the unfetchable module is a ::warning naming it" || bad "5. no warning for the missing module"
grep -q '^checkov modules: 3 fetched, 1 not fetched$' "$WORK/out" && ok "5. the count line: 3 fetched, 1 not fetched" || bad "5. count line: $(grep '^checkov modules' "$WORK/out")"
[ -d "$E/tf-aws-missing" ] && bad "5. a failed clone left a directory (checkov would skip it as present)" || ok "5. a failed clone leaves nothing behind"
grep -q 'terraform-aws-modules' "$WORK/calls.log" && bad "a registry source was handed to git" || ok "a registry source is left alone"
n1=$(grep -c '^git clone' "$WORK/calls.log")
: > "$WORK/calls.log"; run
n2=$(grep -c '^git clone' "$WORK/calls.log")
# The second run retries only the one that failed (it may be fetchable later); it re-clones nothing that's present.
[ "$n2" -le 1 ] && ok "6. idempotent: run 1 cloned $n1, run 2 cloned $n2 (only the missing one retried)" || bad "6. run 2 re-cloned $n2"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
