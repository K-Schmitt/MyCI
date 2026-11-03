#!/usr/bin/env bash
# Checks tests/run.sh itself: it refuses an empty suite set and counts the suites it runs.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/check.sh
. "$root/tests/lib/check.sh"

mkdir "$work/empty"
cp "$root/tests/run.sh" "$work/empty/run.sh"
out=$(bash "$work/empty/run.sh" 2>&1)
code=$?
check "no suite found exits 1 and says so" eval '[ $code = 1 ] && has "$out" "no suite found"'

mkdir "$work/one"
cp "$root/tests/run.sh" "$work/one/run.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$work/one/fake.test.sh"
out=$(bash "$work/one/run.sh" 2>&1)
code=$?
check "one green suite is counted and passes" eval '[ $code = 0 ] && has "$out" "== 1 suite"'

printf '#!/usr/bin/env bash\nexit 1\n' > "$work/one/red.test.sh"
out=$(bash "$work/one/run.sh" 2>&1)
code=$?
check "a red suite fails the run" eval '[ $code = 1 ] && has "$out" "== 2 suite"'

report runner
