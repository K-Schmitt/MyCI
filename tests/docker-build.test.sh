#!/usr/bin/env bash
# Runs the exact `validate`, `resolve` and `tags` steps of docker-build.yml against the fixtures.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/check.sh
. "$root/tests/lib/check.sh"
wf="$root/.github/workflows/docker-build.yml"
for step in validate resolve tags; do
  python3 "$root/tests/lib/extract-step.py" "$wf" docker-build "$step" > "$work/$step.sh" || exit 1
done

# run_step <step> [VAR=value...]: runs from the repository root; sets $out, $code, $outputs
run_step() {
  local step=$1
  shift
  : > "$work/output"
  out=$(cd "$root" && env -i PATH="$PATH" GITHUB_OUTPUT="$work/output" "$@" bash "$work/$step.sh" 2>&1)
  code=$?
  outputs=$(cat "$work/output")
}

# --- resolve -------------------------------------------------------------------------------
run_step resolve CONTEXT=fixtures/node-npm DOCKERFILE=Dockerfile
check "resolve: context + Dockerfile" eval '[ $code = 0 ] && has "$outputs" "file=fixtures/node-npm/Dockerfile"'
run_step resolve CONTEXT=fixtures/node-npm/ DOCKERFILE=Dockerfile
check "resolve: trailing slash on context" eval '[ $code = 0 ] && has "$outputs" "file=fixtures/node-npm/Dockerfile"'
run_step resolve CONTEXT=fixtures/node-pnpm DOCKERFILE=Dockerfile
check "resolve: missing Dockerfile fails and names it" eval '[ $code = 1 ] && has "$out" "Dockerfile not found: fixtures/node-pnpm/Dockerfile"'
run_step resolve CONTEXT=fixtures/node-npm DOCKERFILE=Containerfile
check "resolve: other file name is honoured" eval '[ $code = 1 ] && has "$out" "Dockerfile not found: fixtures/node-npm/Containerfile"'

# --- validate ------------------------------------------------------------------------------
v() { # validate with defaults overridden by the arguments
  run_step validate CONTEXT=. DOCKERFILE=Dockerfile TARGET= BUILD_ARGS= IMAGE= PUSH=false \
    GITHUB_REPOSITORY=K-Schmitt/MyWeb "$@"
}
v
check "validate: defaults pass with a scope and no image" eval '[ $code = 0 ] && grep -qx "scope=.-Dockerfile-" <<< "$outputs" && grep -qx "image=" <<< "$outputs"'
v CONTEXT=../outside
check "validate: context rejects '../outside'" eval '[ $code = 1 ] && has "$out" "Input '"'"'context'"'"'"'
v CONTEXT=/abs
check "validate: context rejects '/abs'" eval '[ $code = 1 ] && has "$out" "Input '"'"'context'"'"'"'
v DOCKERFILE=../Dockerfile
check "validate: dockerfile rejects '../Dockerfile'" eval '[ $code = 1 ] && has "$out" "Input '"'"'dockerfile'"'"'"'
v CONTEXT=apps/web/ DOCKERFILE=docker/Dockerfile.prod TARGET=production
check "validate: scope is built from context, dockerfile and target" eval '[ $code = 0 ] && grep -qx "scope=apps-web-docker-Dockerfile.prod-production" <<< "$outputs"'
v TARGET='prod;rm -rf /'
check "validate: target rejects 'prod;rm -rf /'" eval '[ $code = 1 ] && has "$out" "Input '"'"'target'"'"'"'
v BUILD_ARGS=$'A=1\nB=x=y\n\nVITE_URL=http://x?a=b&c=d'
check "validate: build-args value with '=' and a URL accepted" eval '[ $code = 0 ]'
v BUILD_ARGS=$'A=1\n1BAD=x'
check "validate: build-args rejects a key starting with a digit" eval '[ $code = 1 ] && has "$out" "Input '"'"'build-args'"'"'" && has "$out" "1BAD=x"'
v BUILD_ARGS='NOEQUALS'
check "validate: build-args rejects a line without '='" eval '[ $code = 1 ] && has "$out" "Input '"'"'build-args'"'"'"'
v PUSH=true
check "validate: push derives the image from the repository, lower-cased" eval '[ $code = 0 ] && grep -qx "image=ghcr.io/k-schmitt/myweb" <<< "$outputs"'
v PUSH=true IMAGE=ghcr.io/k-schmitt/myci/fixture
check "validate: push accepts a nested ghcr.io image" eval '[ $code = 0 ] && grep -qx "image=ghcr.io/k-schmitt/myci/fixture" <<< "$outputs"'
v PUSH=true IMAGE=ghcr.io/k-schmitt/my__lib
check "validate: push accepts a double underscore (valid on GitHub and GHCR)" eval '[ $code = 0 ] && grep -qx "image=ghcr.io/k-schmitt/my__lib" <<< "$outputs"'
v PUSH=true IMAGE=ghcr.io/k-schmitt/my--app
check "validate: push accepts consecutive dashes" eval '[ $code = 0 ] && grep -qx "image=ghcr.io/k-schmitt/my--app" <<< "$outputs"'
v PUSH=true IMAGE=ghcr.io/k-schmitt/my..lib
check "validate: push rejects consecutive dots" eval '[ $code = 1 ] && has "$out" "Input '"'"'image'"'"'"'
v PUSH=true IMAGE=docker.io/x/y
check "validate: push rejects a registry other than ghcr.io" eval '[ $code = 1 ] && has "$out" "ghcr.io"'
v PUSH=true IMAGE=ghcr.io/K-Schmitt/MyWeb
check "validate: push rejects an upper-case image" eval '[ $code = 1 ] && has "$out" "Input '"'"'image'"'"'"'
v PUSH=false IMAGE=docker.io/x/y
check "validate: image is ignored without push" eval '[ $code = 0 ] && grep -qx "image=" <<< "$outputs"'

# --- tags ----------------------------------------------------------------------------------
sha=$(printf 'a%.0s' {1..40})
t() { # tags with IMAGE and DEFAULT_BRANCH fixed
  run_step tags IMAGE=ghcr.io/o/r GITHUB_SHA="$sha" DEFAULT_BRANCH=main "$@"
}
t GITHUB_REF=refs/heads/main GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main
check "tags: default branch gets sha and latest" eval '[ $code = 0 ] && has "$outputs" "ghcr.io/o/r:sha-aaaaaaa" && has "$outputs" "ghcr.io/o/r:latest"'
t GITHUB_REF=refs/heads/dev GITHUB_REF_TYPE=branch GITHUB_REF_NAME=dev
check "tags: another branch gets only sha" eval '[ $code = 0 ] && has "$outputs" "ghcr.io/o/r:sha-aaaaaaa" && ! has "$outputs" ":latest" && ! has "$outputs" ":dev"'
t GITHUB_REF=refs/tags/v1.2.3 GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.2.3
check "tags: a tag gets sha and the tag name" eval '[ $code = 0 ] && has "$outputs" "ghcr.io/o/r:sha-aaaaaaa" && has "$outputs" "ghcr.io/o/r:v1.2.3" && ! has "$outputs" ":latest"'
t GITHUB_REF=refs/tags/release/2026.1 GITHUB_REF_TYPE=tag GITHUB_REF_NAME=release/2026.1
check "tags: a tag name is made a valid docker tag" eval '[ $code = 0 ] && has "$outputs" "ghcr.io/o/r:release-2026.1"'

report docker-build
