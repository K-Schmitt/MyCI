#!/usr/bin/env bash
# Runs the exact `run:` scripts of python-ci.yml (detect, summary) against the fixtures.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
wf="$root/.github/workflows/python-ci.yml"
for step in detect summary; do
  python3 "$root/tests/lib/extract-step.py" "$wf" python-ci "$step" > "$work/$step.sh" || exit 1
done

failures=0
total=0

# run_step <step> <dir> <workdir-label> [VAR=value...]: sets $out, $code, $outputs, $summary
run_step() {
  local step=$1 dir=$2 label=$3
  shift 3
  : > "$work/output"
  : > "$work/summary"
  out=$(cd "$dir" && env -i PATH="$PATH" HOME="$HOME" WORKDIR="$label" \
    GITHUB_OUTPUT="$work/output" GITHUB_STEP_SUMMARY="$work/summary" "$@" \
    bash "$work/$step.sh" 2>&1)
  code=$?
  outputs=$(cat "$work/output")
  summary=$(cat "$work/summary")
}

check() { # <name> <condition...>
  local name=$1
  shift
  total=$((total + 1))
  if "$@"; then
    echo "PASS $name"
  else
    echo "FAIL $name"
    printf '%s\n' "$out" "$outputs" "$summary" | sed 's/^/    | /'
    failures=$((failures + 1))
  fi
}
has() { grep -qF -- "$2" <<< "$1"; }

fx="$root/fixtures"
reqs="requirements.txt,requirements-dev.txt"

run_step detect "$fx/python-ok" fixtures/python-ok "REQUIREMENTS=$reqs" "PYTHON_VERSION=3.12"
check "detect: lists every requirements file and takes the version from .python-version" \
  eval '[ $code = 0 ] && grep -qx "install-args=-r requirements.txt -r requirements-dev.txt" <<< "$outputs" && grep -qx "python-version=3.11" <<< "$outputs"'

run_step detect "$fx/python-broken" fixtures/python-broken "REQUIREMENTS=$reqs" "PYTHON_VERSION=3.12"
check "detect: without .python-version the input wins" \
  eval '[ $code = 0 ] && grep -qx "python-version=3.12" <<< "$outputs"'

run_step detect "$fx/python-no-requirements" fixtures/python-no-requirements "REQUIREMENTS=$reqs" "PYTHON_VERSION=3.12"
check "detect: missing requirements file fails and names it" \
  eval '[ $code = 1 ] && has "$out" "Requirements file '"'"'requirements.txt'"'"' not found in '"'"'fixtures/python-no-requirements'"'"'"'

run_step detect "$fx/python-no-requirements" fixtures/python-no-requirements "REQUIREMENTS=" "PYTHON_VERSION=3.12"
check "detect: empty requirements input installs nothing" \
  eval '[ $code = 0 ] && grep -qx "install-args=" <<< "$outputs"'

run_step detect "$fx/python-unpinned" fixtures/python-unpinned "REQUIREMENTS=$reqs" "PYTHON_VERSION=3.12"
check "detect: unpinned requirement warns but does not fail" \
  eval '[ $code = 0 ] && has "$out" "::warning::" && has "$out" "requirements.txt"'

run_step detect "$fx/python-ok" fixtures/python-ok "REQUIREMENTS=$reqs" "PYTHON_VERSION=3.12"
check "detect: pinned requirements raise no warning" eval '! has "$out" "::warning::"'

run_step summary "$fx/python-ok" fixtures/python-ok "GATE=python -m pytest -q" "GATE_OUTCOME=success"
check "summary: green gate" eval '[ $code = 0 ] && has "$summary" "✅ passed" && has "$summary" "python -m pytest -q"'

run_step summary "$fx/python-ok" fixtures/python-ok "GATE=pytest" "GATE_OUTCOME=failure"
check "summary: red gate" eval '[ $code = 0 ] && has "$summary" "❌ failed"'

run_step summary "$fx/python-ok" fixtures/python-ok "GATE=pytest" "GATE_OUTCOME=skipped"
check "summary: gate never ran" eval '[ $code = 0 ] && has "$summary" "⏭️ not run"'

echo "python-ci: $((total - failures))/$total passed"
[ "$failures" -eq 0 ]
