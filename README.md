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
| `node-ci.yml` | Lockfile-strict install (npm or pnpm, auto-detected), then `lint`, `typecheck`, `test`, `build` when present. Scripts listed in `require` (default `lint,build`) must exist. A job summary lists what ran, failed or was absent. |
| `rust-ci.yml` | The pinned toolchain (`rust-toolchain.toml`) and `Cargo.lock` are present, then the project's own quality gate runs (default `cargo xtask check`) with a Cargo cache and `cargo-deny` installed when a `deny.toml` exists. |
| `python-ci.yml` | Installs the requirements files on the requested Python and runs the project's own gate (pytest by default). |
| `docker-build.yml` | The project's Dockerfile builds (no push). It does not reproduce Coolify's build args. |
| `deploy-coolify.yml` | Triggers a Coolify deployment, follows it to the end, and fails unless Coolify reports `finished` **and** the deployed commit equals the tested commit. |

### node-ci inputs

| Input | Default | Notes |
|---|---|---|
| `node-version` | `24` | Ignored when `.nvmrc` exists |
| `require` | `lint,build` | Comma-separated; empty string disables the check |
| `pnpm-version` | `""` | Only for pnpm projects without a `packageManager` field |
| `working-directory` | `.` | Folder holding `package.json` |

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

### docker-build inputs

| Input | Default |
|---|---|
| `context` | `.` |
| `dockerfile` | `Dockerfile` (relative to `context`) |

### deploy-coolify inputs and secrets

| Name | Kind | Default |
|---|---|---|
| `coolify-url` | input | required |
| `app-uuid` | input | required |
| `wait` | input | `true` |
| `coolify-token` | secret | required |

## Use it in a project

1. Copy [`examples/caller-node-coolify.yml`](examples/caller-node-coolify.yml) (Node + Coolify) or
   [`examples/caller-rust.yml`](examples/caller-rust.yml) (Rust, CI only) or
   [`examples/caller-rust-tauri.yml`](examples/caller-rust-tauri.yml) (Tauri app, Linux + Windows) to `.github/workflows/ci.yml`.
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

Pin `@v1`. Each release gets an immutable `vX.Y.Z` tag; `v1` moves to the latest compatible release
once that release has run on a real project pinned to its exact version. Breaking changes ship as `v2`.
Third-party actions are pinned by commit SHA.

## Known limits

- **Manual redeploys bypass CI.** Coolify's *Redeploy* button deploys whatever is on the branch. It is
  also the break-glass path when GitHub Actions or MyCI is down.
- **Race window.** A push landing between the freshness check and Coolify's clone can be deployed;
  the commit verification then turns the job red instead of letting it pass silently.
- **Rollback is manual:** redeploy a previous deployment from the Coolify UI.
- **Tokens are team-wide in Coolify.** A leaked token can deploy (not reconfigure) any application of
  the team. Rotate it repository by repository (`gh secret set COOLIFY_TOKEN`).
- **Build args.** `docker-build` does not receive the build args or variables Coolify injects. If the
  Dockerfile needs them, drop the `docker` job from the caller (and from `deploy.needs`): Coolify's own
  build is still checked by the deployment status.
- **Already-queued deployments.** If Coolify already has a deployment of the app queued or running
  (for example a manual *Redeploy*), it does not start a new one; the job fails with a message saying
  so, since it cannot verify a deployment it did not start.
- **Private repositories on GitHub Free** do not enforce branch protection: red code can be merged,
  it just never gets deployed.

## Development

```bash
bash tests/run.sh   # script tests: deploy-coolify vs a fake Coolify, node-ci and docker-build steps on fixtures
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12 -no-color .github/workflows/*.yml examples/*.yml
```

Tests execute the exact `run:` scripts extracted from the workflow files. `self-test.yml` also runs
the templates on fixtures and dispatches `negative-fixture.yml`, asserting that each broken fixture
fails at the expected step.
