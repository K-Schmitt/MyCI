#!/usr/bin/env bash
# Runs the exact `validate`, `discover` and tool scripts of lint-infra.yml against the fixtures.
# The four Docker-based tools run for real (Docker is already required by the actionlint gate);
# ansible-lint is an action, checked by self-test.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/check.sh
. "$root/tests/lib/check.sh"
wf="$root/.github/workflows/lint-infra.yml"
for step in validate discover shellcheck hadolint compose actionlint summary; do
  python3 "$root/tests/lib/extract-step.py" "$wf" lint-infra "$step" > "$work/$step.sh" || exit 1
done

# run_step <step> <dir> [VAR=value...]: sets $out, $code, $outputs, $summary
run_step() {
  local step=$1 dir=$2
  shift 2
  : > "$work/output"
  : > "$work/summary"
  out=$(cd "$dir" && env -i PATH="$PATH" HOME="$HOME" \
    GITHUB_OUTPUT="$work/output" GITHUB_STEP_SUMMARY="$work/summary" "$@" \
    bash "$work/$step.sh" 2>&1)
  code=$?
  outputs=$(cat "$work/output")
  summary=$(cat "$work/summary")
}
# list_output <name>: the lines of a multi-line output written as `name<<MYCI_LIST ... MYCI_LIST`
list_output() {
  awk -v name="$1" '$0 == name "<<MYCI_LIST" {on=1; next} on && $0 == "MYCI_LIST" {exit} on {print}' "$work/output"
}

fx="$root/fixtures"

# --- validate ------------------------------------------------------------------------------
v() { run_step validate "$fx/infra-ok" WORKDIR=. SEVERITY=style EXCLUDE= "$@"; }
v
check "validate: defaults pass" eval '[ $code = 0 ]'
v SEVERITY=warning
check "validate: severity warning passes" eval '[ $code = 0 ]'
v SEVERITY=all
check "validate: severity rejects 'all'" eval '[ $code = 1 ] && has "$out" "Input '"'"'shellcheck-severity'"'"'"'
v EXCLUDE="legacy third_party .cache configure"
check "validate: exclude accepts directory and file names, dotted ones included" eval '[ $code = 0 ]'
v EXCLUDE="a;b"
check "validate: exclude rejects 'a;b'" eval '[ $code = 1 ] && has "$out" "Input '"'"'exclude'"'"'"'
v EXCLUDE="../x"
check "validate: exclude rejects '../x'" eval '[ $code = 1 ] && has "$out" "Input '"'"'exclude'"'"'"'
v WORKDIR=../outside
check "validate: working-directory rejects '../outside'" eval '[ $code = 1 ] && has "$out" "Input '"'"'working-directory'"'"'"'

# --- discover ------------------------------------------------------------------------------
run_step discover "$fx/infra-ok" EXCLUDE=
check "discover: scripts by extension and by shebang, wrappers and node_modules skipped" eval '[ $code = 0 ] && [ "$(list_output shell)" = $'"'"'bin/run\nok.sh'"'"' ]'
check "discover: Dockerfile, compose, workflow and ansible found, with counts" eval '[ "$(list_output dockerfiles)" = Dockerfile ] && [ "$(list_output compose)" = compose.yml ] && [ "$(list_output workflows)" = .github/workflows/ok.yml ] && grep -qx "ansible=ansible" <<< "$outputs" && grep -qx "shell-count=2" <<< "$outputs" && grep -qx "compose-count=1" <<< "$outputs"'

run_step discover "$fx/infra-ok" EXCLUDE="ansible bin"
check "discover: exclude prunes directories wherever they are" eval '[ $code = 0 ] && grep -qx "ansible=" <<< "$outputs" && [ "$(list_output shell)" = ok.sh ]'

run_step discover "$fx/infra-ok" EXCLUDE="ok.sh"
check "discover: exclude also skips a file by name" eval '[ $code = 0 ] && [ "$(list_output shell)" = bin/run ]'

run_step discover "$fx/infra-bad-shell" EXCLUDE=
check "discover: a folder with one script lists nothing else" eval '[ $code = 0 ] && [ "$(list_output shell)" = bad.sh ] && [ -z "$(list_output dockerfiles)" ] && [ -z "$(list_output compose)" ] && [ -z "$(list_output workflows)" ] && grep -qx "ansible=" <<< "$outputs"'

cp -r "$fx/infra-ok" "$work/editor-copy"
mkdir -p "$work/editor-copy/.history" && printf '#!/bin/bash\necho $UNQUOTED\n' > "$work/editor-copy/.history/stale.sh"
run_step discover "$work/editor-copy" EXCLUDE=
check "discover: an editor's .history copies are never linted" eval '[ $code = 0 ] && [ "$(list_output shell)" = $'"'"'bin/run\nok.sh'"'"' ]'

mkdir -p "$work/root-ansible" && touch "$work/root-ansible/ansible.cfg"
run_step discover "$work/root-ansible" EXCLUDE=
check "discover: ansible.cfg at the root points ansible-lint at '.'" eval '[ $code = 0 ] && grep -qx "ansible=." <<< "$outputs"'

mkdir -p "$work/nested-ansible/deploy/infra" && touch "$work/nested-ansible/deploy/infra/ansible.cfg"
run_step discover "$work/nested-ansible" EXCLUDE=
check "discover: ansible.cfg anywhere points ansible-lint at its folder" eval '[ $code = 0 ] && grep -qx "ansible=deploy/infra" <<< "$outputs"'

# --- tools (Docker) ------------------------------------------------------------------------
run_step shellcheck "$fx/infra-ok" SEVERITY=style FILES=$'bin/run\nok.sh'
check "shellcheck: clean scripts pass" eval '[ $code = 0 ]'
run_step shellcheck "$fx/infra-bad-shell" SEVERITY=style FILES=bad.sh
check "shellcheck: a bad script fails with its code" eval '[ $code != 0 ] && has "$out" "SC2046"'
run_step shellcheck "$fx/infra-bad-shell" SEVERITY=error FILES=bad.sh
check "shellcheck: severity error lets warnings through" eval '[ $code = 0 ]'

run_step hadolint "$fx/infra-ok" FILES=Dockerfile
check "hadolint: a clean Dockerfile passes" eval '[ $code = 0 ]'
run_step hadolint "$fx/infra-bad-dockerfile" FILES=Dockerfile
check "hadolint: ubuntu:latest fails with DL3007" eval '[ $code != 0 ] && has "$out" "DL3007"'

run_step compose "$fx/infra-ok" FILES=compose.yml
check "compose: a valid file with an uncommitted env_file passes" eval '[ $code = 0 ]'
mkdir -p "$work/required-var" && printf 'services:\n  web:\n    image: nginx:1.27\n    ports:\n      - "${PORT:?}:80"\n' > "$work/required-var/compose.yml"
run_step compose "$work/required-var" FILES=compose.yml
check "compose: a required variable without a value still passes (structure only)" eval '[ $code = 0 ]'
run_step compose "$fx/infra-bad-compose" FILES=compose.yml
check "compose: an unknown key fails and names the file" eval '[ $code != 0 ] && has "$out" "additional properties" && has "$out" "::error file=compose.yml"'

run_step actionlint "$fx/infra-ok" FILES=.github/workflows/ok.yml
check "actionlint: a valid workflow passes" eval '[ $code = 0 ]'
run_step actionlint "$fx/infra-bad-workflow" FILES=.github/workflows/bad.yml
check "actionlint: an invalid workflow fails and names the key" eval '[ $code != 0 ] && has "$out" "bogus"'

# --- summary -------------------------------------------------------------------------------
run_step summary "$fx/infra-ok" SHELL_COUNT=2 DOCKERFILE_COUNT=1 COMPOSE_COUNT=1 WORKFLOW_COUNT=1 ANSIBLE=ansible \
  SHELLCHECK=success HADOLINT=failure COMPOSE=success ACTIONLINT=skipped ANSIBLE_LINT=success
check "summary: one row per tool with its file count and result" eval '[ $code = 0 ] && has "$summary" "| shellcheck | 2 | ✅ passed |" && has "$summary" "| hadolint | 1 | ❌ failed |" && has "$summary" "| actionlint | 1 | ⏭️ not run |" && has "$summary" "| ansible-lint | ansible | ✅ passed |"'

report lint-infra
