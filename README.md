# MyCI

[![self-test](https://github.com/K-Schmitt/MyCI/actions/workflows/self-test.yml/badge.svg)](https://github.com/K-Schmitt/MyCI/actions/workflows/self-test.yml)

Reusable GitHub Actions workflows that gate production deployments behind CI.
Written once here, called from every project with a ~25-line file.

**The problem it solves:** Coolify redeployed every push, including broken ones.
With MyCI, a deployment only happens after lint, typecheck, tests, build and a Docker build pass,
and the job turns red if Coolify deploys anything other than the commit that was tested.

```
push to main ──► node-ci ──┐
                           ├──► deploy-coolify ──► Coolify builds ──► verify deployed commit == tested commit
             docker-build ─┘          │
                                      └─ skipped if main moved on (the newer run deploys)
```

## Workflows

| Workflow | What it guarantees |
|---|---|
| `node-ci.yml` | Lockfile-strict install (npm or pnpm, auto-detected), optional production audit, then the `scripts` in order (default `lint`, `typecheck`, `test`, `build`) when present, with the `env` you pass. Scripts listed in `require` (default `lint,build`) must exist. A job summary lists what ran, failed or was absent. |
| `rust-ci.yml` | The pinned toolchain (`rust-toolchain.toml`) and `Cargo.lock` are present, then the project's own quality gate runs (default `cargo xtask check`) with a Cargo cache and `cargo-deny` installed when a `deny.toml` exists. |
| `python-ci.yml` | Installs the requirements files on the requested Python and runs the project's own gate (pytest by default). |
| `android-ci.yml` | The Gradle wrapper is committed and genuine (checksum validated), then the project's own gate runs (default `./gradlew assembleDebug check`: unit tests, lint, whatever `check` wires) on Temurin JDK 21 with a Gradle cache; debug APKs are uploaded on success, lint and test reports on failure. |
| `lint-infra.yml` | Lints what the repository holds without any configuration: shellcheck on scripts, hadolint on Dockerfiles, `docker compose config` on compose files, actionlint on the workflows, ansible-lint on playbooks. A tool runs only when it has files. |
| `docker-build.yml` | The project's Dockerfile builds, with optional stage, build arguments and a smoke command run against the built image; pushes to GHCR only when asked. It does not reproduce Coolify's build args. |
| `deploy-coolify.yml` | Triggers a Coolify deployment, follows it to the end, and fails unless Coolify reports `finished` **and** the deployed commit equals the tested commit **and**, when a `healthcheck-url` is given, the application answers 200. Runs in a GitHub environment (`production` by default). |

### node-ci inputs

| Input | Default | Notes |
|---|---|---|
| `node-version` | `24` | Ignored when `.nvmrc` exists. node-ci follows current Node; rust-ci's embedded Node (`22`) follows LTS, on purpose |
| `require` | `lint,build` | Comma-separated; empty string disables the check |
| `scripts` | `lint,typecheck,test,build` | Comma-separated, run in this order; a script that does not exist is reported `absent`, not failed (name yours: `type-check,test:coverage,build`); the first failure stops the list |
| `env` | `""` | One `KEY=VALUE` per line, exported for the scripts step only (`VITE_*`, `NEXT_PUBLIC_*`, `NODE_OPTIONS=--max-old-space-size=4096`): the install and the audit run without them. Public values only: a reusable workflow cannot read the caller's `env:`, and secrets never belong here |
| `audit` | `none` | `low`, `moderate`, `high` or `critical` runs `npm audit --omit=dev` / `pnpm audit --prod` at that level right after the install |
| `pnpm-version` | `""` | Only for pnpm projects without a `packageManager` field |
| `working-directory` | `.` | Folder holding `package.json`; a relative path inside the repository |

### rust-ci inputs

| Input | Default | Notes |
|---|---|---|
| `gate` | `cargo xtask check` | The project's quality gate; any command that exits non-zero on failure. Projects without an `xtask` pass their own, e.g. `cargo clippy --locked -- -D warnings && cargo test --locked` |
| `working-directory` | `.` | Folder holding `Cargo.lock` and `rust-toolchain.toml` |
| `deny-version` | `0.20.2` | Only used when a `deny.toml` exists |
| `os` | `["ubuntu-latest"]` | JSON array of runners, one job per entry (`fail-fast: false`). Only `ubuntu-latest`, `windows-latest` and `macos-latest` are accepted; anything else fails the `validate` job before a runner is picked |
| `apt-packages` | `""` | Space-separated Debian packages, installed on Linux runners only (`apt-get install --no-install-recommends`), e.g. a Tauri app's `libwebkit2gtk-4.1-dev` |
| `node-working-directory` | `""` | Folder (from the repository root) with a `package-lock.json`: Node is set up with an npm cache and `npm ci` runs there before the gate, for gates that also check a web UI |
| `node-version` | `22` | Only with `node-working-directory`; ignored when that folder has an `.nvmrc` |
| `timeout-minutes` | `30` | Per job; a cold Windows build of a large workspace may need more |

The gate is the project's, not MyCI's: when it changes, CI follows without touching MyCI. With the
defaults the run is the historical one: a single Ubuntu job named `rust-ci`. With several runners each
job is named `rust-ci (<runner>)`, has its own concurrency group and its own summary. Every `run:` step
uses `bash` (Git Bash on Windows), so the gate is a bash command on every OS. Windows and macOS runners
consume included minutes faster on private repositories (check GitHub's current multipliers): restrict them in the caller,
see [`examples/caller-rust.yml`](examples/caller-rust.yml).

### python-ci inputs

| Input | Default | Notes |
|---|---|---|
| `gate` | `python -m pytest -q` | The project's quality gate; any command that exits non-zero on failure (add `ruff check && mypy .` here if you use them) |
| `python-version` | `3.12` | Ignored when `.python-version` exists |
| `requirements` | `requirements.txt,requirements-dev.txt` | Comma-separated, relative to `working-directory`; every listed file must exist; empty installs nothing |
| `working-directory` | `.` | Folder holding the requirements files and the tests |

A requirement not pinned with `==` produces a warning, not a failure. As with rust-ci the gate is the project's.

### android-ci inputs

| Input | Default | Notes |
|---|---|---|
| `gate` | `./gradlew assembleDebug check` | The project's quality gate; any command that exits non-zero on failure (`check` runs unit tests, lint, detekt, Kover… whatever the build wires into it) |
| `working-directory` | `.` | Folder holding `settings.gradle(.kts)`, `gradlew` and `gradle/wrapper/` |
| `java-version` | `21` | Temurin JDK |
| `timeout-minutes` | `30` | A cold build downloads the Android Gradle Plugin and the SDK parts it needs; a large Robolectric suite needs the default |

The Gradle wrapper must be committed (`gradlew`, `gradlew.bat`, `gradle/wrapper/`): the job validates its
checksum against Gradle's published ones and builds with the Gradle version the project pins. The SDK is
the runner's (`ANDROID_HOME` preset on `ubuntu-latest`); the plugin downloads the platform it needs.
Debug APKs (`**/build/outputs/apk/**/*.apk`) are uploaded as an artifact on success, `**/build/reports/**`
on failure, both kept 7 days. Instrumented tests (`connectedAndroidTest`) need an emulator and are out of scope.
Lints that query the network (`GradleDependency`, `NewerVersionAvailable`) are best disabled in the project.

### lint-infra inputs

| Input | Default | Notes |
|---|---|---|
| `working-directory` | `.` | Folder scanned, relative to the repository root |
| `shellcheck-severity` | `style` | Minimum severity that fails: `error`, `warning`, `info` or `style` |
| `exclude` | `""` | Space-separated file or directory names skipped wherever they appear, on top of `.git .history node_modules target dist build .venv venv vendor gradlew mvnw` |

What is scanned: `*.sh`, `*.bash` and extension-less files whose first line is a `sh`/`bash` shebang;
`Dockerfile`, `Dockerfile.*`, `*.Dockerfile`, `Containerfile`; `compose.y(a)ml` and
`docker-compose*.y(a)ml` (checked with `docker compose config` for structure only: variables are not
interpolated and env files are not read, so an uncommitted `.env` or a `${VAR:?}` without a value is
fine); `.github/workflows/*.y(a)ml` (actionlint with shellcheck); the folder holding the shallowest
`ansible.cfg` (ansible-lint, default profile). Tools run from images pinned by tag and digest.

### docker-build inputs

| Input | Default | Notes |
|---|---|---|
| `context` | `.` | Relative path inside the repository |
| `dockerfile` | `Dockerfile` | Relative to `context` |
| `build-args` | `""` | One `KEY=VALUE` per line, public values only (a `VITE_*` or `NEXT_PUBLIC_*` the Dockerfile needs); secrets never belong in a build argument |
| `target` | `""` | Dockerfile stage to build (`--target`) |
| `smoke` | `""` | Command run after the build with `IMAGE` set to the locally loaded image, e.g. `docker run --rm -d -p 8080:80 "$IMAGE" && sleep 2 && curl -fsS localhost:8080/health`; non-zero exit fails the job |
| `push` | `false` | Push to GHCR once the build and the smoke test passed, tagged `sha-<7 chars>`, plus `latest` on the default branch and the tag name on a tag |
| `image` | `""` | Image to push, `ghcr.io/<owner>/<name>` lower-case; defaults to `ghcr.io/<owner>/<repository>` |

The build cache (`type=gha`) is scoped by context, Dockerfile and target, so two docker-build jobs of
one repository (two Dockerfiles, two targets) no longer overwrite each other's cache. The workflow sets no
`permissions` of its own: the calling job's apply, so set them explicitly in the caller (every example
does). `contents: read` builds; `push: true` also needs `packages: write` on the calling job
(`permissions: {contents: read, packages: write}`), and logs in to GHCR with `GITHUB_TOKEN`, so no extra
secret. The checkout keeps no credentials: neither the build context nor the `smoke` command sees a token.

### deploy-coolify inputs and secrets

| Name | Kind | Default | Notes |
|---|---|---|---|
| `coolify-url` | input | required | |
| `app-uuid` | input | required | |
| `wait` | input | `true` | Follow the deployment and verify the deployed commit |
| `environment` | input | `production` | GitHub environment of the `deploy` job: the repository gets a deployment history, and protection rules set on that environment (required reviewers, wait timer) gate the job. Rename it per caller; it cannot be turned off |
| `healthcheck-url` | input | `""` | After Coolify reports `finished` with the right commit, `GET` this URL until it answers 200 (every 5 s). Redirects are not followed: give the final URL. Coolify's status says the container started, not that it serves: this is the check that catches a container that boots and dies |
| `healthcheck-expect` | input | `""` | Text the healthcheck body must contain, e.g. the commit SHA when the app exposes it |
| `healthcheck-timeout` | input | `120` | Seconds before the healthcheck fails the job; a whole number from 1 to 900 (the job itself allows 30 min) |
| `coolify-token` | secret | required | |

A failure message names the deployment uuid and the elapsed time, so the Coolify log is one search away.

## Use it in a project

1. Copy [`examples/caller-node-coolify.yml`](examples/caller-node-coolify.yml) (Node + Docker + infra lint + Coolify),
   [`examples/caller-rust.yml`](examples/caller-rust.yml) (Rust, CI only),
   [`examples/caller-rust-tauri.yml`](examples/caller-rust-tauri.yml) (Tauri app, Linux + Windows),
   [`examples/caller-android.yml`](examples/caller-android.yml) (Android app) or
   [`examples/caller-infra.yml`](examples/caller-infra.yml) (scripts, Dockerfiles, compose, Ansible only) to `.github/workflows/ci.yml`.
   If the production branch is not `main`, change the `branches:` line only.
2. In Coolify: **Keys & Tokens → API tokens**, create a token with **read** and **deploy** only
   (never `root` or `write`): `deploy` triggers the deployment, `read` follows it. Coolify tokens are
   team-wide, so one token can serve every project. Make sure API access is enabled
   (Settings → Advanced).
3. In the GitHub repository:
   ```bash
   gh variable set COOLIFY_URL --body https://coolify.example.com
   gh variable set COOLIFY_APP_UUID --body <application uuid>
   gh secret set COOLIFY_TOKEN        # paste the token when prompted
   ```
4. Push once with Coolify auto-deploy still on and check the `deploy` job is green.
5. Turn off **Auto Deploy** for the application in Coolify. From now on, only green CI deploys.

## Versioning

Pin `@v1`. Each release gets an immutable `vX.Y.Z` tag and a GitHub release with generated notes
(`release.yml`, on tag push); `v1` moves to the latest compatible release once that release has run on
a real project pinned to its exact version. Breaking changes ship as `v2`. Third-party actions are pinned
by commit SHA and bumped by Dependabot; tool images are pinned by digest.

## Known limits

- **Manual redeploys bypass CI.** Coolify's *Redeploy* button deploys whatever is on the branch. It is
  also the break-glass path when GitHub Actions or MyCI is down.
- **Race window.** A push landing between the freshness check and Coolify's clone can be deployed;
  the commit verification then turns the job red instead of letting it pass silently.
- **Rollback is manual:** redeploy a previous deployment from the Coolify UI.
- **Tokens are team-wide in Coolify.** A leaked token can deploy (not reconfigure) any application of
  the team. Rotate it repository by repository (`gh secret set COOLIFY_TOKEN`).
- **Build args.** `docker-build` does not receive the build args or variables Coolify injects. Pass the
  public ones with `build-args`; if the Dockerfile needs a secret at build time, drop the `docker` job
  from the caller (and from `deploy.needs`): Coolify's own build is still checked by the deployment status.
- **Already-queued deployments.** If Coolify already has a deployment of the app queued or running
  (for example a manual *Redeploy*), it does not start a new one; the job fails with a message saying
  so, since it cannot verify a deployment it did not start.
- **Private repositories on GitHub Free** do not enforce branch protection: red code can be merged,
  it just never gets deployed.

## Development

```bash
bash tests/run.sh   # every suite: workflow steps on fixtures, deploy-coolify vs a fake Coolify, lint tools in Docker
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 -no-color .github/workflows/*.yml examples/*.yml
```

Tests execute the exact `run:` scripts extracted from the workflow files (`tests/lib/extract-step.py`);
Docker is needed (actionlint, and the lint-infra suite runs hadolint, shellcheck and compose for real).
`self-test.yml` also runs the templates on fixtures and dispatches `negative-fixture.yml`, asserting that
each broken fixture fails at the expected step. The Android fixtures build locally with
`cd fixtures/android-ok && ./gradlew assembleDebug check` (JDK 21, `ANDROID_HOME` set).

Rules of the repository: a step with logic has an `id` and a test that extracts it; a failure path is a
fixture **and** a job of `negative-fixture.yml` listed in self-test's `EXPECTED`; a job added to
`self-test.yml` is also added to the required checks of the `protect-main` ruleset
(`gh api repos/K-Schmitt/MyCI/rulesets`); Dependabot bumps the SHA-pinned actions, the digest-pinned
tool images inside `run:` steps are bumped by hand.
