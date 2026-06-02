# GitHub Action — PR structural-impact comments

End-user setup for the `code-audit` PR-comment Action, which posts a sticky comment on every pull request listing the structural clusters (exact duplicates, name collisions, cross-package shadows, near-duplicates, etc.) whose members include files the PR touches. The comment is updated in place across force-pushes — no comment-spam churn.

This document covers consumer-repo setup, the design decisions a future implementer needs to know about, and troubleshooting. For the action's own input/output contract, see [`.github/actions/audit-pr-comment/README.md`](../../.github/actions/audit-pr-comment/README.md). For the rendering flag surface this action consumes, see [`docs/pipeline-contract.md`](../pipeline-contract.md) §"CLI contract".

Related issues: [#123](https://github.com/jakebromberg/code-audit-pipeline/issues/123) (this Action), [#120](https://github.com/jakebromberg/code-audit-pipeline/issues/120) (parent Dev-flow integrations), [#154](https://github.com/jakebromberg/code-audit-pipeline/issues/154) (sibling publish-catalog Action).

## 1. What it does

For every PR raised against the configured base branches, the Action:

1. Builds a code-audit catalog of the PR's HEAD checkout (TypeScript / Swift / Go / Python / Rust / file-hashes, as detected).
2. Resolves the touched-file set (`gh pr view --json files` → per-language walker).
3. Runs every cluster query in the pipeline, filters clusters to those whose members include a touched file.
4. Renders a markdown comment body capped at 60 KB and posts (or edits in place) a sticky comment via [`marocchino/sticky-pull-request-comment@v2`](https://github.com/marocchino/sticky-pull-request-comment).

A clean PR (no cluster touched) gets a one-line "No structural impact" body so the sticky comment still updates and reads sensibly. Pipeline-internal errors (extractor crash, query bug) collapse to a single diagnostic line with the marker, so the comment surface never goes stale and the PR is never blocked on pipeline plumbing.

## 2. Quick start

Copy [`.github/templates/pr-comment.yml.example`](../../.github/templates/pr-comment.yml.example) to `.github/workflows/code-audit-pr-comment.yml` in your repo. The defaults pin to `code-audit-pipeline@v1` (major-pin — patches roll forward automatically). The template lives at:

```yaml
name: code-audit (PR comment)
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
permissions:
  contents: read
  pull-requests: write
jobs:
  audit:
    uses: jakebromberg/code-audit-pipeline/.github/workflows/pr-comment-reusable.yml@v1
```

That's the entire install. Two things to verify before the first PR:

1. **Workflow permissions toggle.** Repo Settings → Actions → General → Workflow permissions must be set to *"Read and write permissions"*. The default *"Read repository contents and packages permissions"* denies `pull-requests: write`, and the marocchino step will fail with a 403 on the first run. See §6 below.
2. **Org-level permissions.** If your org has *Settings → Actions → General → Workflow permissions* set to a stricter default, the repo-level toggle above can't override it. Talk to your org admin to whitelist this repo. The failure mode is identical to (1).

## 3. Configuring per-project defaults

v1 of this action does not read a project-level config file — every setting is expressed as a workflow input in the consumer's `.github/workflows/code-audit-pr-comment.yml`. The `audit-binary-version: build-from-source` value is reserved for this pipeline's own selftest and is rejected by the composite when invoked outside this repo.

### Monorepo example

```yaml
# .github/workflows/code-audit-pr-comment.yml
jobs:
  audit:
    uses: jakebromberg/code-audit-pipeline/.github/workflows/pr-comment-reusable.yml@v1
    with:
      languages: typescript,swift,go
      include-file-hashes: true
      # Override the runner — Swift needs macOS.
      runner: macos-latest
```

### Polyrepo example

```yaml
# .github/workflows/code-audit-pr-comment.yml
jobs:
  audit:
    uses: jakebromberg/code-audit-pipeline/.github/workflows/pr-comment-reusable.yml@v1
    with:
      languages: typescript
```

A `.audit/config.yml` for project defaults is tracked as a follow-up — once shipped, it will sit between workflow inputs (highest priority) and composite defaults (lowest), letting repo maintainers commit shared defaults without every workflow author re-specifying them.

## 4. The `base.sha` cache-key pitfall (relevant to v2)

> **v1 of this action does NOT cache anything.** The composite computes HEAD catalogs only. This section is documented now so the baseline-diff follow-up (which WILL add caching) can't relitigate the design.

A future iteration will add baseline-catalog caching to skip recomputing `.audit/catalogs/` for the PR base when nothing under the base SHA's tree has changed. The cache key MUST be `${{ github.event.pull_request.base.sha }}`, NOT `${{ github.base_ref }}`.

**Why.** `github.base_ref` is the branch name (`main`, `develop`, etc.). Branches advance. A PR opened against `main` at commit `abc123`, then left open for two days while four other PRs land on `main` (advancing it to `def456`), would — with a `base_ref`-keyed cache — read the now-stale `main`-keyed catalog and surface phantom diffs against the wrong baseline.

`github.event.pull_request.base.sha` resolves to the actual base commit at the time the PR was opened, regardless of how `main` advances. Cache reads always hit the catalog for that exact commit; a cache miss triggers a recompute against `git worktree add /tmp/audit-base <base.sha>`.

The acceptance criteria for the baseline-diff follow-up ticket:

- Cache key is `audit-catalog-${base.sha}-${runner.os}-${binary-version}`.
- Cache miss triggers `git worktree add /tmp/audit-base <base.sha>` + audit-core re-run against that worktree.
- A regression test asserts the key tracks `base.sha`, not `base.ref`. The test simulates "main advances mid-PR" via a synthetic two-phase run.

## 5. ACSL v1.4 inheritance

This pipeline is licensed under the [Anti-Capitalist Software License v1.4](https://anticapitalist.software/). Consumer repos that import the composite or reusable workflow are bound by the same license terms for any code that exercises this pipeline's substrate.

Practically:

- **Permitted:** individuals, non-profits, educational institutions, worker-owned cooperatives.
- **Not permitted:** capitalist organizations, law enforcement, military.

If your org doesn't match the permitted list, do not adopt this Action. The Action installs the `code-audit` binary into your runner and shells out to it; that's a use of the licensed substrate.

The `marocchino/sticky-pull-request-comment` dependency is MIT-licensed (compatible). No other action-step dependency carries a copyleft-restrictive license.

## 6. Org-level workflow permissions

The marocchino sticky-comment poster requires `pull-requests: write`. The Action declares this in its `permissions:` block, but GitHub gates this on two settings:

1. **Repo level.** Settings → Actions → General → Workflow permissions → "Read and write permissions". The default ("Read repository contents and packages permissions") denies write — first-time installers hit a 403 here.
2. **Org level.** Org Settings → Actions → General → Workflow permissions. If set to a stricter default (e.g. "Read repository contents permissions"), the repo-level toggle CANNOT override it. The org admin must whitelist the repo or relax the org default.

The failure mode is identical for both: marocchino's step errors out with `Resource not accessible by integration` and exit code 1. The render artifact still uploads (good for debugging), but no comment is posted.

If you can't get org-level permissions changed, an alternative is to switch to a personal access token (PAT) with `repo` scope, stored as a repo secret. Pass it via the `github-token` input — but PATs are tied to a human user and rotate when that user leaves, so the workflow-permissions toggle is strongly preferred.

## 7. marocchino dependency note

[`marocchino/sticky-pull-request-comment@v2`](https://github.com/marocchino/sticky-pull-request-comment) is MIT-licensed. Confirmed in the issue's open-questions resolution. The action's design uses substring matching on the body's `<!-- <header> -->` line to identify the existing sticky comment to update; this is reliable across force-pushes and edit-events because the marker survives every render.

The `header:` input must match the body's marker exactly. The composite forwards the same `marker:` input to both `code-audit report --marker` (which renders the marker line) and marocchino's `header:` (which scans for it) — mismatched values would cause every run to create a new comment instead of editing in place. Don't override one without the other.

## 8. Cross-language touched-file resolution status

The touched-file set is per-language — each language's walker decides which paths it would index, and `resolve-touched.sh` runs the appropriate filter for each language audit-core detected.

| Language | Method | Status |
|---|---|---|
| TypeScript | `extractors/typescript/type-catalog.mjs --list-relevant` | Canonical walker — matches what the extractor would index byte-for-byte. |
| Swift | Extension globs (`.swift`) + skip `.build/`, `.swiftpm/`, `Pods/`, `DerivedData/`, `build/`, `node_modules/`. | Approximation. |
| Go | Extension globs (`.go`) + skip `vendor/`, `node_modules/`. | Approximation. |
| Python | Extension globs (`.py`) + skip `.venv/`, `venv/`, `__pycache__/`, `.tox/`, `build/`, `dist/`, `node_modules/`. | Approximation. |
| Rust | Extension globs (`.rs`) + skip `target/`, `node_modules/`. | Approximation. |
| file-hashes | Passthrough — every raw input path is a candidate. | The downstream `code-audit report --touched` intersects against catalog member paths, so over-inclusion never produces false-positive impacts. |

Cross-language `--list-relevant` (canonical walker on Swift / Go / Python / Rust / file-hashes) is tracked as a follow-up. Until that lands:

- The Swift / Go / Python / Rust filters MAY over-include files the language's extractor would actually skip (e.g. a `.go` file under a directory the Go extractor's walker considers test-only when `INCLUDE_TESTS=false`).
- Over-inclusion is benign: paths not present in any catalog can't intersect with any cluster member, so they never produce false-positive impacts.
- Under-inclusion CAN happen if the fallback's skip-list is more aggressive than the extractor's. The plan accepts this risk; the follow-up closes the gap.

## 9. Troubleshooting

### Empty comment ("No structural impact" body)

Expected when no cluster query found a touched-file match. Either the PR didn't touch anything the catalogs index (config-only change, docs-only change with `include-file-hashes=true` returning no MD/YAML clusters), or the catalogs themselves don't yet have clusters in the touched area. Not an error.

### Fail-quiet diagnostic ("> code-audit: report unavailable …")

The pipeline failed somewhere — extractor crash, query syntax error, render bug. The PR is not blocked. The full diagnostic body is in the workflow run logs (visible to anyone with read access to the repo). The render artifact is uploaded as `code-audit-pr-comment` even on this path.

Common causes:

- **Catalog file missing** — audit-core's extract step errored before producing `.audit/catalogs/<lang>-catalog.json`. Check the audit-core step log for the underlying extractor's stderr.
- **Catalog file malformed** — extractor was killed mid-write (OOM, runner timeout), or the extractor itself has a bug that emitted invalid JSON. The catalog file's content is in the audit-core step log if `set -x` is on.
- **jq syntax error in a bundled query** — a query shipped in this release has a bug; file an issue and pin to the previous `v1.x.y` release via `audit-binary-version` until a fix lands.

### Comment isn't sticky (new comment per run)

The `marker:` input must match between renders. If you change `marker:` between two runs of the same PR, the second run won't find the first run's comment (marocchino's substring scan looks for the new marker, not the old one). Default is `code-audit-pipeline-v1` — leave it unless you have a specific need to namespace per-team or per-pipeline-version.

### Force-push convergence

marocchino's sticky behavior means every push to the PR triggers a re-render and an edit-in-place of the comment. The workflow-level `concurrency.cancel-in-progress: true` cancels any in-flight run when a new push lands, so the final comment converges to the latest push's state. For rapid force-pushes (5+ in 60 seconds), expect ~90s of churn before the comment settles on the final state.

### Forks raising PRs against the base repo

Forks do NOT receive a token with `pull-requests: write` by default — GitHub's policy. The marocchino step will skip and the workflow logs will show a 403. The render artifact still uploads. To enable comments on fork-PRs, switch your workflow to `pull_request_target` (instead of `pull_request`) — but this changes the security model: `pull_request_target` runs with the BASE repo's secrets and a base-branch checkout, which is dangerous if combined with `actions/checkout` of the PR's HEAD without manual review. Read [GitHub's `pull_request_target` security guide](https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows#pull_request_target) before considering this.

### Missing baseline cache after main rebase

Not applicable to v1 (no cache). When the baseline-diff follow-up lands, this section will document the recovery: `git worktree add /tmp/audit-base <base.sha>` works against any commit reachable from the default branch's reflog, so a single cache miss recomputes correctly without ceremony.

### `--mode pr-comment` errors on tiny `--size-cap-bytes`

`code-audit report` rejects `--size-cap-bytes` below 1024 with exit 2. The minimum exists so the fallback paths (truncation footer, fail-quiet body) can fit within the cap. The default 60000 is safe; only override if you have a specific need to test the cap behavior (the selftest exercises this).
