#!/usr/bin/env bash
# Runs the exact `assert` step of self-test.yml (job `negative`) against recorded `jobs.json` shapes.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/check.sh
. "$root/tests/lib/check.sh"
python3 "$root/tests/lib/extract-step.py" \
  "$root/.github/workflows/self-test.yml" negative assert > "$work/assert.sh" || exit 1

expected=$'broken|Run scripts\nrust-bad-os|Validate inputs'

run_assert() { # <jobs fixture>: sets $out and $code
  cp "$root/tests/self-test/$1" "$work/jobs.json"
  out=$(cd "$work" && env -i PATH="$PATH" EXPECTED="$expected" bash "$work/assert.sh" 2>&1)
  code=$?
}

run_assert jobs-all-pass.json
check "every prefix failed at its step" eval '[ $code = 0 ] && has "$out" "OK   broken: failed at '"'"'Run scripts'"'"'" && has "$out" "OK   rust-bad-os"'

run_assert jobs-wrong-step.json
check "a job that failed at another step is reported" eval '[ $code = 1 ] && has "$out" "::error::broken: expected failure at '"'"'Run scripts'"'"', got '"'"'failure|Lint'"'"'" && has "$out" "OK   rust-bad-os"'

run_assert jobs-missing-job.json
check "a missing job and a job without steps are reported, not a jq crash" eval '[ $code = 1 ] && has "$out" "no job named" && ! has "$out" "jq: error"'

run_assert jobs-unexpected-job.json
check "a negative job with no EXPECTED row is reported" eval '[ $code = 1 ] && has "$out" "::error::forgotten: no EXPECTED row"'

report self-test
