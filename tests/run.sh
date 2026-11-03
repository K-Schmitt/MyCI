#!/usr/bin/env bash
# Runs every script test. Exit status is non-zero if any suite fails or if no suite is found.
set -uo pipefail
shopt -s nullglob
dir=$(cd "$(dirname "$0")" && pwd)
suites=("$dir"/*.test.sh)
if [ ${#suites[@]} -eq 0 ]; then
  echo "no suite found in $dir (expected tests/*.test.sh)" >&2
  exit 1
fi
echo "== ${#suites[@]} suite(s)"
status=0
for suite in "${suites[@]}"; do
  echo "== $(basename "$suite")"
  bash "$suite" || status=1
done
exit "$status"
