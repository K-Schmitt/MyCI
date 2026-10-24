#!/usr/bin/env bash
# Runs the exact `run:` scripts of rust-ci.yml (validate, detect, node-detect, summary) against the fixtures.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
wf="$root/.github/workflows/rust-ci.yml"
for step in detect node-detect summary; do
  python3 "$root/tests/lib/extract-step.py" "$wf" rust-ci "$step" > "$work/$step.sh" || exit 1
done
python3 "$root/tests/lib/extract-step.py" "$wf" validate validate > "$work/validate.sh" || exit 1

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

run_step summary "$fx/rust-ok" fixtures/rust-ok "GATE=cargo test" "GATE_OUTCOME=success" "HAS_DENY=true" "OS_LABEL=windows-latest"
check "summary: a multi-OS leg names its runner in the heading" eval 'has "$summary" "### rust-ci (windows-latest)"'

run_step summary "$fx/rust-ok" fixtures/rust-ok "GATE=cargo test" "GATE_OUTCOME=success" "HAS_DENY=true" "OS_LABEL="
check "summary: the default single-OS heading is unchanged" eval 'grep -qx "### rust-ci" <<< "$summary"'

# validate runs before any runner is chosen, from the repository root.
default_inputs=('OS_INPUT=["ubuntu-latest"]' "APT_PACKAGES=" "NODE_DIR=")

run_step validate "$root" . "${default_inputs[@]}"
check "validate: defaults pass and keep the single-OS label" eval '[ $code = 0 ] && grep -qx "os=\[\"ubuntu-latest\"\]" <<< "$outputs" && grep -qx "default-os=true" <<< "$outputs"'

run_step validate "$root" . 'OS_INPUT=["windows-latest","ubuntu-latest","windows-latest"]' "APT_PACKAGES=" "NODE_DIR="
check "validate: a multi-OS list is deduplicated and flagged" eval '[ $code = 0 ] && grep -qx "os=\[\"ubuntu-latest\",\"windows-latest\"\]" <<< "$outputs" && grep -qx "default-os=false" <<< "$outputs"'

for bad in '["self-hosted"]' '["ubuntu-latest","my-runner"]' '[]' '"ubuntu-latest"' 'ubuntu-latest' '[["ubuntu-latest"]]' '["ubuntu-latest"] ["self-hosted"]'; do
  run_step validate "$root" . "OS_INPUT=$bad" "APT_PACKAGES=" "NODE_DIR="
  check "validate: os rejects $bad" eval '[ $code = 1 ] && has "$out" "::error::Input '"'"'os'"'"'" && [ -z "$outputs" ]'
done

run_step validate "$root" . 'OS_INPUT=["ubuntu-latest"]' "APT_PACKAGES=libwebkit2gtk-4.1-dev libdbus-1-dev g++ libfoo:amd64" "NODE_DIR=apps/desktop"
check "validate: Debian package names and a relative node directory pass" eval '[ $code = 0 ]'

for bad in 'libfoo; rm -rf /' '-o APT::Get::foo' 'libfoo  libbar' ' libfoo' 'LibFoo' 'libfoo $(id)'; do
  run_step validate "$root" . 'OS_INPUT=["ubuntu-latest"]' "APT_PACKAGES=$bad" "NODE_DIR="
  check "validate: apt-packages rejects '$bad'" eval '[ $code = 1 ] && has "$out" "::error::Input '"'"'apt-packages'"'"'"'
done

for bad in '/abs' '../outside' 'a/../../b' $'apps\nos=x' 'a b'; do
  run_step validate "$root" . 'OS_INPUT=["ubuntu-latest"]' "APT_PACKAGES=" "NODE_DIR=$bad"
  check "validate: node-working-directory rejects '$bad'" eval '[ $code = 1 ] && has "$out" "::error::Input '"'"'node-working-directory'"'"'"'
done

# node-detect runs from the repository root, like setup-node's paths.
run_step node-detect "$root" . "NODE_DIR=fixtures/node-npm"
check "node-detect: lockfile found, no .nvmrc" eval '[ $code = 0 ] && grep -qx "lockfile=fixtures/node-npm/package-lock.json" <<< "$outputs" && grep -qx "nvmrc=" <<< "$outputs"'

mkdir -p "$work/repo/ui"
cp "$fx/node-npm/package.json" "$fx/node-npm/package-lock.json" "$work/repo/ui/"
echo 22 > "$work/repo/ui/.nvmrc"
run_step node-detect "$work/repo" . "NODE_DIR=ui"
check "node-detect: .nvmrc is honoured" eval '[ $code = 0 ] && grep -qx "nvmrc=ui/.nvmrc" <<< "$outputs"'

run_step node-detect "$root" . "NODE_DIR=fixtures/node-nolock"
check "node-detect: missing package-lock.json fails and names the folder" eval '[ $code = 1 ] && has "$out" "No package-lock.json in '"'"'fixtures/node-nolock'"'"'"'

run_step node-detect "$root" . "NODE_DIR=fixtures/does-not-exist"
check "node-detect: missing folder fails and names it" eval '[ $code = 1 ] && has "$out" "No package-lock.json in '"'"'fixtures/does-not-exist'"'"'"'

echo "rust-ci: $((total - failures))/$total passed"
[ "$failures" -eq 0 ]
