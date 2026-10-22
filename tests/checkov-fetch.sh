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
#   6. idempotent: a second run fetches nothing that is already laid out;
#   7. 🔴 TRAVERSAL (INFRA on #11): a fetched module's source is THIRD-PARTY input. A
#      source whose org, repo or ref is "..", "." or anything outside the allow-list is
#      REFUSED (a ::warning) and touches nothing. Org, repo and ref are one path
#      component each, so "../..?ref=<name>" reaches a FILE in the stack's own
#      directory: on 425f34b a failed clone then rm -rf'd it (main.tf, before the
#      plan). Sentinels in and beside the stack, the stack's main.tf and the modules
#      already fetched must all survive, with every clone FAILING;
#   8. a module pinned by commit SHA is fetched (and so scanned), not silently skipped;
#   9. a source the step can't fetch at all (the registry, a local ../ outside the
#      mount) is a ::warning naming it: checkov is blind to it, and the log says so;
#      and only MODULE blocks are read (a provider's required_providers source isn't one).

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

# The stub git serves $FIX/<org>/<repo>/<ref>/, for either way of fetching:
#   git clone -q --depth 1 -b <ref> https://github.com/<org>/<repo>.git <dest>
#   git -C <dir> init -q | git -C <dir> fetch -q --depth 1 <url> <ref> | git -C <dir> checkout -q FETCH_HEAD
# A missing repo fails like git does. Every call is logged.
FIX="$WORK/fixtures"; mkdir -p "$WORK/bin"
cat > "$WORK/bin/git" <<'STUB'
#!/usr/bin/env bash
echo "git $*" >> "$CALLS"
serve() {  # serve <url> <ref> <dest>
  local p="${1#https://github.com/}"; p="${p%.git}"
  [ -d "$FIX/$p/$2" ] || { echo "fatal: repository '$1' not found" >&2; return 128; }
  mkdir -p "$3" && cp -R "$FIX/$p/$2/." "$3/" && mkdir -p "$3/.git" && echo "[remote] url = $1" > "$3/.git/config"
}
if [ "$1" = clone ]; then
  [[ "$6" =~ ^[0-9a-f]{40}$ ]] && { echo "warning: Could not find remote branch $6 to clone." >&2; exit 128; }
  [ -e "$8" ] && { echo "fatal: destination path '$8' already exists and is not an empty directory." >&2; exit 128; }
  serve "$7" "$6" "$8"; exit
fi
if [ "$1" = -C ]; then
  dir="$2"; shift 2
  while [ "$1" = -c ]; do shift 2; done
  case "$1" in
    init) mkdir -p "$dir/.git" ;;
    fetch) url="${*: -2:1}" ref="${*: -1}"; serve "$url" "$ref" "$dir.fetched" || exit 128; echo "$dir.fetched" > "$dir/.git/FETCH_SRC" ;;
    checkout) src="$(cat "$dir/.git/FETCH_SRC")"; cp -R "$src/." "$dir/"; rm -rf "$src" ;;
  esac
  exit 0
fi
exit 0
STUB
chmod +x "$WORK/bin/git"

mod() { mkdir -p "$FIX/$1/$2"; printf '%b' "$3" > "$FIX/$1/$2/main.tf"; }
SHA=0123456789abcdef0123456789abcdef01234567
mod sbe-devops/tf-aws-a v1.0.0 'module "b" {\n  source = "git::https://github.com/sbe-devops/tf-aws-b.git?ref=v2.0.0"\n}\nresource "aws_s3_bucket" "a" {}\n'
mod sbe-devops/tf-aws-b v2.0.0 'resource "aws_sqs_queue" "b" {}\n'
mkdir -p "$FIX/sbe-devops/tf-aws-b/v2.0.0/examples/x" "$FIX/sbe-devops/tf-aws-b/v2.0.0/tests"
printf 'module "e" {\n  source = "git::https://github.com/sbe-devops/only-in-examples.git?ref=v9"\n}\n' > "$FIX/sbe-devops/tf-aws-b/v2.0.0/examples/x/main.tf"
printf 'module "t" {\n  source = "git::https://github.com/sbe-devops/only-in-tests.git?ref=v9"\n}\n' > "$FIX/sbe-devops/tf-aws-b/v2.0.0/tests/main.tf"
mod sbe-devops/tf-aws-route53 v0.2.0 'resource "aws_route53_zone" "z" {}\n'
mod sbe-devops/tf-aws-pinned "$SHA" 'resource "aws_sns_topic" "p" {}\n'
# A THIRD-PARTY module whose own sources try to climb out. Every one of them fails to
# clone (the stub has no such repo), which is the path that used to rm -rf.
mod someone/evil v1.0.0 'module "x1" {\n  source = "git::https://github.com/../..?ref=.."\n}\nmodule "x2" {\n  source = "git::https://github.com/sbe-devops/..?ref=.."\n}\nmodule "x3" {\n  source = "git::https://github.com/./.?ref=."\n}\nmodule "x4" {\n  source = "git::https://github.com/sbe-devops/tf-aws-a.git?ref=../../.."\n}\nmodule "x5" {\n  source = "git::https://github.com/../..?ref=SENTINEL"\n}\nmodule "x6" {\n  source = "git::https://github.com/../..?ref=main.tf"\n}\nresource "aws_sqs_queue" "evil" {}\n'

outer="$WORK/outer"; stack="$outer/stack"; mkdir -p "$stack"
echo keep > "$outer/SENTINEL"; echo keep > "$WORK/SENTINEL"
cat > "$stack/main.tf" <<TF
module "a" {
  source = "git::https://github.com/sbe-devops/tf-aws-a.git?ref=v1.0.0"
}
module "dns" {
  source = "git::https://github.com/sbe-devops/tf-aws-route53.git//modules/env?ref=v0.2.0"
}
module "pinned" {
  source = "git::https://github.com/sbe-devops/tf-aws-pinned.git?ref=$SHA"
}
module "gone" {
  source = "git::https://github.com/sbe-devops/tf-aws-missing.git?ref=v0.1.0"
}
module "evil" {
  source = "git::https://github.com/someone/evil.git?ref=v1.0.0"
}
module "registry" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"
}
module "sibling" {
  source = "../shared"
}
module "local" {
  source = "./sub"
}
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
TF

echo keep > "$stack/SENTINEL"
run() { ( cd "$stack" && export PATH="$WORK/bin:$PATH" FIX CALLS="$WORK/calls.log" && bash "$WORK/fetch.sh" ) > "$WORK/out" 2>&1; RC=$?; }
: > "$WORK/calls.log"; run
E="$stack/.external_modules/github.com/sbe-devops"
[ "$RC" -eq 0 ] && ok "the step exits 0 even with modules it can't fetch" || bad "the step exited $RC"
[ -f "$E/tf-aws-a/v1.0.0/main.tf" ] && ok "1. checkov's layout: .external_modules/github.com/sbe-devops/tf-aws-a/v1.0.0" || bad "1. tf-aws-a not at checkov's path"
[ -f "$E/tf-aws-b/v2.0.0/main.tf" ] && ok "2. a NESTED module (a calls b) is fetched" || bad "2. the nested module b was not fetched"
[ -f "$E/tf-aws-route53/v0.2.0/main.tf" ] && ok "2. a //subdir source fetches the repo at its ref" || bad "2. the //subdir source was not fetched"
grep -qE 'only-in-(examples|tests)' "$WORK/calls.log" && bad "3. followed a module's examples/ or tests/" || ok "3. a module's examples/ and tests/ are not followed"
[ -z "$(find "$stack/.external_modules" -name .git -o -name '.fetch.*')" ] && ok "4. no .git in any clone, and no .fetch.* temp dir left (no remote URL in the tree)" || bad "4. a .git survived: $(find "$stack/.external_modules" -name .git | head -1)"
grep -q '::warning title=checkov is blind to a module::github.com/sbe-devops/tf-aws-missing/v0.1.0' "$WORK/out" \
  && ok "5. the unfetchable module is a ::warning naming it" || bad "5. no warning for the missing module"
[ -e "$E/tf-aws-missing/v0.1.0" ] && bad "5. a failed fetch left its destination (checkov would skip it as present)" || ok "5. a failed fetch leaves nothing behind"
grep -q 'terraform-aws-modules' "$WORK/calls.log" && bad "a registry source was handed to git" || ok "a registry source is not handed to git"

# 7. traversal
[ -f "$stack/SENTINEL" ] && [ -f "$outer/SENTINEL" ] && [ -f "$WORK/SENTINEL" ] && ok "7. sentinels in and beside the stack survive sources that resolve outside .external_modules" \
  || bad "7. TRAVERSAL: a module source deleted a path outside .external_modules (the sentinel is gone)"
[ -f "$E/tf-aws-a/v1.0.0/main.tf" ] && [ -f "$stack/main.tf" ] && ok "7. the stack and the modules already fetched survive them too" \
  || bad "7. TRAVERSAL: a module source deleted the stack or a fetched module"
n_ref=$(grep -c 'title=checkov refused a module source' "$WORK/out")
[ "$n_ref" -eq 6 ] && ok "7. all six climbing sources are REFUSED with a ::warning (6)" || bad "7. refused-source warnings: $n_ref, want 6"
grep -qE 'git .*(github\.com/\.\.|github\.com/\./|ref=\.\.|-b \.\.| \.\.$| \.$)' "$WORK/calls.log" \
  && bad "7. a climbing source was handed to git: $(grep -E 'github\.com/\.|ref=\.|-b \.' "$WORK/calls.log" | head -1)" \
  || ok "7. no climbing source is ever handed to git"

# 7. by construction: the step removes nothing but its own mktemp dir (and that dir's .git)
rmt=$(grep -oE 'rm -r?f? +[^;&|]+' "$WORK/fetch.sh" | sed -E 's/[[:space:]]+$//' | sort -u | tr '\n' '|')
# shellcheck disable=SC2016  # the step's literal text, deliberately unexpanded
[ "$rmt" = 'rm -rf "$tmp"|rm -rf "$tmp/.git"|' ] && ok "7. the step removes only its own mktemp dir and its .git (never a path built from a module source)" \
  || bad "7. the step removes something other than \$tmp: $rmt"

# 8. a commit SHA
[ -f "$E/tf-aws-pinned/$SHA/main.tf" ] && ok "8. a module pinned by commit SHA is fetched (and so scanned)" || bad "8. the SHA-pinned module was not fetched"

# 9. the sources the step can't fetch, named
grep -q '::warning title=checkov is blind to a module::terraform-aws-modules/vpc/aws' "$WORK/out" \
  && ok "9. a registry source is a ::warning naming it" || bad "9. no warning for the registry source"
grep -q '::warning title=checkov is blind to a module::../shared' "$WORK/out" \
  && ok "9. a local ../ source outside the mount is a ::warning naming it" || bad "9. no warning for the ../ source"
grep -q 'checkov is blind to a module::./sub' "$WORK/out" && bad "9. a ./ source inside the mount was reported blind" || ok "9. a ./ source inside the mount is not reported"
grep -q 'checkov is blind to a module::hashicorp/aws' "$WORK/out" && bad "9. a PROVIDER source (required_providers) was reported as a module" || ok "9. only module blocks are read (a provider's source is not a module)"
grep -q '^checkov modules: 5 fetched, 3 not fetched, 6 refused$' "$WORK/out" \
  && ok "5. the count line: 5 fetched, 3 not fetched (1 missing + the registry + ../shared), 6 refused" || bad "5. count line: $(grep '^checkov modules' "$WORK/out")"

# 6. idempotent
: > "$WORK/calls.log"; run
n2=$(grep -cE '^git (clone |-C .* fetch )' "$WORK/calls.log")
[ "$n2" -le 1 ] && ok "6. idempotent: a re-run fetched $n2 (only the missing one retried)" || bad "6. run 2 re-fetched $n2"
[ -f "$E/tf-aws-a/v1.0.0/main.tf" ] && ok "6. a re-run leaves present modules in place" || bad "6. a re-run deleted a present module"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
