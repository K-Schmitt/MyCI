#!/usr/bin/env bash
# A clean script: lint-infra's shellcheck must pass on it.
set -euo pipefail
name=${1:-world}
echo "hello, ${name}"
