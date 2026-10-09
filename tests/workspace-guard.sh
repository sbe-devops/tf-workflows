#!/usr/bin/env bash
#
# tests/workspace-guard.sh — T1's guard, tested against its own bytes.
#
# 🔑 WHY THIS IS TESTABLE AT ALL. The guard's only input is the output of
# `terraform workspace list`, so a stub `terraform` on PATH reproduces every
# layout exactly — a workspace-per-environment stack, a selected non-default
# workspace, a backend that errors. No AWS, no state, no credentials.
#
# Same extraction rule as tests/destroy-guard.sh: the lines between the two
# markers in the workflow are what runs here, and the extractor FAILS CLOSED if
# it cannot find them.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workflow="$here/../.github/workflows/tf-destroy.yml"
[ -f "$workflow" ] || { echo "FATAL: $workflow not found"; exit 2; }

raw="$(awk '
  /# >>> WORKSPACE GUARD BEGIN/ { inside = 1; next }
  /# <<< WORKSPACE GUARD END/   { inside = 0; next }
  inside                        { print }
' "$workflow")"
[ -n "$raw" ] || { echo "FATAL: workspace-guard markers not found in $workflow"; exit 2; }

indent="$(printf '%s\n' "$raw" | sed -n '1s/^\([[:space:]]*\).*/\1/p')"
guard="$(printf '%s\n' "$raw" | sed "s/^${indent}//")"

lines="$(printf '%s\n' "$guard" | wc -l | tr -d ' ')"
[ "$lines" -ge 20 ] || { echo "FATAL: extracted only $lines lines; that is a fragment, not the guard"; exit 2; }
# shellcheck disable=SC2016  # matching the LITERAL characters ${{ is the point
case "$guard" in
  *'${{'*) echo "FATAL: the guard body interpolates a GitHub expression; keep contexts in env:"; exit 2 ;;
esac
printf 'extracted %s lines of workspace guard\n\n' "$lines"

pass=0
fail=0
stubdir="$(mktemp -d)"
trap 'rm -rf "$stubdir"' EXIT

# run_guard <stub-stdout> <stub-exit> [TF_WORKSPACE]
run_guard() {
  local out="$1" rc="$2" tfws="${3-}"
  cat > "$stubdir/terraform" <<STUB
#!/usr/bin/env bash
# Stub terraform: only 'workspace list' is used by the guard.
if [ "\$1" = "workspace" ] && [ "\$2" = "list" ]; then
  printf '%s' "\$(cat <<'OUT'
$out
OUT
)"
  printf '\n'
  exit $rc
fi
echo "stub terraform: unexpected invocation: \$*" >&2
exit 99
STUB
  chmod +x "$stubdir/terraform"
  if [ -n "$tfws" ]; then
    PATH="$stubdir:$PATH" TF_WORKSPACE="$tfws" bash -c "$guard" 2>&1
  else
    PATH="$stubdir:$PATH" bash -c "$guard" 2>&1
  fi
}

refuses() {
  local name="$1" out="$2" rc="$3" expect="$4" tfws="${5-}" got code
  got="$(run_guard "$out" "$rc" "$tfws")"
  code=$?
  if [ "$code" -eq 0 ]; then
    printf '❌ FAIL  %s\n        ALLOWED a layout that must be refused\n        stub output: %s\n' "$name" "$out"
    fail=$((fail + 1))
    return
  fi
  if ! printf '%s' "$got" | grep -qF -- "$expect"; then
    printf '❌ FAIL  %s\n        refused, but not for the stated reason\n        wanted: %s\n        got:    %s\n' "$name" "$expect" "$got"
    fail=$((fail + 1))
    return
  fi
  printf '✅ refused  %s\n' "$name"
  pass=$((pass + 1))
}

allows() {
  local name="$1" out="$2" rc="$3" tfws="${4-}" got code
  got="$(run_guard "$out" "$rc" "$tfws")"
  code=$?
  if [ "$code" -ne 0 ]; then
    printf '❌ FAIL  %s\n        REFUSED a layout that must pass (exit %s): %s\n' "$name" "$code" "$got"
    fail=$((fail + 1))
    return
  fi
  printf '✅ allowed  %s\n' "$name"
  pass=$((pass + 1))
}

echo "── THE ASK: a directory-keyed allow-list cannot describe (directory × workspace) ──"
refuses "workspace-per-environment: one entry would authorise every env" \
  '  default
* staging
  prod' 0 "has more than the default workspace"
refuses "two workspaces, default selected" \
  '* default
  staging' 0 "has more than the default workspace"
refuses "a single non-default workspace" \
  '* staging' 0 "has more than the default workspace"
refuses "TF_WORKSPACE moves the target even with a clean layout" \
  '* default' 0 'TF_WORKSPACE is set to "staging"' staging

echo
echo "── fail closed on anything that is not an answer ─────────────────────────────────"
refuses "the backend errors" \
  'Error: Failed to get existing workspaces: AccessDenied' 1 "could not list Terraform workspaces"
refuses "no workspaces at all" \
  '' 0 "reported no workspaces at all"
refuses "only blank lines" \
  '

' 0 "reported no workspaces at all"

echo
echo "── and the layout the allow-list CAN describe ────────────────────────────────────"
allows "default only, selected"      '* default' 0
allows "default only, not selected"  '  default' 0
allows "default with trailing blank line" '* default
' 0
allows "TF_WORKSPACE set to default explicitly" '* default' 0 default

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
