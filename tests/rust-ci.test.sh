#!/usr/bin/env bash
# Runs the exact `run:` scripts of rust-ci.yml (detect, summary) against the fixtures.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
wf="$root/.github/workflows/rust-ci.yml"
for step in detect summary; do
  python3 "$root/tests/lib/extract-step.py" "$wf" rust-ci "$step" > "$work/$step.sh" || exit 1
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

run_step detect "$fx/rust-ok" fixtures/rust-ok
check "detect: toolchain, lockfile and deny.toml present" eval '[ $code = 0 ] && grep -qx "has-deny=true" <<< "$outputs"'

cp -r "$fx/rust-ok" "$work/nodeny"
rm -f "$work/nodeny/deny.toml"
run_step detect "$work/nodeny" nodeny
check "detect: no deny.toml means no cargo-deny install" eval '[ $code = 0 ] && grep -qx "has-deny=false" <<< "$outputs"'

run_step detect "$fx/rust-no-toolchain" fixtures/rust-no-toolchain
check "detect: missing rust-toolchain.toml fails and names the file" eval '[ $code = 1 ] && has "$out" "No rust-toolchain.toml in '"'"'fixtures/rust-no-toolchain'"'"'"'

run_step detect "$fx/rust-no-lock" fixtures/rust-no-lock
check "detect: missing Cargo.lock fails and names the file" eval '[ $code = 1 ] && has "$out" "No Cargo.lock in '"'"'fixtures/rust-no-lock'"'"'"'

run_step summary "$fx/rust-ok" fixtures/rust-ok "GATE=cargo xtask check" "GATE_OUTCOME=success" "HAS_DENY=true"
check "summary: green gate" eval '[ $code = 0 ] && has "$summary" "✅ passed" && has "$summary" "cargo xtask check" && has "$summary" "cargo-deny: yes"'

run_step summary "$fx/rust-ok" fixtures/rust-ok "GATE=cargo test" "GATE_OUTCOME=failure" "HAS_DENY=false"
check "summary: red gate" eval '[ $code = 0 ] && has "$summary" "❌ failed" && has "$summary" "cargo-deny: no"'

run_step summary "$fx/rust-ok" fixtures/rust-ok "GATE=cargo test" "GATE_OUTCOME=skipped" "HAS_DENY="
check "summary: gate never ran" eval '[ $code = 0 ] && has "$summary" "⏭️ not run"'

echo "rust-ci: $((total - failures))/$total passed"
[ "$failures" -eq 0 ]
