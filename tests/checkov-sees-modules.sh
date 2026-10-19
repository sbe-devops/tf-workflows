#!/usr/bin/env bash
#
# tests/checkov-sees-modules.sh [repo-root] — checkov must SEE what a stack deploys,
# and this change must not make it GATE anything.
#
# 🔑 WHY. Measured 2026-10-19 on Fitbooks' 9 tst stacks: at v12.1347.0 (checkov
# 2.0.930), with no module download and the step BEFORE the module token, checkov ran
# 40 checks in total, ONE on the wireguard stack (FB-08). With the modules fetched by
# the token and checkov 3.3.29: 964. The three halves of that are each asserted here,
# because each alone changes nothing:
#   - the token step comes BEFORE checkov in tf-plan.yml (a private module can't be
#     fetched without it);
#   - tf-plan's checkov downloads external modules and is handed that token as
#     github_pat (checkov's own input; the runner's git insteadOf config is invisible
#     inside a docker action);
#   - the action is pinned to one SHA, the same in tf-plan and tf-module-ci, and is not
#     the 2022 pin (2.0.930 parses tf-aws-wireguard to zero resources).
# And the gate: soft_fail stays true in both. Turning it off is a separate, breaking
# decision (Eric's), not a side effect of this.
#
# Static assertions on the parsed workflows: the property is the job's definition.

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

OLD_PIN = "bridgecrewio/checkov-action@v12.1347.0"
TOKEN = "${{ steps.module-token.outputs.token }}"
pins = {}
for name in ("tf-plan.yml", "tf-module-ci.yml"):
    doc = yaml.safe_load((wf / name).read_text())
    steps = [s for j in doc["jobs"].values() for s in j.get("steps", [])]
    ck = [i for i, s in enumerate(steps) if str(s.get("uses", "")).startswith("bridgecrewio/checkov-action@")]
    check(len(ck) == 1, f"{name}: exactly one checkov step ({len(ck)})")
    if len(ck) != 1:
        continue
    st = steps[ck[0]]; w = st.get("with") or {}
    pins[name] = st["uses"]
    check(st["uses"] != OLD_PIN, f"{name}: not the 2022 pin {OLD_PIN} (checkov 2.0.930 parses some modules to zero resources)")
    check(re.fullmatch(r"bridgecrewio/checkov-action@[0-9a-f]{40}", st["uses"]) is not None,
          f"{name}: pinned to a full commit SHA: {st['uses']}")
    check(w.get("soft_fail") is True, f"{name}: soft_fail stays true (this change reports, it does not gate): {w.get('soft_fail')!r}")
    if name == "tf-plan.yml":
        tok = [i for i, s in enumerate(steps) if s.get("id") == "module-token"]
        check(len(tok) == 1 and tok[0] < ck[0],
              f"{name}: the module-token step comes BEFORE checkov (token={tok}, checkov={ck[0]})")
        check(w.get("download_external_modules") is True,
              f"{name}: checkov downloads external modules: {w.get('download_external_modules')!r}")
        check(w.get("github_pat") == TOKEN,
              f"{name}: checkov gets the module token as github_pat: {w.get('github_pat')!r}")
check(len(set(pins.values())) == 1, f"one checkov-action pin across both files: {sorted(set(pins.values()))}")
print(f"\n{'all checks passed' if not fails else f'{fails} check(s) FAILED'}")
sys.exit(1 if fails else 0)
PY
