#!/usr/bin/env bash
# Runs the exact `run:` scripts of node-ci.yml (detect, require, summary) against the fixtures.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
wf="$root/.github/workflows/node-ci.yml"
for step in detect require summary; do
  python3 "$root/tests/lib/extract-step.py" "$wf" node-ci "$step" > "$work/$step.sh" || exit 1
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

check() { # <name> <condition-description> <command...>
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

run_step detect "$fx/node-npm" fixtures/node-npm PNPM_VERSION=
check "detect npm" eval '[ $code = 0 ] && has "$outputs" "pm=npm" && has "$outputs" "lockfile=fixtures/node-npm/package-lock.json" && has "$outputs" "nvmrc="'

run_step detect "$fx/node-pnpm" fixtures/node-pnpm PNPM_VERSION=
check "detect pnpm via packageManager" eval '[ $code = 0 ] && has "$outputs" "pm=pnpm" && grep -qx "pnpm-version=" <<< "$outputs"'

run_step detect "$fx/node-pnpm" fixtures/node-pnpm PNPM_VERSION=9.0.0
check "packageManager wins over pnpm-version input" eval '[ $code = 0 ] && grep -qx "pnpm-version=" <<< "$outputs"'

cp -r "$fx/node-pnpm" "$work/nopm"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d.pop("packageManager"); json.dump(d, open(p, "w"))' "$work/nopm/package.json"
run_step detect "$work/nopm" nopm PNPM_VERSION=
check "pnpm without packageManager nor input fails" eval '[ $code = 1 ] && has "$out" "no pnpm-version input was given"'

run_step detect "$work/nopm" nopm PNPM_VERSION=8.15.9
check "pnpm-version input used without packageManager" eval '[ $code = 0 ] && grep -qx "pnpm-version=8.15.9" <<< "$outputs"'

run_step detect "$fx/node-nolock" fixtures/node-nolock PNPM_VERSION=
check "no lockfile fails" eval '[ $code = 1 ] && has "$out" "No lockfile in '"'"'fixtures/node-nolock'"'"'"'

cp -r "$fx/node-npm" "$work/nvm"
echo 22 > "$work/nvm/.nvmrc"
run_step detect "$work/nvm" sub/app PNPM_VERSION=
check ".nvmrc is reported" eval '[ $code = 0 ] && grep -qx "nvmrc=sub/app/.nvmrc" <<< "$outputs"'

run_step require "$fx/node-npm" fixtures/node-npm "REQUIRE=lint,build"
check "require satisfied" eval '[ $code = 0 ]'

run_step require "$fx/node-npm" fixtures/node-npm "REQUIRE= lint , build ,"
check "require tolerates spaces and trailing comma" eval '[ $code = 0 ]'

run_step require "$fx/node-missing-script" fixtures/node-missing-script "REQUIRE=lint,typecheck,build"
check "missing required scripts listed" eval '[ $code = 1 ] && has "$out" "Required package.json scripts missing: lint typecheck"'

run_step require "$fx/node-missing-script" fixtures/node-missing-script "REQUIRE="
check "empty require accepts anything" eval '[ $code = 0 ]'

run_step summary "$fx/node-pnpm" fixtures/node-pnpm PM=pnpm \
  "OUTCOMES=lint=success typecheck=success test=failure build=skipped"
check "summary table" eval '[ $code = 0 ] && has "$summary" "| lint | ✅ passed |" && has "$summary" "| typecheck | ⚠️ absent |" && has "$summary" "| test | ❌ failed |" && has "$summary" "| build | ⏭️ not run |" && has "$summary" "Package manager: \`pnpm\`"'

run_step summary "$fx/node-nolock" fixtures/node-nolock PM= \
  "OUTCOMES=lint=skipped typecheck=skipped test=skipped build=skipped"
check "summary when detection failed" eval '[ $code = 0 ] && has "$summary" "not detected" && has "$summary" "| lint | ⏭️ not run |"'

echo "node-ci: $((total - failures))/$total passed"
[ "$failures" -eq 0 ]
