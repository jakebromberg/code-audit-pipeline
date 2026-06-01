# `audit-core` composite action

The one-place-it-lives substrate for code-audit-pipeline's CI consumers. Detect language(s), install toolchain(s) + the `code-audit` binary, run every applicable extractor, emit the resulting `.audit/catalogs/` directory as an output.

Both #154 (per-repo CI publication, uploads catalogs to R2) and #123 (PR-comment Action, diffs catalogs across the PR) consume this composite. When the catalog contract changes, one tag bump here updates every downstream consumer.

## Use it

The one-screen caller — applicable to most sibling repos in the org — looks like this:

```yaml
name: Publish catalog
on:
  push: { branches: [main] }
  schedule: [{ cron: '17 7 * * *' }]
  workflow_dispatch:
permissions: { contents: read, id-token: write }
jobs:
  publish:
    uses: jakebromberg/code-audit-pipeline/.github/workflows/publish-catalog-reusable.yml@v1
    secrets: inherit
```

Lower-level callers (e.g. #123's PR-comment Action) use the composite directly:

```yaml
jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - id: audit
        uses: jakebromberg/code-audit-pipeline/.github/actions/audit-core@v1
        with:
          root: '.'
      - run: ls -la "${{ steps.audit.outputs.catalogs-dir }}"
```

## Inputs

| Name | Default | Purpose |
|---|---|---|
| `root` | `.` | Repo root to scan. |
| `languages` | `''` (auto-detect) | Comma-separated override. When empty, marker files at `root` decide. |
| `binary-version` | `v1` | code-audit release tag. `v1`/`v2` resolve to the newest matching release. `latest` tracks HEAD. `build-from-source` builds from the action checkout (only when this repo's own CI is the caller). |
| `include-tests` | `false` | Pass `--include-tests` to every extractor. |
| `include-file-hashes` | `true` | Run the polyglot file-hashes extractor on top of language-specific ones. Cheap (no toolchain) and downstream queries assume it. |
| `audit-root` | `''` (= `root`) | Where to place `.audit/`. Override to put the cache on a separate prefix (e.g. for cross-job artifact sharing). |
| `github-token` | `${{ github.token }}` | Used for `gh release download`. Override on private repos or IP-restricted orgs. |

## Outputs

| Name | Example | Purpose |
|---|---|---|
| `catalogs-dir` | `/home/runner/work/foo/foo/.audit/catalogs` | Absolute path; feeds directly into `publish-catalog.sh --catalogs-dir`. |
| `languages-detected` | `typescript,swift` | Stable, deduped, ordered list. Empty string when nothing matched. |
| `binary-version-used` | `v1.4.2` | Resolved tag after major-pin expansion. |
| `requires-macos` | `true` / `false` | True iff `swift` is in the detected set. Use it to gate a follow-up job onto `macos-latest`. |

## Marker-based language detection

`detect-languages.sh` looks at the repo root only — markers in subdirectories don't count. The priority list (also the output order):

| Language | Markers (any one) |
|---|---|
| `typescript` | `tsconfig.json`, `package.json` |
| `swift` | `Package.swift` |
| `go` | `go.mod` |
| `python` | `pyproject.toml`, `setup.py` |
| `rust` | `Cargo.toml` |

`typescript` matches on bare `package.json` even when the repo is JS-only. The TypeScript extractor produces an (empty or small) catalog in that case; the cost is bounded and the detection rule stays simple. Override via the `languages` input if needed.

The `polyglot` file-hashes extractor runs unconditionally (unless `include-file-hashes: false`). Downstream queries assume per-file hashes are present.

## Polyglot behavior + runner cost

A repo with both TypeScript and Swift produces `languages-detected=typescript,swift` and runs *both* extractors in the order TS → Swift. Two things to be aware of when wiring this into a workflow:

1. **Composites inherit the caller's runner.** This action does not set `runs-on:`. A repo that needs Swift must run on `macos-latest` (or a macOS self-hosted runner). A TS-only repo runs cheaper on `ubuntu-latest`.
2. **Recommended gating pattern for mixed repos:** run a single-step detection job first, then dispatch the real audit job onto the right runner using `needs.<detect-job>.outputs.requires-macos`. Example:

```yaml
jobs:
  detect:
    runs-on: ubuntu-latest
    outputs:
      requires-macos: ${{ steps.d.outputs.requires-macos }}
    steps:
      - uses: actions/checkout@v6
      - id: d
        run: |
          langs="$(.github/actions/audit-core/scripts/detect-languages.sh .)"
          case ",$langs," in *,swift,*) m=true ;; *) m=false ;; esac
          echo "requires-macos=$m" >> "$GITHUB_OUTPUT"

  audit:
    needs: detect
    runs-on: ${{ needs.detect.outputs.requires-macos == 'true' && 'macos-latest' || 'ubuntu-latest' }}
    steps:
      - uses: actions/checkout@v6
      - uses: jakebromberg/code-audit-pipeline/.github/actions/audit-core@v1
```

3. **Polyglot TS+Swift runs the whole composite on macOS** when called from a single-runner workflow. Slower toolchain provisioning + more expensive runner minutes. Splitting the languages across two jobs (sharing catalogs via `actions/upload-artifact`) is a follow-up — track in #154's follow-on issues, not blocking.

## Version pinning

| Input value | Resolves to | When to use |
|---|---|---|
| `v1` (default) | newest `v1.*` release | Default. Get patches automatically, never a breaking change. |
| `v1.4.2` | exactly `v1.4.2` | Reproducibility-critical contexts (post-mortems, replays). |
| `latest` | newest release of any major | Bleeding-edge — accept that a major bump can break your job overnight. |
| `build-from-source` | binary built from the action's own checkout | Only when this repo is the caller (CI for this repo). Not a valid choice for sibling consumers. |

## Troubleshooting

- **`audit-core: no release tags matching v1.*`** — the binary has not shipped any `v1.x` releases yet. Set `binary-version: latest` until the first v1 cut, or `build-from-source` if you're running this repo's own CI.
- **`code-audit: extract <name>: ...`** — the extractor exited non-zero. Look one log line up; `code-audit` propagates the extractor's stderr including its `setup_hint` from `manifest.toml`.
- **`expected catalogs dir not found`** — either every extractor failed silently, or `--audit-root` was passed a path the runner can't write to. Re-run with the default `audit-root` to confirm.
- **macOS runner used for a TS-only repo** — the caller workflow is hard-coded to `macos-latest`. Use the gating pattern under "Polyglot behavior" above.

## Tests

- `pipeline/_tests/test_audit_core.sh` — hermetic unit tests for `detect-languages.sh`. Runs in <1s.
- `.github/workflows/audit-core-selftest.yml` — end-to-end self-test workflow that runs this composite against the `code-audit-pipeline` checkout itself (build-from-source mode). The only test that exercises the composite as a whole; release-download mode is validated by PR 2's first real consumer.
