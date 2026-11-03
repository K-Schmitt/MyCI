#!/usr/bin/env bash
# Runs the exact `validate`, `detect` and `summary` scripts of android-ci.yml against the fixtures.
# The gate itself (a Gradle build) is exercised by self-test, not here.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/check.sh
. "$root/tests/lib/check.sh"
wf="$root/.github/workflows/android-ci.yml"
for step in validate detect summary; do
  python3 "$root/tests/lib/extract-step.py" "$wf" android-ci "$step" > "$work/$step.sh" || exit 1
done

# run_step <step> <dir> <workdir-label> [VAR=value...]: sets $out, $code, $outputs, $summary
run_step() {
  local step=$1 dir=$2 label=$3
  shift 3
  : > "$work/output"
  : > "$work/summary"
  out=$(cd "$dir" && env -i PATH="$PATH" WORKDIR="$label" \
    GITHUB_OUTPUT="$work/output" GITHUB_STEP_SUMMARY="$work/summary" "$@" \
    bash "$work/$step.sh" 2>&1)
  code=$?
  outputs=$(cat "$work/output")
  summary=$(cat "$work/summary")
}

fx="$root/fixtures"

# --- validate ------------------------------------------------------------------------------
run_step validate "$fx/android-ok" fixtures/android-ok
check "validate: a relative working-directory passes" eval '[ $code = 0 ]'
run_step validate "$fx/android-ok" ../outside
check "validate: working-directory rejects '../outside'" eval '[ $code = 1 ] && has "$out" "Input '"'"'working-directory'"'"'"'

# --- detect --------------------------------------------------------------------------------
run_step detect "$fx/android-ok" fixtures/android-ok
check "detect: wrapper found, Gradle version read from the properties" eval '[ $code = 0 ] && grep -qx "gradle-version=9.7.1" <<< "$outputs"'

run_step detect "$fx/android-no-wrapper" fixtures/android-no-wrapper
check "detect: missing wrapper fails and says how to add it" eval '[ $code = 1 ] && has "$out" "No Gradle wrapper in '"'"'fixtures/android-no-wrapper'"'"'" && has "$out" "gradle wrapper"'

mkdir "$work/empty"
run_step detect "$work/empty" empty
check "detect: no settings file fails and names the folder" eval '[ $code = 1 ] && has "$out" "No settings.gradle"'

cp -r "$fx/android-ok" "$work/noexec"
chmod -x "$work/noexec/gradlew"
run_step detect "$work/noexec" noexec
check "detect: a non-executable gradlew is fixed for the run and reported" eval '[ $code = 0 ] && has "$out" "::warning::" && has "$out" "git update-index --chmod=+x gradlew" && [ -x "$work/noexec/gradlew" ]'

# --- summary -------------------------------------------------------------------------------
s() { run_step summary "$fx/android-ok" fixtures/android-ok "GATE=./gradlew assembleDebug check" JAVA_VERSION=21 GRADLE_VERSION=9.7.1 "$@"; }
s GATE_OUTCOME=success
check "summary: green gate" eval '[ $code = 0 ] && has "$summary" "✅ passed" && has "$summary" "./gradlew assembleDebug check" && has "$summary" "Gradle \`9.7.1\`"'
s GATE_OUTCOME=failure
check "summary: red gate" eval '[ $code = 0 ] && has "$summary" "❌ failed"'
s GATE_OUTCOME=skipped
check "summary: gate never ran" eval '[ $code = 0 ] && has "$summary" "⏭️ not run"'

report android-ci
