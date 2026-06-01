# Plan — #159: Extractor `--list-relevant` flag

Parent ticket: [#159 — Extractor: --list-relevant flag (shared prerequisite for #123 and #124)](https://github.com/jakebromberg/code-audit-pipeline/issues/159). Hard prerequisite for #123 (PR-comment Action) and #124 (pre-commit hook).

## Goal

Surface the TypeScript extractor's existing walk-predicate as a pure query: given a list of candidate paths on stdin or argv, print the subset the walker would index. No parse, no catalog, no I/O beyond reading `.gitattributes` for linguist overrides.

## Why this scope shape

The downstream consumers (#123, #124) both need to ask "would the extractor look at this file?" without paying the full extraction cost. Re-implementing the predicate in each consumer drifts; exposing it as a flag keeps the extractor authoritative.

Filed standalone (not bundled into #123) so #123 and #124 can land in either order once this ships, and so this change is reviewable in isolation against the existing walk semantics.

## Discrepancy worth resolving up front

The issue body describes the predicate as:

> extension match (`.ts`, `.mts`, `.cts`, `.tsx`), not under a skip-dir (`node_modules`, `dist`, `build`, `coverage`, `tests`, any `.dotdir`), not matching test/spec patterns unless `--include-tests` is passed, not marked `linguist-generated` in `.gitattributes`.

The current walk in [`extractors/typescript/type-catalog.mjs:144-167`](../../extractors/typescript/type-catalog.mjs) actually does:

| Behavior | Issue spec | Current walker |
|---|---|---|
| Extensions `.ts` `.tsx` `.mts` `.cts` | yes | yes (line 160) |
| Skip-dirs `node_modules`, `dist`, `build`, `coverage` | yes | yes (line 93) |
| Skip any dotdir | yes | yes (line 156) |
| Skip `tests/` as a skip-dir | yes | **no** — extracts test files; row carries `is_test` flag |
| `--include-tests` opt-in | yes | **no** flag — tests always extracted |
| Skip `linguist-generated` per `.gitattributes` | yes | **no** — `.gitattributes` is not read |

The issue's "Predicate: Identical to the in-extractor walk" sentence is authoritative; the bulleted list below it describes the *intended* (not actual) walker. Three options:

**A. Mirror current walk exactly.** `--list-relevant` keeps every `.ts/.tsx/.mts/.cts` file that's not under a skip-dir or dotdir, including tests. No `--include-tests` flag, no `.gitattributes` read. Consumers (#123/#124) get the predicate the catalog already enforces — no behavioral surprise.

**B. Mirror current walk + post-filter test paths.** Extend `isRelevantPath` with an `includeTests` opt that wraps `isTestPath` (already exported from [`_lib/paths.mjs`](../../extractors/typescript/_lib/paths.mjs)). Default `includeTests=false`. The walker continues to extract tests; the flag's `--include-tests` default drops them on the *query side* only. This keeps the catalog stable but gives #123/#124 a saner default (test files are not where structural drift lives).

**C. Bring walker and flag in lock-step with the issue spec.** Add `--include-tests` to extraction, default-off; add `.gitattributes` linguist-generated handling. This *changes* what every consumer of `type-catalog.mjs` indexes today.

**Recommendation: B.** Lowest blast radius for a small ticket. The walker's behavior is unchanged (no catalog drift, no downstream test breakage in `pipeline/_tests/`); the flag exposes a *test-aware* version that's strictly a superset query against the same path set the walker visits. `.gitattributes` linguist-generated handling is deferred to a follow-up — none of the case-study corpus exercised it, and it can be added without breaking the predicate's API.

Documenting C as a follow-up issue (linguist-generated handling for both the walker and the predicate query) keeps the issue-spec promise intact without bundling scope creep into #159.

## Design

### Exported predicate

Add to `extractors/typescript/type-catalog.mjs` (or extract to `_lib/walk-predicate.mjs` if the function-catalog walk should call it too — see follow-up):

```js
export function isRelevantPath(relPath, { includeTests = false } = {}) {
  // Reject absolute paths — caller must pass paths relative to --root,
  // matching how the walker reports them.
  if (relPath.startsWith('/')) return false;

  const segments = relPath.split('/');

  // Reject any segment matching a skip-dir or dotdir.
  for (let i = 0; i < segments.length - 1; i++) {
    const seg = segments[i];
    if (seg.startsWith('.')) return false;
    if (SKIP_DIRS.has(seg)) return false;
  }

  // Extension match on the basename.
  const basename = segments[segments.length - 1];
  if (!/\.(tsx|ts|mts|cts)$/.test(basename)) return false;

  // Test/spec opt-out — applied on the query side only; the walker continues
  // to extract tests so that catalog rows can carry is_test=true.
  if (!includeTests && isTestPath(relPath)) return false;

  return true;
}
```

`SKIP_DIRS` and `isTestPath` are already in scope. The function is pure; no I/O.

### CLI surface

Extend the `parseArgs` block in `type-catalog.mjs`:

```js
'list-relevant':  { type: 'boolean', default: false },
'include-tests':  { type: 'boolean', default: false },
'null':           { type: 'boolean', short: '0', default: false },
```

Note: `-0`/`--null` selects NUL-separated I/O. `--include-tests` applies to *both* the new `--list-relevant` mode and (later, in a follow-up) any in-walker filtering.

`--list-relevant` mode flow:

1. If `--list-relevant` is passed without `--root`, the help-or-error gate currently requires `--root`. Either:
   - **a.** Relax the gate so `--list-relevant` works without `--root` (paths are predicate-only; no walk happens), OR
   - **b.** Keep requiring `--root`, on the theory that paths *will* be `--root`-relative in practice.

   **Pick (a).** The predicate doesn't read the filesystem; requiring `--root` is friction. Callers pass relative paths; the flag returns the relative paths it would keep.

2. Read paths from stdin to EOF, split on `\n` (default) or `\0` (with `--null`). **Stdin-only for v1** — the issue spec says "stdin OR positional argv", but `parseArgs` requires explicit `allowPositionals: true` to surface positionals, and neither downstream consumer (#123, #124) needs argv input. Omitting `allowPositionals` keeps the surface minimal; if a future consumer needs argv mode, adding it is mechanical.

3. For each input path, evaluate `isRelevantPath(path, { includeTests })`. If kept, write to stdout followed by `\n` (default) or `\0` (with `--null`).

4. Exit 0 regardless of whether any path was kept. Non-zero only on stdin read failure.

### What does NOT change

- The walker. `walkDir` continues to extract test files; rows carry `is_test=true`. Downstream `_tests/` and the case-study fixtures depend on this.
- The catalog output schema.
- The `function-catalog.mjs` walk. (Follow-up question: should `function-catalog.mjs` also expose `--list-relevant`? Probably yes, but bundling is scope creep — file as follow-up.)
- Any other extractor flag.

## Test plan

New tests in [`extractors/typescript/test/`](../../extractors/typescript/test/) (existing convention — `extract.test.mjs`, `function-catalog.test.mjs`, etc. live here; the `tests/` directory is for shell smoke tests + fixtures, not Node unit tests):

- **Unit (`isRelevantPath`):**
  - Keeps `src/foo.ts`, `src/foo.tsx`, `src/foo.mts`, `src/foo.cts`.
  - Drops `src/foo.js`, `src/foo.md`, `src/foo` (no extension), `README.md`.
  - Drops `node_modules/pkg/index.ts`, `dist/foo.ts`, `build/foo.ts`, `coverage/foo.ts`.
  - Drops `.git/HEAD`, `.next/foo.ts`, `.claude/x.ts`, `.idea/x.ts`, `.cursor/x.ts`.
  - Drops `tests/foo.ts`, `src/__tests__/foo.ts`, `src/foo.test.ts`, `src/foo.spec.ts` when `includeTests=false`.
  - Keeps the same when `includeTests=true`.
  - Drops absolute paths (`/abs/path.ts`).
  - Drops empty string.
  - Mixed-case extensions: drops `foo.TS` (case-sensitive — matches existing walk regex).

- **CLI (`--list-relevant`):**
  - Stdin of mixed paths → stdout is the kept subset in input order, one per line.
  - `--null` flag → NUL-separated I/O on both sides.
  - `--include-tests` flag → test files are kept.
  - Empty stdin → empty stdout, exit 0.
  - Stdin with only excluded paths → empty stdout, exit 0.
  - Without `--root` set, `--list-relevant` still works (no help/error gate trip).

- **No regression on existing extractor invocations:** the existing test suite (`test/`, `tests/`) must continue to pass unchanged. This is the load-bearing assertion that the walker hasn't shifted.

Test wiring matches the existing `tests/` directory convention. Use `node --test` (Node's built-in runner) since the rest of `tests/` already does.

## Documentation

- **`extractors/typescript/README.md`** — add a `--list-relevant` section with a one-line example:
  ```bash
  git diff --name-only main...HEAD | node extractors/typescript/type-catalog.mjs --list-relevant
  ```
- **`docs/pipeline-contract.md`** — extractor-CLI section: add `--list-relevant`, `--include-tests`, `--null` to the documented flag set with the note that `--list-relevant` is a query, not an extraction.
- **`extractors/typescript/manifest.toml`** — no change needed (the manifest describes the extractor itself, not the CLI surface). Verify on review.

## Out of scope (filed as follow-ups in the PR body)

- **`.gitattributes` linguist-generated handling** — neither the walker nor the predicate reads `.gitattributes` today. Adding it later does not change the predicate's signature.
- **Cross-language `--list-relevant`** — Python/Swift/Go extractors get their own flag in their own PRs. Each language's walk semantics live in its own extractor; the flag's CLI shape is documented here as the convention.
- **Positional argv input mode** — stdin-only for v1. If a consumer needs argv input later, adding it is mechanical.
- **`function-catalog.mjs` `--list-relevant`** — same walker semantics for `.ts/.tsx/.mts/.cts`; could share the predicate. File as follow-up if/when a consumer needs it.

## Rollout

Single PR. Diff target: ≲ 400 lines (predicate + flag wiring + tests + doc updates). Well under the 1000-line PR ceiling in CLAUDE.md.

CI gates: `node --test extractors/typescript/tests/`, the existing `pipeline/_tests/test_substrate.sh` and `test_audit_core.sh` (unchanged from main), shellcheck/actionlint clean.

Post-merge: announce in PR body that #123 and #124 can now proceed.

## Acceptance checklist

- [ ] `isRelevantPath(path, { includeTests })` exported from `type-catalog.mjs` (or `_lib/walk-predicate.mjs` if extracted).
- [ ] `--list-relevant` flag reads stdin, evaluates predicate, prints kept paths to stdout.
- [ ] `--include-tests` and `--null` modifiers respected.
- [ ] Unit tests for predicate cover all bullet points in the test plan above.
- [ ] CLI integration tests cover stdin/argv/null/include-tests matrix.
- [ ] README documents the flag with a one-line example.
- [ ] `pipeline-contract.md` updated.
- [ ] No regression in `test/`, `tests/`, `pipeline/_tests/test_substrate.sh`, `test_audit_core.sh`.
- [ ] PR body lists the deferred follow-ups (linguist-generated, cross-language, argv-input, function-catalog).
