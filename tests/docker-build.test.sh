#!/usr/bin/env bash
# Runs the exact `resolve` step of docker-build.yml against the fixtures.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 "$root/tests/lib/extract-step.py" \
  "$root/.github/workflows/docker-build.yml" docker-build resolve > "$work/resolve.sh" || exit 1

failures=0
total=0
# context | dockerfile | expected exit | expected text (output file or stdout)
cases=(
  "fixtures/node-npm|Dockerfile|0|file=fixtures/node-npm/Dockerfile"
  "fixtures/node-npm/|Dockerfile|0|file=fixtures/node-npm/Dockerfile"
  "fixtures/node-pnpm|Dockerfile|1|Dockerfile not found: fixtures/node-pnpm/Dockerfile"
  "fixtures/node-npm|Containerfile|1|Dockerfile not found: fixtures/node-npm/Containerfile"
)
for row in "${cases[@]}"; do
  IFS='|' read -r context dockerfile want_exit want_text <<< "$row"
  total=$((total + 1))
  : > "$work/output"
  out=$(cd "$root" && env -i PATH="$PATH" CONTEXT="$context" DOCKERFILE="$dockerfile" \
    GITHUB_OUTPUT="$work/output" bash "$work/resolve.sh" 2>&1)
  code=$?
  if [ "$code" = "$want_exit" ] && grep -qF -- "$want_text" <<< "$out$(cat "$work/output")"; then
    echo "PASS $context + $dockerfile"
  else
    echo "FAIL $context + $dockerfile: exit $code (want $want_exit), output: $out $(cat "$work/output")"
    failures=$((failures + 1))
  fi
done
echo "docker-build: $((total - failures))/$total passed"
[ "$failures" -eq 0 ]
