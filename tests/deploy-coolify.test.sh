#!/usr/bin/env bash
# Runs the exact `validate` and `deploy` scripts of deploy-coolify.yml against a fake Coolify/GitHub
# API, one scenario per row of the spec's deploy algorithm (§6.3) plus the healthcheck rows.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
mock_pid=""
trap 'kill "$mock_pid" 2>/dev/null; rm -rf "$work"' EXIT
# shellcheck source=lib/check.sh
. "$root/tests/lib/check.sh"

wf="$root/.github/workflows/deploy-coolify.yml"
python3 "$root/tests/lib/extract-step.py" "$wf" deploy validate > "$work/validate.sh" || exit 1
python3 "$root/tests/lib/extract-step.py" "$wf" deploy deploy > "$work/deploy.sh" || exit 1

sha=$(printf 'a%.0s' {1..40})
port=18765

# --- validate ------------------------------------------------------------------------------
v() { # <healthcheck-url> <healthcheck-timeout>: sets $out and $code
  out=$(env -i PATH="$PATH" HEALTHCHECK_URL="$1" HEALTHCHECK_TIMEOUT="$2" bash "$work/validate.sh" 2>&1)
  code=$?
}
for url in "" "https://app.example.com/health" "http://127.0.0.1:8080/api/health?deep=1"; do
  v "$url" 120
  check "validate: accepts '$url'" eval '[ $code = 0 ]'
done
for url in "ftp://x" "app.example.com/health" "https://x y"; do
  v "$url" 120
  check "validate: rejects '$url'" eval '[ $code = 1 ] && has "$out" "Input '"'"'healthcheck-url'"'"'"'
done
for t in 1 120 900; do
  v "" "$t"
  check "validate: accepts timeout '$t'" eval '[ $code = 0 ]'
done
for t in 0 1.5 -5 abc 1000; do
  v "" "$t"
  check "validate: rejects timeout '$t'" eval '[ $code = 1 ] && has "$out" "Input '"'"'healthcheck-timeout'"'"'"'
done

# --- deploy --------------------------------------------------------------------------------
# scenario | wait | healthcheck-url path (or -) | expect | expected exit | expected output | expected request (or !request = must not happen)
cases=(
  "ok|true|-||0|Deployed aaaaaaa|GET /api/v1/deployments/dep-123"
  "stale|true|-||0|skipping, the newer run deploys|!POST /api/v1/deploy"
  "head-unreadable|true|-||1|Could not read the current head of main|!POST /api/v1/deploy"
  "deploy-401|true|-||1|rejected the token (401)|POST /api/v1/deploy"
  "deploy-403|true|-||1|lacks the deploy permission (403)|POST /api/v1/deploy"
  "deploy-404|true|-||1|not found (404)|POST /api/v1/deploy"
  "deploy-500|true|-||1|deploy request failed (HTTP 500)|POST /api/v1/deploy"
  "no-uuid|true|-||1|No deployment_uuid|POST /api/v1/deploy"
  "nowait|false|-||0|wait=false|!GET /api/v1/deployments/dep-123"
  "failed|true|-||1|ended with status 'failed' (deployment dep-123, |GET /api/v1/deployments/dep-123"
  "cancelled|true|-||1|ended with status 'cancelled-by-user'|GET /api/v1/deployments/dep-123"
  "commit-mismatch|true|-||1|instead of the tested commit|GET /api/v1/deployments/dep-123"
  "poll-403|true|-||1|lacks the read permission (403): Missing required permissions: read|GET /api/v1/deployments/dep-123"
  "poll-500|true|-||1|failed (HTTP 500)|GET /api/v1/deployments/dep-123"
  "poll-garbage|true|-||1|Unreadable deployment status: <html>not json</html>|GET /api/v1/deployments/dep-123"
  "timeout|true|-||1|Timed out after 2s|GET /api/v1/deployments/dep-123"
  "already-queued|true|-||1|already has a deployment queued or in progress|!GET /api/v1/deployments/orphan-456"
  "queue-full|true|-||1|deployment queue is full (429)|POST /api/v1/deploy"
  "poll-hang|true|-||1|Timed out after 2s|GET /api/v1/deployments/dep-123"
  "queued|true|-||0|Deployed aaaaaaa|GET /api/v1/deployments/dep-123"
  "health-ok|true|/health|${sha}|0|Healthcheck passed|GET /health"
  "health-ok|true|/health||0|Healthcheck passed|GET /health"
  "health-late|true|/health||0|Healthcheck passed|GET /health"
  "health-503|true|/health||1|Healthcheck http://127.0.0.1:${port}/health did not pass within 2s (last: HTTP 503)|GET /health"
  "health-body|true|/health|${sha}|1|body without '${sha}'|GET /health"
  "health-ok|false|/health||0|wait=false|!GET /health"
)

for row in "${cases[@]}"; do
  IFS='|' read -r scenario wait health expect want_exit want_out want_req <<< "$row"
  : > "$work/requests.log"
  python3 "$root/tests/lib/mock-coolify.py" "$port" "$scenario" "$sha" "$work/requests.log" test-token &
  mock_pid=$!
  for _ in $(seq 200); do curl -s -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.02; done
  health_url=""
  [ "$health" = - ] || health_url="http://127.0.0.1:${port}${health}"

  out=$(env -i PATH="$PATH" HOME="$HOME" \
    COOLIFY_URL="http://127.0.0.1:$port/" APP_UUID=app-uuid WAIT="$wait" \
    HEALTHCHECK_URL="$health_url" HEALTHCHECK_EXPECT="$expect" HEALTHCHECK_TIMEOUT=2 HEALTH_INTERVAL=0.2 \
    COOLIFY_TOKEN=test-token GITHUB_TOKEN=gh-token \
    GITHUB_API_URL="http://127.0.0.1:$port" GITHUB_REPOSITORY=owner/repo \
    GITHUB_REF_NAME=main GITHUB_SHA="$sha" GITHUB_STEP_SUMMARY="$work/summary.md" \
    POLL_INTERVAL=0.2 POLL_TIMEOUT=2 CURL_MAX_TIME=1 \
    timeout 15 bash "$work/deploy.sh" 2>&1)
  code=$?
  kill "$mock_pid" 2>/dev/null; wait "$mock_pid" 2>/dev/null

  problems=()
  [ "$code" = "$want_exit" ] || problems+=("exit $code, want $want_exit")
  has "$out" "$want_out" || problems+=("output lacks '$want_out'")
  if [[ "$want_req" == !* ]]; then
    ! grep -q "^${want_req#!}" "$work/requests.log" || problems+=("unexpected request '${want_req#!}'")
  else
    grep -q "^${want_req}" "$work/requests.log" || problems+=("missing request '$want_req'")
  fi
  if has "$out" test-token; then problems+=("token leaked to output"); fi
  out="${problems[*]:-}"$'\n'"$out"
  check "$scenario${health_url:+ + healthcheck}${expect:+ + expect}${wait/true/}" eval '[ ${#problems[@]} -eq 0 ]'
done

report deploy-coolify
