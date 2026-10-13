#!/usr/bin/env bash
# Runs every script test. Exit status is non-zero if any suite fails.
set -uo pipefail
shopt -s nullglob
dir=$(cd "$(dirname "$0")" && pwd)
status=0
for suite in "$dir"/*.test.sh; do
  echo "== $(basename "$suite")"
  bash "$suite" || status=1
done
exit "$status"
