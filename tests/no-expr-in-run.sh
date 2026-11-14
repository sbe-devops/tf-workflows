#!/usr/bin/env bash
#
# tests/no-expr-in-run.sh — no `${{ }}` expression inside any `run:` block.
#
# An expression in `run:` is pasted into the script's SOURCE before bash sees it: a
# caller's value becomes code, and a secret (the module token here, until 2026-11-14) is
# written into the step's script file on disk. Every value reaches a script through `env:`.
# Stricter than a list of contexts: ANY expression inside run: fails.
#
# Dependency-free, like the other gates here (bash, awk). A `run:` block is the `run:` line
# plus every following line indented deeper than the `run:` key (or blank); a one-line
# `run: …` is checked on its own line.
#
#   tests/no-expr-in-run.sh [file.yml ...]    (default: .github/workflows/*.yml)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ $# -gt 0 ]; then files=("$@"); else files=("$here"/../.github/workflows/*.yml); fi

scan() {
  awk -v F="$(basename "$1")" '
    function indent(s) { match(s, /[^ ]/); return RSTART - 1 }
    {
      line = $0
      if (inrun) {
        if (line ~ /^[[:space:]]*$/) { next }
        if (indent(line) > runind) { if (index(line, "${{")) { print F ":" NR ": " line; n++ } ; next }
        inrun = 0
      }
      if (match(line, /^[[:space:]]*(- )?run:[[:space:]]*/)) {
        # Read the rest BEFORE indent(): it calls match() and overwrites RSTART/RLENGTH
        # (the first version did it the other way round and found nothing, on main either).
        rest = substr(line, RSTART + RLENGTH)
        if (line ~ /^[[:space:]]*- run:/) runind = indent(line) + 2; else runind = indent(line)
        if (rest ~ /^[|>][-+0-9]*[[:space:]]*$/) { inrun = 1 }
        else if (index(rest, "${{")) { print F ":" NR ": " line; n++ }
      }
    }
    END { exit (n > 0) }
  ' "$1"
}

# --self-test: fixtures for every shape the parser must and must not flag.
if [ "${1:-}" = "--self-test" ]; then
  d="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/nexpr.XXXXXX")"; trap 'rm -rf -- "$d"' EXIT
  ok=0
  fixture() {  # fixture <name> <expect: flag|clean> <yaml body>
    printf '%s\n' "$3" > "$d/$1.yml"
    if scan "$d/$1.yml" >/dev/null; then got=clean; else got=flag; fi
    if [ "$got" = "$2" ]; then echo "  ✅ $1: $got"; else echo "  🔴 $1: expected $2, got $got"; ok=1; fi
  }
  # shellcheck disable=SC2016 # fixtures hold literal ${{ }}
  {
  fixture block-run flag $'jobs:\n  j:\n    steps:\n      - name: x\n        run: |\n          echo "${{ inputs.a }}"'
  fixture one-line-run flag $'jobs:\n  j:\n    steps:\n      - run: echo ${{ inputs.a }}'
  fixture list-item-block flag $'jobs:\n  j:\n    steps:\n      - run: |\n          set -e\n\n          echo ${{ github.event.x }}'
  fixture folded-block flag $'jobs:\n  j:\n    steps:\n      - name: x\n        run: >-\n          echo ${{ steps.s.outputs.o }}'
  fixture env-is-fine clean $'jobs:\n  j:\n    steps:\n      - name: x\n        env:\n          A: ${{ inputs.a }}\n        run: |\n          echo "$A"'
  fixture with-is-fine clean $'jobs:\n  j:\n    steps:\n      - uses: a/b@c\n        with:\n          x: ${{ inputs.a }}'
  fixture after-block clean $'jobs:\n  j:\n    steps:\n      - name: x\n        run: |\n          echo hi\n        env:\n          A: ${{ inputs.a }}'
  }
  if [ $ok -ne 0 ]; then echo "🔴 self-test: FAILED"; exit 1; fi
  echo "self-test: passed"
  exit 0
fi

bad=0
for f in "${files[@]}"; do scan "$f" || bad=1; done
if [ $bad -ne 0 ]; then echo "🔴 expression(s) inside run: (above). Pass each through env: and use \"\$VAR\"."; exit 1; fi
echo "✓ no expression inside any run: block (${#files[@]} file(s))"
