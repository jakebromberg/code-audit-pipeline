# D — Per-repo CI publication: extract catalog on push, upload to substrate

**Parent:** [#118 — Cross-repo queries — merging N catalogs across the org](https://github.com/jakebromberg/code-audit-pipeline/issues/118).
**Coordinates with:** [#120 — Dev-flow integration](https://github.com/jakebromberg/code-audit-pipeline/issues/120) at the composite-action layer.
**Blocked by:** [C — Catalog substrate](118-C-substrate.md) (defines `publish-catalog.sh` contract).

## 1. Context summary

This Action is the **producer** side of #118's substrate. Each of ~30 sibling repos installs a one-line workflow that, on every push to the default branch, runs the language-appropriate extractor, packages a top-level catalog object (per [A](118-A-schema-v2.md) — `repo`, `commit_sha`, `extractor`, `generated_at`, `scope`, `entries`), and uploads it to a content-addressable key in central object storage (`r2://wxyc-catalogs/by-repo/<repo>/<sha>.json`) plus a mutable `latest.json` pointer per repo. A central `index.json` enumerates every repo's most recent successful publication, with extractor-version metadata.

**How it differs from the #120 PR-comment Action:**

| Dimension | #118 publication (this brief) | #120 PR-comment |
|---|---|---|
| Trigger | `push` to default branch + `schedule` (nightly) + `workflow_dispatch` | `pull_request` |
| Output | `catalog-<sha>.json` written to R2, plus `latest.json` mutable pointer | Markdown comment on a PR, sticky-keyed |
| Permissions | `id-token: write` (OIDC to R2) | `pull-requests: write` (GitHub-issued token only) |
| Cardinality | One execution per push, one artifact per execution | One execution per PR sync, ephemeral |
| Idempotency lever | Bucket key is the SHA → re-runs are no-ops on repeat | Sticky comment marker (`<!-- code-audit-pipeline:v1 -->`) |

**Shared substrate.** Both flows need to: (a) detect language from marker files; (b) install language toolchain + the matching extractor; (c) invoke the extractor with the right flags; (d) shape the output into the canonical catalog block. That's exactly the surface of a single composite action — call it `audit-core` — that both publication and PR-comment workflows consume. The publication side adds an "upload-to-substrate" step after `audit-core`; the PR-comment side adds "diff-against-baseline + render markdown + sticky-post." Centralizing the shared bits in one composite action is the load-bearing decision at 30-repo scale: when the catalog contract changes, you bump one tag, not 30 workflow files.

## 2. Functional requirements

### Triggers

```yaml
on:
  push:
    branches: [main, master]   # whatever the repo's default is — detect, don't hard-code
  schedule:
    - cron: '17 7 * * *'       # nightly safety net, jittered hour to avoid herding
  workflow_dispatch:           # manual rerun for one-off recovery
```

The `schedule` trigger is a sweep, not a delta — if the most recent push-triggered run for this repo failed, the nightly run produces a fresh catalog from `HEAD` of the default branch. Catches webhook drops, transient extractor failures, missing toolchain installs.

### Job shape — language detection

A single job that detects the dominant language(s) via marker files at repo root:

| Marker file present | Extractor invoked |
|---|---|
| `tsconfig.json` or `package.json` with `.ts`/`.tsx` sources | TypeScript |
| `pyproject.toml` or `setup.py` | Python |
| `go.mod` | Go |
| `Package.swift` | Swift |
| `Cargo.toml` | Rust |

For polyglot repos (rare in the WXYC org per #120's "most of the 30 repos are single-language"), the composite action runs each detected extractor and concatenates their `entries` arrays under one top-level catalog object — each entry carries its own `extractor` field. Single-language is the hot path; the YAML stays linear.

### Extractor invocation

`extractor --root . --output /tmp/entries.json` (per the CLI contract in `docs/pipeline-contract.md`). The composite action then wraps the raw entries with the top-level metadata block per [A](118-A-schema-v2.md):

```jsonc
{
  "repo": "wxyc/dj-site",
  "commit_sha": "abc123…",
  "extractor": { "name": "type-catalog", "version": "1.3.0", "language": "typescript" },
  "generated_at": "2026-05-25T07:17:42Z",
  "scope": { "files_indexed": 194, "files_total": 198, "errors": 0 },
  "entries": [ /* the raw extractor output */ ]
}
```

### Upload step

Target: `r2://wxyc-catalogs/by-repo/<repo-slug>/<sha>.json` plus `r2://wxyc-catalogs/by-repo/<repo-slug>/latest.json`. Retry with exponential backoff (3 attempts, 2s / 8s / 32s) on transient `5xx`. **Auth: GitHub OIDC → Cloudflare token assumption** — no long-lived secrets, federated trust scoped to `repo:wxyc/*:ref:refs/heads/main`. The token's policy permits `PutObject` on `wxyc-catalogs/by-repo/<repo-slug>/*` only — one role with a path-templated policy, instantiated per repo via a permission boundary keyed on the GitHub claim subject.

### `index.json` update strategy

**Reconciled-from-bucket-listing, not per-write.** Per-write means every repo's publish job mutates one shared object: race conditions, lost-update on simultaneous pushes, and a fan-in dependency that violates the "fail-independently" property the substrate brief calls for. Reconcile-from-listing means a separate central job (R2 event trigger or cron in a 31st workflow housed in `wxyc/catalogs` itself) lists the bucket, reads each `latest.json`'s metadata block, and writes a fresh `index.json`. The per-repo Action is *write-only to its own prefix*. Tradeoffs:

- Pro: per-repo jobs are fully independent, no shared mutable state, no concurrency primitives needed in the publish path.
- Pro: index is regeneratable from R2 at any time — no possibility of `index.json` drifting from ground truth.
- Con: index is *eventually* consistent (typically <30s lag with R2 events; <24h with cron). Acceptable per #118's "snapshot consistency is eventual" stance.

### Failure handling

A flaky extractor must not block subsequent pushes. The job's `continue-on-error: false` ensures the run fails and is visible on the commit, but because each push is its own workflow run, a failed publication at commit N has no effect on commit N+1's publication. The nightly cron sweep is the safety net for repos whose most-recent push failed.

### Permissions model

- Workflow `permissions:` block: `contents: read`, `id-token: write` (for OIDC), nothing else.
- Cloudflare API token: trust policy scoped to the GitHub OIDC issuer + `repo:wxyc/*:ref:refs/heads/main`; permission policy scoped to `PutObject` on the repo's prefix only.
- **Secret rotation:** none required. OIDC tokens are short-lived (15min) and minted per-workflow-run.

## 3. Non-functional requirements

**Wall-clock budget: under 2 minutes total.** Case-study numbers: extraction on a 194-file TS repo ran in ~2 seconds. Realistic split:

- Checkout (with `fetch-depth: 1`): ~5s
- Toolchain install (cached node_modules / pip cache / Go module cache): ~10–20s warm, ~60s cold
- Extractor run: 1–5s for typical repos, up to ~30s for the largest
- Upload to R2 (single PUT, ~50–200KB catalog): ~1s
- Total warm: ~20–40s. Total cold: ~80–120s. Cold path is the worst case; warm is overwhelmingly the steady state.

**Concurrency.** Multiple pushes to `main` back-to-back must not corrupt `index.json`. The reconcile-from-listing design (above) sidesteps this: per-repo writes go to SHA-keyed paths (immutable) plus the repo's own `latest.json` (single-writer per repo). A `concurrency:` block on the workflow with `group: publish-catalog-${{ github.repository }}` and `cancel-in-progress: true` collapses a burst of pushes to a single execution covering the latest SHA. This trades the intermediate snapshots for a guaranteed-eventually-correct latest — appropriate for a catalog substrate where intermediate states aren't queried.

**Cost.** Actions minutes × 30 repos × N pushes/day. Assuming 5 pushes/day average per repo and 1-minute warm runs: 30 × 5 × 1min × 30 days = **4,500 minutes/month**. Ubuntu minutes on free public-repo tier are unlimited; on the org's paid tier at $0.008/minute, ~$36/month. Add nightly sweep: 30 × 1min × 30 = 900 minutes (~$7/month). R2 storage: 30 repos × ~150 SHAs/month × 100KB = ~450MB/month growth, ~$0.01/month. **Total ongoing cost is dominated by Actions minutes, ballpark $50/month.**

**Observability.**

- Each job writes a structured JSON log line per phase (extractor stats, upload result, total wall-clock) to stdout. GitHub captures these for 90 days.
- Post-publish status check on the commit: `audit-publish/success` or `audit-publish/failure`. Lets cross-repo dashboards (and humans) tell at a glance whether the catalog for a SHA is current.
- Central reconciler emits Prometheus-style metrics from R2 listings: `audit_catalog_repos_total`, `audit_catalog_stale_24h_total`, `audit_catalog_publish_lag_seconds_p99`. Surfaced via a simple `pipeline/coverage.jq` (see [E](118-E-operational-safety.md)) plus a daily Slack/email digest if any repo's `latest.json` is older than 48h.

## 4. Reusable composite action design

Repo: `wxyc/code-audit-pipeline` (this repo). Path: `.github/actions/audit-core/action.yml` (the shared invocation) and a workflow `.github/workflows/publish-catalog-reusable.yml` (the publication-specific wrapper).

**`audit-core/action.yml` interface:**

```yaml
name: audit-core
description: Detect language, install toolchain, run extractor, emit canonical catalog object
inputs:
  root:
    description: Repo root to scan
    default: '.'
  shared:
    description: Optional shared-types sibling path
    required: false
  extractor-version:
    description: Pin to a tagged release of code-audit-pipeline (e.g., v1.3.0)
    required: false
    default: 'v1'
  include-tests:
    description: Pass --include-tests to the extractor
    default: 'false'
outputs:
  catalog-path:
    description: Filesystem path to the wrapped catalog JSON
    value: ${{ steps.wrap.outputs.path }}
  language:
    description: Detected language (typescript|python|go|swift|rust|polyglot)
    value: ${{ steps.detect.outputs.language }}
  extractor-version:
    description: Actual extractor version used (for downstream metadata)
    value: ${{ steps.detect.outputs.version }}
runs:
  using: composite
  steps:
    - id: detect      # marker-file scan → set language output
    - id: install     # language-conditional toolchain setup (uses actions/setup-node etc.)
    - id: extract     # node extractors/<lang>/...  --root ${{ inputs.root }} --output entries.json
    - id: wrap        # wrap entries + metadata block → catalog-<sha>.json
```

**Language detection: inside the action, not via matrix.** Matrix-at-call-site would require each of 30 repos to know which extractor they need; the whole point of centralization is that they don't. Marker-file detection inside the composite action means the consumer YAML is one line:

```yaml
- uses: wxyc/code-audit-pipeline/.github/actions/audit-core@v1
```

Polyglot repos handled via the action emitting multiple `entries` chunks merged into one catalog. The composite action self-locates its extractors via `${{ github.action_path }}/../../extractors/<lang>/`.

**Publication-specific reusable workflow** (`.github/workflows/publish-catalog-reusable.yml`):

```yaml
on:
  workflow_call:
    inputs:
      bucket: { type: string, default: 'wxyc-catalogs' }
      endpoint: { type: string, default: 'https://<account>.r2.cloudflarestorage.com' }
    secrets:
      r2-access-key-id: { required: true }
      r2-secret-access-key: { required: true }
```

Per-repo consumer (`.github/workflows/audit-publish.yml` in each sibling repo) is **one screen** total:

```yaml
name: Publish catalog
on:
  push: { branches: [main] }
  schedule: [{ cron: '17 7 * * *' }]
  workflow_dispatch:
concurrency:
  group: publish-catalog-${{ github.repository }}
  cancel-in-progress: true
permissions: { contents: read, id-token: write }
jobs:
  publish:
    uses: wxyc/code-audit-pipeline/.github/workflows/publish-catalog-reusable.yml@v1
    secrets:
      r2-access-key-id: ${{ secrets.AUDIT_PUBLISH_R2_KEY }}
      r2-secret-access-key: ${{ secrets.AUDIT_PUBLISH_R2_SECRET }}
```

Centralizing means: when the catalog schema bumps from v1 to v2, you cut a `v2` tag on `code-audit-pipeline` and walk 30 repos through changing one number. No 30-PR fan-out for every schema iteration.

## 5. KPIs

1. **Per-push job completes in <2min on the `wxyc/dj-site` fixture (p95).** Validates the wall-clock budget end-to-end. Measured via workflow run duration in Actions.
2. **Catalog publication success rate >99% over a 30-day window** (push-triggered runs, excluding fork PRs which don't trigger). Tracks substrate health.
3. **Nightly sweep recovers any repo whose event-driven publish failed — zero stale catalogs after 24h.** Operationalized: `audit_catalog_stale_24h_total` metric stays at 0 (cron sweep ran successfully for every repo).
4. **Actions cost per repo per month <$3.** Sanity-check against budget at the 30-repo scale.
5. **`index.json` reconciler lag p95 <60s (event-driven) or <24h (cron-only).**
6. **Composite action major-version stability: zero unintended breaking changes between minor bumps on `@v1`.**

## 6. Testing strategy

- **`act` for local runs.** `act push -W .github/workflows/audit-publish.yml` against a local fixture repo exercises the composite action end-to-end without burning Actions minutes. Limited (no real R2, no OIDC — mock those), but catches 80% of YAML syntax and shell errors before push.
- **Test repo in the org: `wxyc/audit-publish-fixture`.** A small TypeScript repo with known catalog output (~10 declarations, byte-stable). The reusable workflow's CI in `code-audit-pipeline` itself runs `audit-publish-fixture` through the full pipeline on every PR, then asserts the published catalog matches a checked-in golden file (modulo `generated_at` and `commit_sha`). This is the *only* end-to-end test that runs the real OIDC + R2 path.
- **Post-publish status check on the commit.** `audit-publish/success | failure` GitHub status, set via `gh api`. Observability and a forcing function — a failed publish is visible on the commit history, not just buried in Actions logs.
- **Recovery testing.** Quarterly: deliberately revoke the R2 token's `PutObject` permission on one repo's prefix, push to that repo, confirm the job fails loudly with a useful error, restore permission, confirm the next nightly sweep publishes.
- **Schema-bump test.** When the catalog contract changes, the composite action's CI runs the *new* extractor against the fixture and asserts the output is parseable by both the old and new `pipeline/preflight-versions.jq` check.

## 7. Implementation recommendations

**File paths (this repo will own):**

- `/Users/jake/Developer/code-audit-pipeline/.github/actions/audit-core/action.yml` — the shared composite.
- `/Users/jake/Developer/code-audit-pipeline/.github/workflows/publish-catalog-reusable.yml` — publication-specific reusable workflow.
- `/Users/jake/Developer/code-audit-pipeline/.github/workflows/pr-comment-reusable.yml` — #120's reusable, sharing `audit-core`.
- `/Users/jake/Developer/code-audit-pipeline/scripts/wrap-catalog.mjs` — wraps extractor output with the top-level metadata block (called from `audit-core`).
- `/Users/jake/Developer/code-audit-pipeline/docs/audit-publish-setup.md` — onboarding doc for sibling-repo maintainers (one-page).

**Per-repo opt-in.** One file per consumer repo:

- `<repo>/.github/workflows/audit-publish.yml` — the ~10-line consumer config shown in §4.

**Rollout plan.**

1. **Phase 0 (week 1):** Build `audit-core` + `publish-catalog-reusable.yml` in `code-audit-pipeline`. Set up R2 bucket, API token, OIDC trust policy. Test against fixture repo `wxyc/audit-publish-fixture`.
2. **Phase 1 (week 2):** Enable on 2 production repos (`wxyc/dj-site`, `wxyc/shared`). Watch for two weeks. Tune wall-clock budget. Confirm `index.json` reconciler behaves correctly with 2 repos.
3. **Phase 2 (weeks 3–4):** Expand to remaining ~28 repos via batched PRs (5 per day). Each PR is one-file, mechanical.
4. **Phase 3 (ongoing):** Nightly sweep monitoring; tune cron jitter if all 30 repos cluster on the same minute. Add the 31st workflow (`wxyc/catalogs` reconciler) once Phase 2 is stable.

**Migration path.** No existing audit-related workflows in any sibling repo. If any repo grows one in the meantime, the consumer-config opt-in pattern means it lives alongside without conflict.

## 8. Coordination with #120

**Shared inputs/outputs:**

| Element | Owner | Consumer |
|---|---|---|
| `audit-core` composite action | This brief (`code-audit-pipeline` repo) | Both #118 publish and #120 PR-comment workflows |
| Catalog top-level metadata block schema | [A](118-A-schema-v2.md) | #120 (consumed when fetching baseline) |
| Extractor invocation flags | Pipeline contract (`docs/pipeline-contract.md`) | Both |
| Language detection logic | `audit-core` step | Both |

**`audit-core` is the unification point.** Both flows call it; both flows then diverge. #118 calls it and pipes the output to R2. #120 calls it twice (head + baseline), diffs them, posts a comment. The composite action knows nothing about substrate or PRs — it only emits a wrapped catalog.

**Ship as two PRs against `code-audit-pipeline`, in order:**

1. **PR 1: `audit-core` composite + fixture test.** Pure infrastructure, no external dependency. Reviewable, mergeable independently. Closes a precursor sub-issue.
2. **PR 2: `publish-catalog-reusable.yml` + R2/OIDC setup.** Depends on PR 1. Closes this sub-issue.
3. **(Tracked separately under #120) PR 3: `pr-comment-reusable.yml`.** Depends on PR 1. Closes #120's Action sub-issue.

Splitting this way keeps each PR under the 1000-line CLAUDE.md budget, keeps reviews focused, and means a problem with the publish flow doesn't block the PR-comment flow from merging.

## 9. Open questions / decisions still needed

- **OIDC provider setup.** Confirm the Cloudflare account has GitHub OIDC federation configured (one-time per account). If not, that's a half-hour task before Phase 0 ships.
- **Cross-language extractor cold-start motivates extractor caching.** Swift in particular: `SwiftSyntax` builds via SPM take 30–90s cold, and dwarf the Node-based extractor's startup. Two mitigations: (1) cache the resolved/built `SwiftSyntax` artifacts as an Actions cache keyed on extractor version (recovery: ~5s); (2) longer-term, pre-build language extractor binaries and host them in the substrate itself (`r2://wxyc-catalogs/_extractors/<lang>-<version>/<arch>/extractor`), download in the action (~2s). **Recommend (1) for Phase 0, (2) as a Phase 3 optimization.**
- **Default-branch detection.** Hard-coding `main` breaks on `master`-named repos. Detect via `gh api repos/${{ github.repository }} --jq .default_branch` once at action setup; parametrize triggers via repo-level workflow.
- **Catalog size ceiling for the single-PUT upload path.** Case study repo: ~600 entries, ~120KB. Largest plausible repo: ~5000 entries, ~1MB. R2 single PUT supports up to 5GB. No ceiling concern at this scale; flag if any repo's catalog exceeds 10MB.

## 10. Sub-ticket boilerplate

**Title:** `Per-repo CI publication — extract catalog on push, upload to substrate`

**Direction:**

> Each of the org's ~30 sibling repos installs a one-line GitHub Actions workflow that, on push to the default branch and via a nightly safety-net cron, runs the language-appropriate extractor and uploads the resulting `catalog-<sha>.json` to a central Cloudflare R2 bucket with content-addressable keys. A `latest.json` mutable pointer per repo plus a centrally-reconciled `index.json` (regenerated from bucket listing, not per-write) form the substrate that #118's cross-repo queries consume. The Action is built as a thin wrapper around a shared `audit-core` composite (co-owned with #120) so language detection, toolchain install, and extractor invocation live in one place — when the catalog contract changes, one tag bump, not thirty workflow edits. OIDC-to-Cloudflare authentication eliminates long-lived secrets; concurrency-collapse on push bursts plus per-SHA immutability keep the substrate safe under any commit cadence.

## Key file references

- [`/Users/jake/Developer/code-audit-pipeline/CLAUDE.md`](../../CLAUDE.md) — operational conventions (1000-line PR cap, gitignore, scratch directory)
- [`/Users/jake/Developer/code-audit-pipeline/docs/pipeline-contract.md`](../pipeline-contract.md) — schema baseline (the metadata-wrapping in this brief extends, doesn't replace, this contract)
- [`/Users/jake/Developer/code-audit-pipeline/extractors/typescript/type-catalog.mjs`](../../extractors/typescript/type-catalog.mjs) — reference extractor, validates CLI contract
- [`/Users/jake/Developer/code-audit-pipeline/docs/case-study.md`](../case-study.md) — sub-2s extraction time, ~280-line extractor, basis for the wall-clock budget
- [`/Users/jake/Developer/code-audit-pipeline/docs/future-directions.md`](../future-directions.md) §3 — substrate scale-dependency that motivates the reconcile-from-listing choice
