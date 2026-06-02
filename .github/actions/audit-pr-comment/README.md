# audit-pr-comment

Composite GitHub Action that posts a sticky "structural impact" comment on every PR. Wraps the [audit-core](../audit-core/README.md) composite plus `code-audit report --mode pr-comment` plus the [`marocchino/sticky-pull-request-comment@v2`](https://github.com/marocchino/sticky-pull-request-comment) poster.

For end-user setup, see [`docs/integrations/github-action.md`](../../../docs/integrations/github-action.md). This README documents the action's contract for callers who want to wrap it themselves (instead of using the [`pr-comment-reusable.yml`](../../workflows/pr-comment-reusable.yml) one-screen entrypoint).

## What it does

1. Runs `audit-core` against the PR's HEAD checkout to produce `.audit/catalogs/`.
2. Resolves the touched-file set: `gh pr view --json files` filtered per-language via the canonical walker (TypeScript) or extension-glob fallback (Swift/Go/Python/Rust/file-hashes).
3. Renders the comment body via `code-audit report --mode pr-comment` — sticky marker on line 1, per-section size cap, fail-quiet on pipeline-internal errors.
4. Posts via `marocchino/sticky-pull-request-comment@v2`, which edits in place across force-pushes (matched by the marker substring).
5. Always uploads the rendered `comment.md` as a step-summary detail + workflow artifact (via the reusable workflow's upload step) for debugging.

## Inputs

| Name | Default | Purpose |
|---|---|---|
| `root` | `.` | Repo root to scan; forwarded to audit-core. |
| `audit-binary-version` | `v1` | code-audit release tag. See [audit-core README](../audit-core/README.md) for resolution semantics. |
| `languages` | `''` (auto) | Comma-separated language override; forwarded to audit-core. |
| `include-tests` | `false` | Forwarded to audit-core. |
| `include-file-hashes` | `true` | Forwarded to audit-core. Keep on so file-hashes catalog rows participate in touched-file matching. |
| `marker` | `code-audit-pipeline-v1` | Sticky comment marker. Forwarded to `code-audit report --marker` AND marocchino's `header:`. |
| `size-cap-bytes` | `60000` | Body cap; min `1024` (enforced by `code-audit report`). |
| `on-extraction-failure` | `quiet` | `quiet` exits 0 with a diagnostic body; `loud` exits non-zero. |
| `audit-root` | runner temp | Where audit-core writes `.audit/`. |
| `github-token` | `${{ github.token }}` | Forwarded to audit-core (release download) and marocchino (sticky comment post). |
| `skip-comment` | `false` | When `true`, render the comment but skip the marocchino post. Used by the selftest. |

## Outputs

| Name | Purpose |
|---|---|
| `comment-path` | Absolute path to the rendered `comment.md`. |
| `touched-count` | Number of repo-relative paths in the resolved touched set. |
| `posted` | `true` iff the marocchino step ran (and did not skip). |
| `exit-code` | Exit code from `code-audit report`. |

## Caller requirements

- **Checkout already done.** This composite does NOT run `actions/checkout`; the caller is responsible for placing the PR HEAD at `$GITHUB_WORKSPACE`.
- **Permissions.** The calling job must grant `contents: read` (for checkout) and `pull-requests: write` (for marocchino's sticky-comment post). Forks raising PRs against the base repo do NOT receive a token with `pull-requests: write` — the marocchino step skips gracefully.
- **Concurrency.** Recommended at the calling-workflow level: `concurrency: { group: code-audit-pr-comment-${{ github.event.pull_request.number }}, cancel-in-progress: true }`. The [reusable workflow](../../workflows/pr-comment-reusable.yml) sets this for you.

## Touched-file resolution

The action runs [`scripts/resolve-touched.sh`](scripts/resolve-touched.sh) to produce a per-PR touched-file JSON array. Per-language:

| Language | Method | Notes |
|---|---|---|
| TypeScript | `extractors/typescript/type-catalog.mjs --list-relevant` | Canonical walker; matches what the extractor would index byte-for-byte. |
| Swift | Extension globs (`.swift`) + skip `.build/`, `Pods/`, `DerivedData/`, etc. | Approximation; canonical walker pending follow-up to add `--list-relevant`. |
| Go | Extension globs (`.go`) + skip `vendor/`. | Approximation. |
| Python | Extension globs (`.py`) + skip `__pycache__/`, `.venv/`, etc. | Approximation. |
| Rust | Extension globs (`.rs`) + skip `target/`. | Approximation. |
| file-hashes | Passthrough — every input path is a candidate. | The downstream `code-audit report --touched` intersects against catalog member paths, so over-inclusion is benign. |

Cross-language `--list-relevant` is tracked as a follow-up; the extension-glob fallback is documented as the MVP state in [`docs/integrations/github-action.md`](../../../docs/integrations/github-action.md#cross-language-touched-file-resolution-status).

## Fixture-mode touched input

For selftests and local dry-runs, set `TOUCHED_RAW` in the calling step's env to a newline-separated path list. `resolve-touched.sh` honors it and skips the `gh pr view` call. The composite forwards env from the workflow step into the script's environment, so:

```yaml
- uses: ./.github/actions/audit-pr-comment
  env:
    TOUCHED_RAW: |
      src/foo.ts
      src/bar.tsx
```

is sufficient. Real consumer workflows leave `TOUCHED_RAW` unset and rely on `gh pr view`.

## See also

- [`pr-comment-reusable.yml`](../../workflows/pr-comment-reusable.yml) — one-screen consumer entrypoint.
- [`docs/integrations/github-action.md`](../../../docs/integrations/github-action.md) — end-user setup, troubleshooting, license notes.
- [`docs/pipeline-contract.md`](../../../docs/pipeline-contract.md) §"CLI contract" — the `--mode pr-comment` flag surface this composite consumes.
- [`docs/plans/123-implementation.md`](../../../docs/plans/123-implementation.md) — design + rationale.
