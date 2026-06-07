# Pre-commit hook integration

The `code-audit-clusters` pre-commit hook surfaces the three cluster signals — exact duplicates, name collisions, and near-duplicates — at `git commit` time. It runs locally, scoped to the staged TypeScript file set, against a cached full-repo catalog under `.git/audit/`.

This is the second of three integrations described in parent issue [#120](https://github.com/jakebromberg/code-audit-pipeline/issues/120). The first is the [GitHub Action PR-comment integration](https://github.com/jakebromberg/code-audit-pipeline/issues/123); the hook is sequenced LAST of the three. It mirrors the Action's signal locally, so contributors see the same warning shape earlier in their workflow.

## Install

Add the hook to your repo's `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/jakebromberg/code-audit-pipeline
    rev: <release-tag>
    hooks:
      - id: code-audit-clusters
```

Then install the hook into your local checkout:

```bash
pre-commit install
```

The `pre-commit` framework will fetch this repo, install `hooks/pre-commit-audit.mjs` in its managed Node environment, and wire it into `.git/hooks/pre-commit`. No manual extractor bootstrap required.

If you don't have the `pre-commit` framework installed, follow the upstream install instructions at https://pre-commit.com.

> The hook is NOT auto-installed when you run `npm install` elsewhere in the org. Hidden git-hook installation is surprise behavior and breaks consent. Adopt explicitly via the `pre-commit install` step above.

## What it does, at commit time

1. Pipes the staged file list through the type extractor's `--list-relevant` predicate (issue [#159](https://github.com/jakebromberg/code-audit-pipeline/issues/159)). Non-TypeScript, vendored, test-bucket, and dotdir paths drop out. So do paths marked `linguist-generated=true` in `.gitattributes`.
2. If the kept set is empty, the hook exits 0 silently. This is the common path for prose-only commits.
3. Otherwise: checks `.git/audit/catalog.json` and `catalog.meta.json` for freshness. The cache is valid iff every relevant repo file's mtime is at-or-before its cached entry, no new relevant file has appeared, and the cache is less than 24 hours old.
4. On a cache miss, rebuilds the catalog by re-running the extractor against the full repo. If the estimated cold-path cost would blow the 5-second wall-clock budget, the rebuild is spawned **detached**, the hook prints `code-audit: cache rebuild in background`, and exits 0 immediately. The next commit benefits.
5. Runs the three cluster queries (`pipeline/queries/exact-duplicates.jq`, `name-collisions.jq`, `near-duplicates.jq`) against the catalog in JSONL mode via `jq`. Filters to rows whose cluster (or pair endpoint) lands on a staged file.
6. Writes the full report to `.git/audit/last-report.md` and prints a 3-line digest to stderr.
7. Exits 0.

## Configuration

The hook is configured by environment variables, set in your shell or in the pre-commit framework's `env` block:

| Variable | Default | Meaning |
|---|---|---|
| `CODE_AUDIT_TIMING` | unset | When `1`, appends one timing line per invocation to `.git/audit/timing.log`. Format: `<ISO timestamp> total_ms=… verdict=… cache=… staged=… exact=… name-coll=… near=…`. |
| `CODE_AUDIT_INCLUDE_TESTS` | unset | When `1`, the `--list-relevant` predicate keeps test/spec/fixture/mock paths. Matches the extractor's `--include-tests` flag. |
| `CODE_AUDIT_NEAR_DUP_THRESHOLD` | `0.7` | Jaccard threshold passed to `near-duplicates.jq` via `--argjson threshold`. Lower for broader recall, higher to focus only on near-exact matches. |
| `CODE_AUDIT_EXTRACTOR` | bundled `extractors/typescript/type-catalog.mjs` | Path to the extractor entrypoint. Override only for advanced testing. |
| `CODE_AUDIT_QUERIES_DIR` | bundled `pipeline/queries/` | Directory of cluster queries. Override only for advanced testing. |

## Cache layout

All hook state lives under `.git/audit/`:

```
.git/audit/
├── catalog.json          # full-repo catalog, schema v1.1
├── catalog.meta.json     # { schema_version, extractor_version, mtimes, built_at }
├── last-report.md        # the most recent cluster digest (markdown)
└── timing.log            # opt-in timing log (see CODE_AUDIT_TIMING)
```

These are all under `.git/`, so they are automatically excluded from your repo. The hook will rebuild any missing file from scratch.

## Non-blocking by design

The hook **always exits 0** — on cluster hits, on extractor errors, on `jq` errors, on wall-clock-budget overruns, on uncaught exceptions. This is intentional, not an oversight.

Per the parent ticket [#120](https://github.com/jakebromberg/code-audit-pipeline/issues/120) and this ticket's [§Non-goals](https://github.com/jakebromberg/code-audit-pipeline/issues/124):

> **Not blocking.** Exit 0 always — even on cluster hits, extractor errors, or budget overruns. Pre-commit hooks that block get bypassed; non-blocking hooks get read.

A blocking hook with even a 1% false-positive rate trains contributors to reach for `git commit --no-verify` reflexively, and once that habit takes hold the hook stops being read entirely. A non-blocking warning digest stays in the field of view, and contributors who want the deeper check have the GitHub Action ([#123](https://github.com/jakebromberg/code-audit-pipeline/issues/123)) running on every PR.

## Troubleshooting

### "Nothing happened on my commit"

Confirm the hook is installed:

```bash
pre-commit run code-audit-clusters --hook-stage commit --all-files
```

If that exits 0 without output, your staged change didn't include any relevant TypeScript files (the most common reason). Try staging a `.ts` source change and running again.

### "The cache is stale even though I didn't change anything"

The 24-hour TTL fires regardless of mtime, so the first commit each day rebuilds the catalog. This is by design — it defends against editor mtime quirks and filesystem clock skew.

### "The digest says `cache rebuild in background`"

Your repo grew past the 5-second cold-path estimate (~200 relevant TypeScript files). The first commit triggers a detached rebuild and exits immediately; the next commit hits a fresh cache. If this happens on every commit, your repo's relevant-file count grew unexpectedly — check `git ls-files | node extractors/typescript/type-catalog.mjs --list-relevant | wc -l`.

### "I want to bypass for one commit"

`git commit --no-verify` skips all pre-commit hooks. Use it. The hook is non-blocking so you should rarely need this, but the escape hatch exists.

### "I want to disable the hook entirely"

Remove the `code-audit-clusters` entry from `.pre-commit-config.yaml` and run `pre-commit install` again.

### "I want to invalidate the cache manually"

```bash
rm -rf .git/audit
```

The next commit rebuilds from scratch.

## Performance

The hook's measured wall-clock budgets, per [issue #124 §non-functional](https://github.com/jakebromberg/code-audit-pipeline/issues/124):

| Path | Target | Hard ceiling |
|---|---|---|
| Hot (cache hit, ≤5 staged) | p50 < 500ms, p95 < 1.5s | 5s wall-clock |
| Cold (cache miss, ~600-entry catalog) | < 5s | 5s wall-clock (else detached) |

The cold-path wall-clock guard is enforced via a `setTimeout` that fires `process.exit(0)` if the synchronous path hasn't finished within 5 seconds. The detached-rebuild fallback for estimated overruns kicks in before that, but the guard is the last-ditch defense against extractor pathology.

## What the hook does NOT do

- **It does not block your commit.** Ever.
- **It does not call out to the network.** No GitHub API, no telemetry, no auto-update.
- **It does not warn about non-TypeScript files.** TypeScript-only at MVP, per the parent ticket's scope.
- **It does not check whether an Action-bearing PR is already open** (would require network).
- **It does not auto-install on `npm install` of the extractor package.**
- **It is not a snapshot consumer** — operates on a single cached catalog, not a snapshot history. No dependency on [#117](https://github.com/jakebromberg/code-audit-pipeline/issues/117).
