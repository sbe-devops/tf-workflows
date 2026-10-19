#!/usr/bin/env bash
#
# tests/checkov-sees-modules.sh [repo-root] — checkov must SEE what a stack deploys,
# must never HOLD a credential, and must not GATE anything.
#
# 🔑 WHY. Measured 2026-10-19 on Fitbooks' 9 tst stacks: checkov-action@v12.1347.0
# (checkov 2.0.930), run before the module token with no module download, ran 40 checks
# in total, ONE on the wireguard stack (FB-08). Our own fetch step + checkov 3.3.29:
# 964. PROOF on #11: the first fix handed the module token (GITHUB_PAT) and the
# tokenised clones to a third-party image behind a MUTABLE tag. So:
#   - SEES: in tf-plan.yml the module token, then the git credentials, then OUR fetch
#     step, then checkov, in that order;
#   - HOLDS NOTHING: no step uses bridgecrewio/checkov-action; the token appears in
#     exactly one step (the git credentials), never in the fetch or checkov step; the
#     checkov step's KEYS are an allow-list (no env:, no with:) and its run: is pinned
#     byte for byte: --network none, the working dir read-only, the image by DIGEST, the
#     same digest in both files;
#   - GATES NOTHING: --soft-fail and continue-on-error: true on checkov, and
#     continue-on-error on the fetch. Gating is a separate decision (the ladder).
# The fetch step's BEHAVIOUR is tests/checkov-fetch.sh's job.

set -uo pipefail
root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

python3 - "$root/.github/workflows" <<'PY'
import pathlib, re, sys
import yaml

wf = pathlib.Path(sys.argv[1])
fails = 0
def check(cond, msg):
    global fails
    print(("✅ " if cond else "❌ FAIL  ") + msg)
    fails += 0 if cond else 1

DIGEST_RE = r"ghcr\.io/bridgecrewio/checkov@sha256:[0-9a-f]{64}"
TOKEN = "steps.module-token.outputs.token"
KEYS = {"name", "id", "working-directory", "continue-on-error", "run"}
WD = "${{ inputs.working_directory }}"
def expected(digest, download):
    return ('docker run --rm --network none -v "$PWD:/tf:ro" -w /tf \\\n'
            f"  {digest} \\\n"
            f"  -d /tf --framework terraform {'--download-external-modules true ' if download else ''}--soft-fail -o cli\n")

for p in sorted(wf.glob("*.y*ml")):
    check("bridgecrewio/checkov-action" not in re.sub(r"(?m)^\s*#.*$", "", p.read_text()),
          f"{p.name}: no step uses bridgecrewio/checkov-action (a docker action behind a mutable image tag)")

digests = {}
for name, download in (("tf-plan.yml", True), ("tf-module-ci.yml", False)):
    doc = yaml.safe_load((wf / name).read_text())
    steps = [s for j in doc["jobs"].values() for s in j.get("steps", [])]
    ck = [i for i, s in enumerate(steps) if s.get("id") == "checkov"]
    check(len(ck) == 1, f"{name}: exactly one checkov step ({len(ck)})")
    if len(ck) != 1:
        continue
    st = steps[ck[0]]
    check(set(st) == KEYS, f"{name}: the checkov step's keys are exactly {sorted(KEYS)} (no env:, no with:, no uses:): {sorted(st)}")
    check(st.get("working-directory") == WD, f"{name}: checkov runs in the caller's working directory: {st.get('working-directory')!r}")
    check(st.get("continue-on-error") is True,
          f"{name}: checkov is report-only even if it crashes (continue-on-error: true): {st.get('continue-on-error')!r}")
    m = re.search(DIGEST_RE, str(st.get("run", "")))
    check(m is not None, f"{name}: checkov's image is pinned by DIGEST, not a tag")
    if m:
        digests[name] = m.group(0)
        check(st["run"] == expected(m.group(0), download),
              f"{name}: the checkov command is exactly the pinned one (--network none, read-only mount, --soft-fail"
              f"{', module download from the fetched dir' if download else ''}, nothing else)")
    if name == "tf-plan.yml":
        ids = [s.get("id") for s in steps]
        pos = {k: ids.index(k) if k in ids else -1 for k in ("module-token", "checkov-modules", "checkov")}
        creds = [i for i, s in enumerate(steps) if TOKEN in str(s.get("run", "")) + str(s.get("with", "")) + str(s.get("env", ""))]
        check(-1 < pos["module-token"] < pos["checkov-modules"] < pos["checkov"],
              f"{name}: the token, then OUR fetch step, then checkov: {pos}")
        check(len(creds) == 1 and creds[0] < pos["checkov-modules"] and "git config --global" in str(steps[creds[0]].get("run", "")),
              f"{name}: the module token is used in exactly ONE step, the git credentials, before the fetch (never handed to checkov): steps {creds}")
        fetch = steps[pos["checkov-modules"]] if pos["checkov-modules"] >= 0 else {}
        check(fetch.get("continue-on-error") is True and "env" not in fetch and "uses" not in fetch,
              f"{name}: the fetch is our own run: step (no uses:, no env:), and never fails the job")
check(len(set(digests.values())) == 1 and len(digests) == 2,
      f"one checkov image digest across both files: {sorted(set(digests.values()))}")
print(f"\n{'all checks passed' if not fails else f'{fails} check(s) FAILED'}")
sys.exit(1 if fails else 0)
PY
