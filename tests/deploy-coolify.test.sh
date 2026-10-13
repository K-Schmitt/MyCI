#!/usr/bin/env bash
# Runs the exact `run:` script of deploy-coolify.yml against a fake Coolify/GitHub API,
# one scenario per row of the spec's deploy algorithm (§6.3).
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
mock_pid=""
trap 'kill "$mock_pid" 2>/dev/null; rm -rf "$work"' EXIT

python3 "$root/tests/lib/extract-step.py" \
  "$root/.github/workflows/deploy-coolify.yml" deploy deploy > "$work/deploy.sh" || exit 1

sha=$(printf 'a%.0s' {1..40})
port=18765
failures=0

# scenario | wait | expected exit | expected output substring | expected request (or !request = must not happen)
cases=(
  "ok|true|0|Deployed aaaaaaa|GET /api/v1/deployments/dep-123"
  "stale|true|0|skipping, the newer run deploys|!POST /api/v1/deploy"
  "head-unreadable|true|1|Could not read the current head of main|!POST /api/v1/deploy"
  "deploy-401|true|1|rejected the token (401)|POST /api/v1/deploy"
  "deploy-403|true|1|lacks the deploy permission (403)|POST /api/v1/deploy"
  "deploy-404|true|1|not found (404)|POST /api/v1/deploy"
  "deploy-500|true|1|deploy request failed (HTTP 500)|POST /api/v1/deploy"
  "no-uuid|true|1|No deployment_uuid|POST /api/v1/deploy"
  "nowait|false|0|wait=false|!GET /api/v1/deployments/dep-123"
  "failed|true|1|ended with status 'failed'|GET /api/v1/deployments/dep-123"
  "cancelled|true|1|ended with status 'cancelled-by-user'|GET /api/v1/deployments/dep-123"
  "commit-mismatch|true|1|instead of the tested commit|GET /api/v1/deployments/dep-123"
  "poll-500|true|1|failed (HTTP 500)|GET /api/v1/deployments/dep-123"
  "poll-garbage|true|1|Unreadable deployment status|GET /api/v1/deployments/dep-123"
  "timeout|true|1|Timed out after 2s|GET /api/v1/deployments/dep-123"
  "already-queued|true|1|already has a deployment queued or in progress|!GET /api/v1/deployments/orphan-456"
  "queue-full|true|1|deployment queue is full (429)|POST /api/v1/deploy"
  "poll-hang|true|1|Timed out after 2s|GET /api/v1/deployments/dep-123"
)

for row in "${cases[@]}"; do
  IFS='|' read -r scenario wait want_exit want_out want_req <<< "$row"
  : > "$work/requests.log"
  python3 "$root/tests/lib/mock-coolify.py" "$port" "$scenario" "$sha" "$work/requests.log" &
  mock_pid=$!
  for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.1; done

  out=$(env -i PATH="$PATH" HOME="$HOME" \
    COOLIFY_URL="http://127.0.0.1:$port/" APP_UUID=app-uuid WAIT="$wait" \
    COOLIFY_TOKEN=test-token GITHUB_TOKEN=gh-token \
    GITHUB_API_URL="http://127.0.0.1:$port" GITHUB_REPOSITORY=owner/repo \
    GITHUB_REF_NAME=main GITHUB_SHA="$sha" GITHUB_STEP_SUMMARY="$work/summary.md" \
    POLL_INTERVAL=0.2 POLL_TIMEOUT=2 CURL_MAX_TIME=1 \
    timeout 15 bash "$work/deploy.sh" 2>&1)
  got_exit=$?
  kill "$mock_pid" 2>/dev/null; wait "$mock_pid" 2>/dev/null

  problems=()
  [ "$got_exit" = "$want_exit" ] || problems+=("exit $got_exit, want $want_exit")
  grep -qF -- "$want_out" <<< "$out" || problems+=("output lacks '$want_out'")
  if [[ "$want_req" == !* ]]; then
    ! grep -q "^${want_req#!}" "$work/requests.log" || problems+=("unexpected request '${want_req#!}'")
  else
    grep -q "^${want_req}" "$work/requests.log" || problems+=("missing request '$want_req'")
  fi
  if grep -qF test-token <<< "$out"; then problems+=("token leaked to output"); fi

  if [ ${#problems[@]} -eq 0 ]; then
    echo "PASS $scenario"
  else
    echo "FAIL $scenario: ${problems[*]}"
    printf '%s\n' "$out" | sed 's/^/    | /'
    failures=$((failures + 1))
  fi
done

echo "deploy-coolify: $(( ${#cases[@]} - failures ))/${#cases[@]} passed"
[ "$failures" -eq 0 ]
