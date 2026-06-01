# Implementation plan — #154 Per-repo CI publication

Parent design brief: [`docs/plans/118-D-ci-publication.md`](118-D-ci-publication.md). Reconciliation caveat from [`docs/plans/README.md`](README.md): `audit-core` must drive 2–4 extractors per language via the canonical `code-audit extract` entry point, not the one-shot raw `node …` invocations sketched in the original brief.

## What's already on `main`

- `pipeline/publish-catalog.sh` (#153) — validates a directory of v1.1-wrapped catalogs and uploads them under `by-repo/<flattened-repo>/<iso>_<short-sha>/` + writes a per-repo `latest.json` + triggers `refresh-index.mjs`. Takes `--repo`, `--sha`, `--catalogs-dir`, plus `--bucket-fs` or (`--bucket-name`+`--bucket-endpoint`). Done.
- `pipeline/refresh-index.mjs` (#153) — listing-driven `index.json` reconciliation. Done.
- `code-audit extract <name> --root .` (Go binary, `internal/cli/extract.go`) — runs every `[[command]]` in `~/.config/audit/extractors/<name>/manifest.toml`, writes outputs to `.audit/catalogs/*.json`. Each extractor already emits the v1.1 wrapper natively, so no separate `wrap-catalog` step is needed.
- Extractors: `typescript` (type + function), `swift` (type + function + package-graph), `file-hashes` (polyglot). All ship their own `manifest.toml`.

## What this issue must add

A composite GitHub Action that any sibling repo can opt into with one workflow file:

1. Detect dominant language(s) from marker files at repo root.
2. Install required toolchains (Node / Swift / Go / etc., conditional on detection).
3. Install `code-audit` + extractors (via the release artifact + `code-audit init`).
4. Run `code-audit extract <lang>` per detected language, plus `code-audit extract file-hashes` unconditionally.
5. Emit a composite output: path to the `.audit/catalogs/` directory plus the detected language list.

Plus a **publication-specific reusable workflow** that wraps the composite and uploads to R2 via `pipeline/publish-catalog.sh`.

Plus a **consumer template** + one-page setup doc for sibling-repo maintainers.

## PR split (CLAUDE.md ≤1000-line cap)

| PR | Scope | Reviewable independently | Closes |
|---|---|---|---|
| **PR 1** | `audit-core` composite + self-test workflow + detect-languages.sh unit tests + setup doc | ✅ — no external infra dependency | (refs #154; #123 also depends on it) |
| **PR 2** | `publish-catalog-reusable.yml` + consumer template `audit-publish.yml.example` + OIDC/R2 docs | depends on PR 1 merged | `Closes #154` |

Both land under `wxyc/code-audit-pipeline` (this repo). The first lays the foundation; the second wires it to R2.

## PR 1 — `audit-core` composite

### Files added

```
.github/actions/audit-core/
├── action.yml                                 ~150 LoC
├── README.md                                  ~80 LoC — usage + caller examples
└── scripts/
    └── detect-languages.sh                    ~80 LoC

.github/workflows/
└── audit-core-selftest.yml                    ~50 LoC — runs the composite against this repo as fixture

pipeline/_tests/
├── test_audit_core.sh                         ~120 LoC — POSIX shell unit tests for detect-languages.sh
└── fixtures/audit-core-detect/
    ├── ts-only/{tsconfig.json, src/index.ts}
    ├── swift-only/{Package.swift, Sources/foo/main.swift}
    ├── go-only/{go.mod, main.go}
    ├── polyglot/{tsconfig.json, Package.swift}
    └── empty/                                  (no markers)
```

### `action.yml` interface (committed under `code-audit-pipeline/.github/actions/audit-core/`)

Inputs:
- `root` (default `.`) — repo root to scan
- `languages` (default empty = auto-detect) — explicit override, comma-separated
- `binary-version` (default `v1`) — `code-audit` release tag to install. **Pinned to a major version by default** so consumers get patches automatically but never an unexpected breaking change. Set to `latest` to track the bleeding edge; set to a fully-pinned `v1.2.3` to freeze. Resolved via `gh release list --json tagName --jq '...'` if the input is `v1`/`v2`.
- `include-tests` (default `false`)
- `include-file-hashes` (default `true`) — file-hashes is polyglot; default-on per the contract
- `audit-root` (default `${{ inputs.root }}`) — where to place `.audit/` (lets callers cache it on a different prefix)
- `github-token` (default `${{ github.token }}`) — passed to `gh release download` via `GH_TOKEN`. Public-repo callers can ignore; private-repo callers or IP-restricted orgs may need to supply a token with `contents: read` on this repo.

Outputs:
- `catalogs-dir` — absolute path to `.audit/catalogs/` (input to `publish-catalog.sh`)
- `languages-detected` — comma-separated list, e.g. `typescript,swift`
- `binary-version-used` — resolved version string for downstream metadata
- `requires-macos` — boolean (`"true"`/`"false"`); true iff Swift was detected. Lets callers gate the *next* job onto `runs-on: macos-latest` instead of running the whole composite on macOS unconditionally.

Internal steps:
1. **detect** — run `detect-languages.sh ${{ inputs.root }}` → exports `languages` to `$GITHUB_OUTPUT`
2. **setup-node** — `if: contains(steps.detect.outputs.languages, 'typescript')` — `actions/setup-node@v6` + cache + `npm ci` in extractors/typescript on the *audit pipeline checkout* (see below)
3. **setup-swift** — `if: contains(... 'swift')` — uses `SwiftyLab/setup-swift` action; OR runs on the macOS runner if the caller's workflow specified one
4. **setup-go** — `if: contains(... 'go')` — `actions/setup-go@v6`
5. **install-binary** — `gh release download` against `wxyc/code-audit-pipeline` → `code-audit` on PATH; then `code-audit init --from <pipeline checkout>` populating `~/.config/audit/extractors/`
6. **extract** — bash loop: `for lang in ${{ steps.detect.outputs.languages }}; do code-audit extract "$lang" --root "${{ inputs.root }}"; done; code-audit extract file-hashes --root "${{ inputs.root }}"`
7. **emit** — set `catalogs-dir` output to `${{ inputs.audit-root }}/.audit/catalogs`

**Self-location:** the composite needs the extractor source trees on disk (`code-audit init --from <path>` needs a checkout of this repo). Use `${{ github.action_path }}` — when a caller does `uses: wxyc/code-audit-pipeline/.github/actions/audit-core@v1`, GitHub Actions checks out *this repo* at `action_path`. The composite passes `--from ${{ github.action_path }}/../..` to `code-audit init`.

### `detect-languages.sh`

```
#!/usr/bin/env bash
# Usage: detect-languages.sh <repo-root>
# Prints a comma-separated language list on stdout (e.g. "typescript,swift").
# Empty output (exit 0) when no markers match — the caller decides whether
# to fail or proceed with file-hashes only.

set -Eeuo pipefail
root="${1:-.}"
declare -a langs

[ -f "$root/tsconfig.json" ] || [ -f "$root/package.json" ] && langs+=("typescript")
[ -f "$root/Package.swift" ] && langs+=("swift")
[ -f "$root/go.mod" ] && langs+=("go")
[ -f "$root/pyproject.toml" ] || [ -f "$root/setup.py" ] && langs+=("python")
[ -f "$root/Cargo.toml" ] && langs+=("rust")

(IFS=,; echo "${langs[*]:-}")
```

TypeScript marker rule: per the brief, `package.json` alone without `.ts`/`.tsx` sources is *not* a TS repo (CRA/Webpack-only JS). PR 1 takes the simple stance — `package.json` OR `tsconfig.json` → typescript — and lets the extractor itself decide "no `.ts` files, output an empty catalog." Refinement is a Phase-3 concern; the cost of a no-op extractor run on a JS-only repo is small.

### `test_audit_core.sh` (POSIX shell, runs under existing test harness)

Each test creates a temp dir, copies one of the fixtures into it, runs `detect-languages.sh <tmp>`, and asserts on stdout. Cases:

- `ts-only` → `typescript`
- `swift-only` → `swift`
- `go-only` → `go`
- `polyglot` (TS + Swift) → `typescript,swift` (order: stable, alphabetical-ish; pin the expected order in the assertion)
- `empty` → `""` (empty output, exit 0)
- root path containing spaces — confirm `"$root"` quoting holds
- `--help` flag — refuses with exit 2 and prints usage (validates flag-handling, even though caller passes positional only)

Wire into `.github/workflows/ci.yml`'s shellcheck list + as a new test step.

### Self-test workflow (`audit-core-selftest.yml`)

Triggers: `pull_request` (paths: `.github/actions/audit-core/**`, `extractors/**`, `cmd/code-audit/**`) + `push` to main on same paths.

Steps:
1. Checkout `code-audit-pipeline` (this repo)
2. Build `code-audit` binary from source (`go build ./cmd/code-audit`)
3. `uses: ./.github/actions/audit-core` with `root: <repo-root>`, `binary-version: build-from-source`
4. Assert `.audit/catalogs/type-catalog.json`, `.audit/catalogs/function-catalog.json`, `.audit/catalogs/file-hashes.json` exist and each parses as a v1.1 wrapper

This is the **only** end-to-end test that runs the composite. CI for the unit tests is cheap; the self-test runs once per relevant PR.

### Setup doc (`.github/actions/audit-core/README.md`)

One page:
- Caller example (the one-screen consumer YAML the brief targets)
- Inputs/outputs reference
- Polyglot behavior
- Troubleshooting (binary not found / extractor toolchain missing / `code-audit init` failed)

### Runner-selection responsibility

The composite does **not** declare `runs-on:` — composites inherit the caller's runner. Two implications callers must own:

1. If they're not sure whether the repo uses Swift, they should run a small detection-only job first (one ubuntu step calling `detect-languages.sh`), then dispatch a second job onto `macos-latest` if `requires-macos == "true"`. The composite's `requires-macos` output exists for exactly this pattern.
2. A polyglot TS+Swift repo runs the *whole* composite on macOS (slower Node toolchain, more expensive runner minutes). Phase-2 follow-up could split via `actions/upload-artifact` to keep the TS half on ubuntu. Not blocking for #154.

The README must state this explicitly under "Polyglot behavior" — both the gating pattern and the cost note.

### Open decisions for PR 1

- **Polyglot ordering.** Detection emits languages in a fixed order (typescript, swift, go, python, rust) so cache keys / output diffs are stable. Document in the README.
- **Self-test cannot exercise the release-download path.** The `audit-core-selftest.yml` workflow runs in PRs *before* a release exists for the changed code, so it must always use `build-from-source`. The `gh release download` path (default consumer flow) is untested in CI until PR 2 lands and a first real consumer publishes. Flag in PR 1 description that this is a known gap; the alternative (publishing a pre-release on each PR) is not worth the complexity.
- **`${{ github.action_path }}` self-location is untested in the unit suite.** Validated only by the self-test workflow. Note in PR description.

## PR 2 — publication wrapper

### Files added (sketch — refined when PR 1 is in)

```
.github/workflows/
└── publish-catalog-reusable.yml               ~80 LoC — workflow_call entry point

.github/templates/
└── audit-publish.yml.example                  ~25 LoC — one-screen consumer YAML

docs/
└── audit-publish-setup.md                     ~150 LoC — onboarding for sibling repos, OIDC config, R2 setup
```

### `publish-catalog-reusable.yml`

```yaml
on:
  workflow_call:
    inputs:
      bucket-name:     { type: string, required: true }
      bucket-endpoint: { type: string, required: true }
      audit-binary-version: { type: string, default: 'latest' }
      include-tests:   { type: boolean, default: false }
    secrets:
      r2-access-key-id:     { required: true }
      r2-secret-access-key: { required: true }
```

Steps:
1. Checkout caller repo (`actions/checkout@v6`, `fetch-depth: 1`)
2. Use `audit-core` composite
3. `aws-actions/configure-aws-credentials@v4` for R2 (S3-compatible, OIDC trust)
4. Run `pipeline/publish-catalog.sh --repo ${{ github.repository }} --sha ${{ github.sha }} --catalogs-dir <output> --bucket-name <input> --bucket-endpoint <input>`

### Consumer template (`audit-publish.yml.example`)

The one-screen sibling-repo file from the brief, ready to copy.

### Setup doc

Goes through:
- Bucket creation + IAM policy for OIDC-scoped write to `by-repo/<repo>/*`
- Cloudflare OIDC trust setup
- Adding the consumer workflow to a new repo
- Verifying publication with `code-audit query coverage` against the freshly-populated bucket

## Testing strategy

PR 1:
- **Unit:** `test_audit_core.sh` exercises `detect-languages.sh` against fixture trees. Hermetic, runs in seconds, no network.
- **Integration:** `audit-core-selftest.yml` workflow runs the composite end-to-end against this repo's own checkout. Catches YAML syntax errors, missing tools, ordering bugs, and the `${{ github.action_path }}` self-location pattern.
- No `act`-based test in PR 1 — premature given the self-test workflow already covers the same ground in real CI.

PR 2:
- **Unit:** none new. The reusable workflow is dataflow-only.
- **Integration:** add an extension to `pipeline/_tests/test_substrate.sh` (or a new test) that runs the composite against `pipeline/_tests/fixtures/audit-core-detect/polyglot/`, then drives `publish-catalog.sh --bucket-fs <tmpdir>` against the resulting `.audit/catalogs/`, asserts the keys land where expected.
- **No real-OIDC test in CI.** That requires production R2 + GitHub org config; defer to manual smoke test on the first real consumer repo.

## Acceptance criteria mapping

The issue body's top-3 KPIs:

1. **Per-push job <2 min p95 on dj-site fixture.** PR 1's self-test gives us a baseline wall-clock; PR 2's first real-consumer run validates against a production repo. Tracked-not-blocked for the PRs themselves.
2. **Publication success rate >99% over 30 days.** Post-PR-2 operational signal; cannot be validated until Phase 2 rollout.
3. **`audit-core` shared with #123.** PR 1 builds the composite; the brief calls for #123 to consume it. PR 1's README + the action's input/output stability are what makes this acceptance check pass.

## Risk / blockers

- **`code-audit` binary release tag must exist.** The `gh release download wxyc/code-audit-pipeline` step in PR 1 needs at least one released tag. Recent commits show `8d818c18 fix(214): rename binary audit → code-audit` and a `release.yml` workflow — confirm a release exists or wire the self-test to `build-from-source` mode (which is what PR 1's self-test does) and only require the release path in PR 2.
- **macOS runner cost for Swift detection.** `audit-core` only spins up a macOS runner if Swift is detected, but a polyglot repo with TS + Swift forces macOS for the whole job. Mitigation: split into two jobs sharing the catalogs dir via `actions/upload-artifact` — defer to a follow-up if Phase-1 production runs prove slow.
- **Composite-action checkouts of this repo are per-runner.** Each invocation re-clones `code-audit-pipeline`. The `git fetch` for `gh release download` is cheap; not a blocker.

## Out of scope (followups, not blockers)

- Pre-built per-language extractor binaries hosted in the substrate (`r2://_extractors/`). Brief §9 lists this as a Phase-3 optimization; deferred.
- Schema-bump compatibility test (the brief's `preflight-versions.jq` round-trip). Implementable in PR 2 against the fixture; tentatively in scope, will cut if PR 2 grows over the line budget.
- 30-repo bulk-rollout PRs. Operational task, not a code change here.
