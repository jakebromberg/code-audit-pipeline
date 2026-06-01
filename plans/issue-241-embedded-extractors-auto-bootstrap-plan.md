# Embedded extractors + auto-bootstrap

## Problem

`code-audit init` requires `--from <local-checkout>` (enforced at `internal/cli/init.go:67-70`), so a user who installs the binary via `brew install jakebromberg/tap/code-audit` (or `go install` outside a checkout) has no path to run extractors. The README's Quick start opens with `code-audit init --from /path/to/code-audit-pipeline`, which a brew user cannot satisfy.

Queries already work in this state — they're embedded in the binary per [ADR-0006](../docs/adr/0006-bundling-and-discovery.md). The gap is specifically extractor delivery: extractors live in `extractors/<lang>/` in the source tree and are copied to `~/.config/audit/extractors/` only via `code-audit init --from`.

This plan closes the gap by **embedding extractor source in the binary** (same pattern as queries) and **auto-extracting on first `code-audit extract <name>` call** when no on-disk source is found, with bootstrap (`npm install` etc.) declared in the extractor manifest and executed by the binary.

## Design

### Twelve nailed-down decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Brew UX scope | Full pipeline, no clone required. `brew install code-audit` → `code-audit extract typescript --root ~/repo` just works. |
| 2 | Delivery mechanism | Embed extractor source in the binary via `//go:embed`, mirroring the existing queries pattern. |
| 3 | `init` semantics | Auto-extract on first `code-audit extract <name>` if the discovery chain falls through to tier 4 and tier 4 is missing/empty. Accepted lazy state mutation as cost of one-step UX. |
| 4 | Bootstrap delivery | New manifest field `[runtime].bootstrap = ["npm", "install"]` (array form, no shell interpolation). Binary shells out to it. Manifest schema version bumps 1 → 2. |
| 5 | Staleness detection | On every `extract` call, SHA-walk the source tree (excluding `node_modules` per existing `initSkipDirs`), compare on-disk vs. embedded vs. state.json pristine SHA. |
| 6 | CLEAN-and-stale | Auto-upgrade silently. Update state.json pristine SHA. |
| 6b | DIRTY-and-stale | Print stderr warning naming the files; proceed with on-disk version. User must run `init --upgrade --force` to overwrite. |
| 7 | Bootstrap re-run | If auto-upgrade overwrote any source file (excluding `node_modules`), re-run the manifest's bootstrap command after extraction. |
| 8 | Bootstrap failure | Print failed command + captured stderr + the manifest's `setup_hint` for context. Set `bootstrap_status: "failed"` in state.json. Exit non-zero. Next `extract` call retries. |
| 9 | `init` keeps living | Contributor + upgrade tool. `--from` becomes optional (defaults to embedded FS). `--upgrade` re-extracts; `--force` overwrites DIRTY. Remove the "required in v1" error at `init.go:67-70`. |
| 10 | Concurrency | Per-extractor `flock(2)` on `~/.config/audit/extractors/<name>/.audit-init/lock`. 60s blocking timeout. Releases on process exit. |
| 11 | `init` also bootstraps | Every path that puts source on disk (`init --from`, `init`, `init --upgrade`, auto-extract) also runs the manifest's bootstrap. The README's "after init, run `npm install`" post-step disappears. |
| 12 | Auto-extract trigger gate | Fires iff: **the discovery chain resolves to tier 4** (`~/.config/audit/extractors/`). Any earlier tier resolving (explicit `--extractors-dir`, cwd-local `extractors/` present even if incomplete, `$AUDIT_HOME` set even if empty) preempts auto-extract entirely — the user/contributor is signalling "I'm managing source here" and the binary doesn't second-guess. If tier 2 (cwd-local) is present but missing the requested extractor, the extract command surfaces a "no such extractor" error rather than auto-extracting into `~/.config/`. Pinned by test 19b. |

### Five mechanical decisions

- **LE1 — generator.** Generalize `internal/genqueries` into `internal/genembed`. Flags: `--src`, `--dst`, `--skip` (CSV of dirnames to prune), `--flatten` (current queries behavior — top-level files only) vs. default `--preserve-tree` (extractors). Move the shared skip-dir set (`node_modules`, `.build`, `.swiftpm`, `DerivedData`, `Pods`, `dist`, `build`, `coverage`, dot-dirs) into a new `internal/initstate` package referenced by both `init.go` and `genembed`.
- **LE2 — `code-audit status`.** Add a per-extractor block: resolved source path, `bootstrap_status` (`ok`/`failed`/`pending`/`n-a`), `bootstrapped_at` timestamp.
- **LE3 — manifest field name.** `[runtime].bootstrap = ["npm", "install"]`. Array form. Lives in the existing `[runtime]` table next to `requires` and `setup_hint`.
- **LE4 — extractors without bootstrap declared.** Treat as no-op. **Status rendering rule:** an extractor whose manifest declares no `[runtime].bootstrap` shows `bootstrap: n-a` in `code-audit status` **as soon as the user runs `extract` once** (which writes `bootstrap_status: "n-a"` to state.json). Before the first `extract`, the extractor shows as `bootstrap: pending` if state.json is missing the entry — pending becomes `n-a` (not `ok`) once `EnsureExtractor` parses the manifest and sees the empty bootstrap field. No retry, no warning. Pinned by test 10c.
- **LE5 — `node_modules` under `~/.config/`.** Accepted. Documented in the new ADR. The alternative (split source under `.config/`, `node_modules` under `.cache/`) requires `NODE_PATH` gymnastics and breaks atomic upgrade semantics.

### State.json schema change

Add a per-extractor map next to the existing per-file map:

```json
{
  "audit_version": "...",
  "source_repo_root": "...",
  "source_commit_sha": "...",
  "applied_at": "...",
  "files": { ... existing per-file SHA map ... },
  "extractors": {
    "typescript": {
      "bootstrap_status": "ok",
      "bootstrapped_at": "2026-06-01T12:34:56Z",
      "source_sha": "<combined SHA of source files at last bootstrap>"
    }
  }
}
```

Backward compatibility:

- **New binary reading old state.json** (missing `extractors` field): the JSON unmarshal leaves the new field as a nil/empty map. The first `extract` call treats every extractor as `bootstrap_status: "pending"`, runs bootstrap once, persists the new state. One-time slow path. Documented in ADR-0008 as expected behavior.
- **Old binary reading new state.json** (extra `extractors` field): Go's `encoding/json` ignores unknown fields by default. Old binary's behavior is unchanged. No panic, no corruption. Pinned by test 10a.
- **Old binary *writing* new state.json** (downgrade scenario): the old binary's `InitState` struct has no `Extractors` field, so `json.Marshal` silently omits it. A user who downgrades after running the new binary loses their extractor bootstrap state. The next run of the new binary observes `Extractors == nil` and re-bootstraps once (the same one-time slow path as the fresh-upgrade case). **No corruption, no panic; pre-1.0 acceptable**. ADR-0008 documents this explicitly under a "Downgrade migration" subsection: "state.json is a one-way migration; downgrades lose extractor tracking but auto-recover on next new-binary run." Pinned by test 10e.
- **`code-audit status` surfaces the slow path**: after the change, status shows `bootstrap: pending (will run on next extract)` for extractors whose state was migrated from an old format. The user sees the one-time path is upcoming rather than discovering it via a surprise 30-second pause.

### Manifest schema change

`manifest_schema_version` bumps 1 → 2. The change is purely additive: a new optional `[runtime].bootstrap` array. Binaries reading schema 1 ignore the field; schema 2 readers act on it. No breakage for users with old extractor checkouts.

Updated `extractors/typescript/manifest.toml`:

```toml
schema_version = 2

[extractor]
name = "typescript"
# ... unchanged ...

[runtime]
requires = ["node >= 18"]
bootstrap = ["npm", "install"]
setup_hint = "Run `npm install` in extractors/typescript/ (once per clone)."
```

`setup_hint` stays as the human-readable fallback printed on bootstrap failure.

## Implementation phases

The work is sequenced so each phase compiles and tests pass before the next begins. Final PR size estimate is 1200–1500 lines including tests; **expect this to chain into two PRs** rather than land as one. The natural split is between Phase 3 (embed + manifest, no behavior change) and Phase 4 (auto-extract + bootstrap orchestration, the meaty part).

### Phase 1 — generalize the generator (internal-only, no behavior change)

**Pre-flight check** (verified before authoring this plan): `grep -rn "genqueries" --exclude-dir=.claude` across `.github/`, `.goreleaser.yaml`, and `Makefile` produces no hits. (The `--exclude-dir=.claude` flag is critical — the repo contains worktree clones under `.claude/worktrees/<branch>/` which carry historical copies of the same code and would otherwise produce false positives.) The rename touches only `cmd/code-audit/embed.go`, `internal/genqueries/main.go` (→ `internal/genembed/main.go`), and a docs reference in `plans/pr3-binary-skeleton.md` (historical, leave as-is — the prior plan documents the prior name). No CI or release tooling change needed.

1. Create `internal/initstate/skipdirs.go` with a single exported `SkipDirs map[string]bool` initialized at package-init time to `{"node_modules": true, ".build": true, ".swiftpm": true, "DerivedData": true, "Pods": true, "dist": true, "build": true, "coverage": true}`. **Read-only after init:** add a top-of-file doc comment "`// SkipDirs is read-only after package init. Concurrent reads are safe; do not mutate.`" — since the codebase has no goroutines mutating it, no further locking is needed, but the invariant is documented. **CLI-internal:** referenced from `internal/cli/init.go` (replacing the package-private `initSkipDirs`). **Future-work note** (deferred — not part of this PR): consider factoring the skip-dir set into a single TOML/YAML config file referenced by both `genembed` and `initstate` to eliminate the CSV-parsing drift-guard (test 4g). v1 uses the simpler CSV-passing approach. The generator does **not** import this package — `genembed` stays standalone-runnable, receiving its skip list via the `--skip` CSV flag. The `//go:generate` directive in `cmd/code-audit/embed.go` passes the same dirname set as a literal CSV (kept in sync by code review / `grep`; an integration test in Phase 1 reads both lists and asserts they match, preventing silent drift).
2. Rename `internal/genqueries/` → `internal/genembed/`. The old directory is **deleted entirely** — no stub, no symlink, no deprecated package. The pre-flight grep above confirmed no CI/release tooling references the old name; the only consumer is the `//go:generate` directive in `cmd/code-audit/embed.go`, which gets updated in step 4 below.

Add flags:
   - `--src <path>` (required)
   - `--dst <path>` (required)
   - `--flatten` (bool, **default false** — generator preserves the source tree). When `--flatten` is passed, only top-level files in `--src` are copied (any file at a non-zero depth is skipped). This matches what today's `genqueries/main.go:60` does unconditionally (`if strings.Contains(path, "/") return nil`). To preserve the current queries behavior, the queries `//go:generate` line in `embed.go` must pass `-flatten` explicitly. Extractors don't pass it and get tree-preservation. Plain reading: default false = tree mode; opt-in true = flat mode.
   - `--ext <csv>` (default empty, meaning "all extensions"): file-extension filter (today's `genqueries` hardcodes `.jq`).
   - `--skip <csv>` (default empty): comma-separated dirnames to prune at *every* level by basename. Independent of `internal/initstate.SkipDirs` (the generator stays standalone-runnable without importing CLI packages).
3. **Symlink and empty-dir semantics** (specified to prevent ambiguity):
   - Symlinks (file or directory) are **not followed**. Encountered symlinks are skipped silently. Rationale: monorepo extractors may symlink `node_modules` to a workspace root; following could explode the embedded FS. Tested explicitly.
   - Empty source directories are not preserved (`//go:embed` does not embed empty dirs regardless; matching the embed semantics avoids surprises).
   - Skip-by-basename applies at every depth, not just top-level. E.g., `--skip node_modules` prunes `extractors/typescript/node_modules` AND any hypothetical `extractors/x/y/node_modules`.
4. Update the existing `//go:generate` line in `cmd/code-audit/embed.go`:
   ```go
   //go:generate go run ../../internal/genembed -src ../../pipeline/queries -dst ./queries -flatten -ext .jq
   ```
5. Add a new generate line:
   ```go
   //go:generate go run ../../internal/genembed -src ../../extractors -dst ./extractors -skip node_modules,.build,.swiftpm,DerivedData,Pods,dist,build,coverage
   ```
6. Add `//go:embed extractors` to the existing embed block; expose `embeddedExtractors() fs.FS` symmetrically to `embeddedQueries()`.

**Tests** (in `internal/genembed/main_test.go`):

| # | Test | Phase-dep |
|---|---|---|
| 1 | `--flatten` skips subdirs entirely (only top-level files copied) | 1 |
| 2 | Default (no `--flatten`) preserves tree | 1 |
| 3 | `--skip node_modules` prunes at top level AND nested levels | 1 |
| 4 | `--ext .jq` filter (with `--flatten`) excludes non-`.jq` files | 1 |
| 4a | No `--ext` flag copies all file extensions | 1 |
| 4b | Symlinks to files are silently skipped | 1 |
| 4c | Symlinks to directories are silently skipped (no infinite recursion in pathological cases) | 1 |
| 4d | Empty source directories are not copied | 1 |
| 4e | Refuses to operate when src is missing (exit non-zero, clear error) | 1 |
| 4f | Refuses to operate when dst resolves inside src (refuseSymlinkLoop equivalent) | 1 |
| 4g | **Drift guard:** scan `cmd/code-audit/embed.go` for **all** lines containing `genembed`. For each line, parse the `-skip` CSV (if present) and compare against `initstate.SkipDirs` keys — asserts every `genembed` invocation that declares `-skip` has the same set as the constant. Future-proof: a second `//go:generate genembed -src ../../other -skip ...` line gets validated automatically. Lines without `-skip` (e.g., the queries line) are not checked. Pinned test comment: "If a future `genembed` invocation needs a *different* skip set, factor SkipDirs into per-target maps and update this test to dispatch accordingly." | 1 |

### Phase 2 — manifest schema bump + bootstrap field

The parser lives at `internal/manifest/parser.go`. Current validation at line 79 is strict equality: `if m.SchemaVersion != 1`.

1. Centralize schema version constants in `internal/manifest/parser.go` to prevent literal drift between validator, tests, and manifests. **All constants are exported** (capital-S) **within the `internal/manifest` package** so `internal/manifest/parser_test.go` can reference them without hard-coding `1`/`2`/`3`. Note: `internal/manifest` is itself a private package under `internal/`, so these "exports" are not public API surface — they are visible only to other packages inside this module. The Go convention of capital-S for cross-file-within-a-package use is what's at play here, not external exposure:
   ```go
   const (
       SchemaVersion1   = 1  // exported; tests 5a–7c import and use these
       SchemaVersion2   = 2
       MinSchemaVersion = SchemaVersion1
       MaxSchemaVersion = SchemaVersion2
   )
   ```
   Change the validation at `internal/manifest/parser.go:79` from strict equality to a range check using the constants:
   ```go
   if m.SchemaVersion < MinSchemaVersion || m.SchemaVersion > MaxSchemaVersion {
       return fmt.Errorf("manifest: %s: schema_version must be %d–%d, got %d",
           path, MinSchemaVersion, MaxSchemaVersion, m.SchemaVersion)
   }
   ```
   Tests 5a–7c reference the constants too, not literal `1` / `2` / `3`.
2. Add a `Bootstrap []string` field to the `Runtime` struct in `internal/manifest/parser.go`. The struct currently sits at lines 46–49; the new field goes immediately after `SetupHint` (becoming line ~50). Struct tag: `toml:"bootstrap"` — lowercase, matching the convention of `Requires` (`toml:"requires"`) and `SetupHint` (`toml:"setup_hint"`). Optional — zero-value (nil) means "no bootstrap declared, treat as `n-a`."
2a. **Validator rejects `bootstrap` on schema 1** (resolves the prior ambiguity in test 5b's "Alternative"). Add to `validate()` immediately after the range check:
    ```go
    if m.SchemaVersion == 1 && len(m.Runtime.Bootstrap) > 0 {
        return fmt.Errorf("manifest: %s: [runtime].bootstrap requires schema_version >= 2", path)
    }
    ```
    Rationale: keeps the schema 1 → schema 2 distinction in the validator (fail-fast at parse), rather than as an implicit invariant the `runBootstrap` caller must remember. One-line change; eliminates a hidden invariant.
3. Bump `schema_version = 2` in `extractors/typescript/manifest.toml`. Add `bootstrap = ["npm", "install"]` to `[runtime]`. Keep `setup_hint` (used as fallback in failure messages and `code-audit status`).
4. `runBootstrap` (added in Phase 3) must guard on `len(manifest.Runtime.Bootstrap) == 0` and skip silently when the field is absent or empty. Schema 1 manifests will naturally produce an empty Bootstrap slice and never invoke `runBootstrap` — the same code path as a schema 2 manifest that omits the optional field.

**Tests** (all in `internal/manifest/parser_test.go`).

| # | Test | Phase-dep |
|---|---|---|
| 5a | Schema 1 manifest without `[runtime].bootstrap` parses; `m.Runtime.Bootstrap == nil` | 2 |
| 5b | Schema 1 manifest WITH `[runtime].bootstrap` is **rejected** at parse time with a clear error mentioning the schema-version requirement (resolves the prior ambiguity by pushing the invariant into the validator) | 2 |
| 6 | Schema 2 manifest with `bootstrap = ["npm", "install"]` parses; `m.Runtime.Bootstrap` is the right slice | 2 |
| 7a | Schema 2 manifest WITHOUT `[runtime].bootstrap` parses; nil Bootstrap; status will show `n-a` (validated in Phase 6) | 2 |
| 7b | Schema 0 rejected | 2 |
| 7c | Schema 3 rejected with clear error mentioning the supported range | 2 |

### Phase 3 — bootstrap execution + state.json schema extension

1. Add `ExtractorState` struct in `init.go`:
   ```go
   type ExtractorState struct {
       BootstrapStatus string    `json:"bootstrap_status"` // ok|failed|pending|n-a
       BootstrappedAt  time.Time `json:"bootstrapped_at,omitempty"`
       SourceSHA       string    `json:"source_sha,omitempty"` // combined SHA of source files at last successful bootstrap
       LastError       string    `json:"last_error,omitempty"` // captured stderr summary when status==failed
   }
   ```
2. Add `Extractors map[string]ExtractorState` to `InitState`. JSON tag `extractors,omitempty`.
3. **Nil-map semantics.** Go's `json.Unmarshal` leaves omitted map fields as `nil` (not as an empty initialized map). For *reads*, this is safe: `state.Extractors[name]` on a nil map returns the zero value (`ExtractorState{}` — empty `BootstrapStatus`, treated as `pending` by the caller). For *writes*, Go panics on nil-map assignment. To eliminate this footgun globally, add a helper method:
    ```go
    // EnsureExtractorsMap returns the Extractors map, initializing it if nil.
    // All write paths must go through this helper to avoid nil-map panics on
    // state loaded from older binaries that omitted the field.
    func (s *InitState) EnsureExtractorsMap() map[string]ExtractorState {
        if s.Extractors == nil {
            s.Extractors = map[string]ExtractorState{}
        }
        return s.Extractors
    }
    ```
    Add a doc comment on the `Extractors` field referencing this helper. **Explicit call sites for `EnsureExtractorsMap()`:**
    - `Init` (Phase 4): immediately before the per-extractor record-write at the end of the file-copy loop in `init.go` — current line range `init.go:130-138` (the `newState := InitState{...}` block plus the loop that writes file SHAs); the analogous extractor-record write is added in the same loop.
    - `layDownExtractor` (Phase 5): immediately before the `state.Extractors[name] = ExtractorState{...}` assignment near the end of the function.
    - `EnsureExtractor` (Phase 5): not needed directly — it delegates writes to `layDownExtractor`.
    Tests 10 (read), 10a (round-trip), and **10d** (explicit write against a freshly unmarshaled state.json with nil `Extractors` — verifies no panic) pin the invariant.
4. Add `runBootstrap(ctx, extractorDir, manifest) error` to `internal/cli/init.go`. Spawns the manifest's bootstrap command via `os/exec.CommandContext` with `Cmd.Dir = extractorDir`, stdout/stderr captured into bounded buffers (cap at 64KB to avoid OOM on noisy installers). On non-zero exit, returns a `*BootstrapError` wrapping the captured stderr; on success, returns nil.
5. Extend `Init` to call `runBootstrap` after the file-copy phase for each extractor whose source was just laid down OR upgraded (`copiedNew > 0 || upgraded > 0` for that extractor). Record `ok` / `failed` per extractor in `newState.Extractors`. Record `n-a` when the extractor's manifest declares no bootstrap.

6. **Discovery API change lives here in Phase 3** (the full spec sits under Phase 5's section text for narrative reasons, but the *implementation* lands in Phase 3 so Phase 4 tests can compile). To make the structural seam clear: see "Discovery API change" subsection under Phase 5 below for the full `Tier` enum + signature change spec. The work is implemented and tested *within Phase 3's PR*; Phase 5 only consumes it.

**PR-α sequencing boundary.** Phases 1, 2, and 3 form PR α and must all compile + test cleanly on `main` before any Phase 4 work begins. No cherry-picking, no parallel branches. Confirmed by the test list — every Phase 4 test that references the `Tier` enum requires Phase 3's API change to be in scope.

**Tests** (in `internal/cli/init_test.go`):

| # | Test | Phase-dep |
|---|---|---|
| 8 | `runBootstrap` invokes with `Cmd.Dir` == extractor dir; captures stderr on failure (verify by running a script that writes to stderr + exits 1) | 3 |
| 8a | `runBootstrap` truncates captured stderr at the 64KB cap | 3 |
| 8b | `runBootstrap` respects context cancellation (Ctrl-C during long install) | 3 |
| 9 | state.json round-trips per-extractor map (write → read → compare struct) | 3 |
| 10 | state.json missing `extractors` field loads as nil map; callers see effectively `pending` | 3 |
| 10a | **Backward-compat round-trip:** write a `state.json` blob simulating the *old* format (no `extractors` key — just a JSON literal in the test source, with a comment `// Simulates state.json from the binary immediately before Phase 3 was released — keep the field set frozen for this test even as InitState grows new fields.`), unmarshal into the *current* `InitState` struct, assert no error and `Extractors == nil`. Codifies Go's "ignore unknown fields" default and our "treat nil map as pending" convention. **No frozen struct file** — JSON literal in the test body achieves the same coverage without the per-schema-change update burden. | 3 |
| 10b | `Init` re-run on the same dest with no source changes is idempotent: state.json's `bootstrapped_at` does NOT advance, `bootstrap_status` stays `ok`, `os/exec` is never invoked (use a spy) | 3 |
| 10c | Missing `bootstrap` field in manifest skips silently; state.json records `bootstrap_status: n-a` | 3 |
| 10d | Write path against a freshly unmarshaled state.json that omits `extractors` (simulating an old-binary write): calling `state.EnsureExtractorsMap()` then assigning `state.Extractors["foo"] = ExtractorState{...}` succeeds without panic | 3 |
| 10f | **End-to-end downgrade-then-upgrade-recovery cycle**: (1) build a state.json string with `extractors: {typescript: {...ok...}}` populated; (2) `json.Unmarshal` into an inline `oldInitState` struct (no `Extractors` field); (3) re-`json.Marshal` from the old struct → confirm `extractors` field is absent in the bytes; (4) `json.Unmarshal` the round-tripped bytes into a fresh new `InitState` → confirm `Extractors == nil`; (5) **invoke the actual `Init` write codepath against that state** (or the closest faithful simulation: call `state.EnsureExtractorsMap(); state.Extractors["typescript"] = ...; saveState(...)`) → assert no panic, no error; (6) load the saved state back → assert `Extractors` is now populated. This is the production downgrade-recovery sequence, end-to-end. | 3 |
| 10e | **Downgrade simulation, fully explicit:** (1) Construct a JSON string with the new format including a populated `"extractors": {...}` block. (2) Verify (with a regex or `gjson`-style probe) that `extractors` is present in the JSON bytes — pre-condition assertion. (3) Unmarshal into an inline `oldInitState` struct (defined in the test body, with only the old fields) — assert no error. (4) Re-marshal the old struct → assert the resulting JSON does NOT contain `extractors` (post-condition: old binary drops the field on write). (5) Unmarshal the round-tripped JSON into the *current* `InitState` → assert `Extractors == nil`. Documents the full downgrade-then-upgrade cycle and proves the recovery is automatic on next new-binary run (test 10d guards the recovery write path). | 3 |

### Phase 4 — `init --from` becomes optional

**Test file co-location.** Phase 4 tests (11–12c) land in `internal/cli/init_test.go` alongside Phase 3 tests (8–10c). Despite the test-count growth (~17 tests across two phases in one file), co-location is intentional: both phases exercise `Init` end-to-end with different source backends (filesystem path vs. embedded FS), and a shared helper function `setupSourceFS(t, kind)` (returning either `os.DirFS(tmp)` or `embeddedExtractors()`) eliminates fixture duplication.

**Approach: thread `fs.FS` through.** The reviewer-flagged "walk embedded FS into a temp dir" path was originally listed as the simpler option but is rejected: temp-dir cleanup interacts badly with the per-extractor flock in Phase 5 (a reaped temp dir mid-bootstrap means the lock's source disappears), and the cleanup paths multiply error surfaces. Threading `fs.FS` through `buildCopyPlan` / `copyFile` is the higher-quality refactor and is now the chosen path.

**Symlink semantics in the refactor — observable behavior change.** `fs.WalkDir` does not follow symlinks (it visits them as regular entries but does not recurse into symlinked directories) and `//go:embed` does not include symlinks at all. This matches Phase 1's "symlinks not followed" rule for `genembed` without extra code. The `--from <checkout>` path (using `os.DirFS`) inherits the same semantic, which is a *behavior change* from the current `filepath.WalkDir`-based code at `init.go:332` that does descend into symlinked directories.

The change is intentional: it eliminates the divergence between the `--from` and embedded paths and reduces the attack surface (a hostile symlink under `--from <untrusted>` can no longer cause arbitrary recursion).

**TDD sequencing for test 12b.** Test 12b is a *specification test* for the new behavior, not a post-hoc regression-guard. Per red-green-refactor discipline, it lands first in Phase 4 and is red against the old `filepath.WalkDir` code. Implementing the `fs.WalkDir` refactor turns it green. Do not implement the refactor without test 12b in place — that would invert the discipline.

**Migration consequence for existing users:** A user who previously ran `init --from <checkout>` against a tree containing symlinks may have copies of files-via-symlink under `~/.config/audit/extractors/`. After the refactor, those orphan files have no entries in the new copy plan (because the symlink that produced them is no longer traversed). They are not classified as DIRTY — `classifyFiles` only inspects files in the *current* plan. The orphans sit harmlessly until the user manually removes the extractor dir or runs `init --upgrade` (which still doesn't touch unplanned files). Phase 5's auto-extract logic likewise never sees the orphans because they are not in `state.json.files`. This is acceptable: dead files in tier 4 don't break extractor execution.

1. Remove the early-exit at `internal/cli/init.go:67-70`.
2. Refactor `buildCopyPlan` (currently `init.go:328-363`) to take an `fs.FS` source instead of an absolute `src string`. Use `fs.WalkDir(srcFS, subdir, ...)` instead of `filepath.WalkDir(filepath.Join(srcAbs, subdir), ...)`. The destination remains a filesystem path. **The existing `initSubdirs` loop (line 330) is preserved inside `buildCopyPlan`** — each subdir (`extractors`, `pipeline/queries`) gets its own `fs.WalkDir` walk on the same `srcFS`. The FS root is the source tree root: the repo root when `--from` is given (via `os.DirFS(src)`), or the embedded root (where `extractors/` and `pipeline/queries/` are sibling top-level dirs in the embedded FS).

   **Path representation in `fileClassification`** (full before/after, all fields enumerated):
   ```go
   // BEFORE (init.go:224-230):
   type fileClassification struct {
       srcAbs  string     // absolute path on host filesystem — DROP
       dstAbs  string     // absolute destination path — KEEP
       relDest string     // forward-slash path under dst root — KEEP
       srcSHA  string     // SHA of source content — KEEP
       state   fileState  // NEW / CLEAN / DIRTY — KEEP
   }

   // AFTER:
   type fileClassification struct {
       srcRel  string     // NEW: path within srcFS, forward-slash, e.g., "extractors/typescript/type-catalog.mjs"
       dstAbs  string     // unchanged
       relDest string     // unchanged
       srcSHA  string     // unchanged
       state   fileState  // unchanged
   }
   ```
   Callers (`classifyFiles`, the main loop in `Init`) carry the `srcFS` reference and open files via `srcFS.Open(c.srcRel)` rather than `os.Open(c.srcAbs)`.

   **`srcRel` format invariant** (load-bearing for cross-FS equivalence): always forward-slash, relative to the FS root, **no leading `./` or `/`**. Example: `"extractors/typescript/type-catalog.mjs"`, never `"./extractors/typescript/type-catalog.mjs"` or `"/extractors/typescript/type-catalog.mjs"`. `fs.WalkDir` produces this format natively; both `os.DirFS(src)` and `embeddedExtractors()` yield identical strings for the same relative file. Test 12a's plan-equivalence assertion depends on this invariant — break it and the two backends produce non-equal plans even when their content is identical.
3. Refactor `copyFile` (currently `init.go:430-466`) to take an `fs.File` source instead of opening by path. Signature: `copyFile(in fs.File, dst string, mode os.FileMode) error`. The caller does `in, err := srcFS.Open(c.srcRel); defer in.Close(); copyFile(in, c.dstAbs, mode)`. The tmp-then-rename atomicity stays. **File mode bits:** `//go:embed` does not preserve mode bits — every embedded file appears as `0o444` regardless of source mode. We honor an executable bit only by detecting a `#!` shebang in the first two bytes of the file content. Cost: open + read 2 bytes per file at extraction time. For the TS extractor (~10 source files), trivial. For larger future extractors, still bounded by file count. Trade-off accepted explicitly: shebang detection is the right v1 default; future extractors that need finer control can declare `[runtime].executable_patterns` in their manifest as a follow-up. The TS extractor today has only `.mjs` files invoked via `node`, so no file gets the executable bit anyway — the cost is exercised but the bit is never set.
4. Add a small adapter so `--from <checkout>` produces an `fs.FS` via `os.DirFS(src)`. Then `embeddedExtractors()` and `os.DirFS(src)` are interchangeable as the source argument.
5. `validateSource` runs only when source is a filesystem path (i.e., `--from` is given). Embedded source is trusted by construction.
6. `gitHeadSHA` is called only with a filesystem source. When source is embedded, state.json records `source_repo_root: "<embedded>"` and `source_commit_sha: ""` (plus `audit_version` for the pinning information).
7. **`gitHeadSHA` error handling.** Two paths, two policies:
   - `--from <path>` is given but the path is not a git checkout (`.git/HEAD` missing or unreadable): record an empty `source_commit_sha` and proceed silently. Rationale: contributors may legitimately point at an exported source tree, not a checkout. Failing here would block a valid workflow for no safety gain — the SHA is forensic-only, never load-bearing.
   - Embedded source path: skip `gitHeadSHA` entirely; record `source_commit_sha: ""`. Always succeeds.

   Existing behavior at `init.go:510-525` already returns "" on read errors; the change is just to document the policy explicitly so future maintainers don't introduce a stricter check. Test 12e pins this.

**Tests** (all in `internal/cli/init_test.go`):

| # | Test | Phase-dep |
|---|---|---|
| 11 | `code-audit init` (no args) succeeds with embedded source; state.json records `source_repo_root: "<embedded>"` | 4 |
| 11a | `code-audit init` (no args) on a fresh dest runs bootstrap once; state.json records `bootstrap_status: ok` per extractor | 4 (also touches Phase 3) |
| 11b | `code-audit init` (no args) re-run with no source changes is idempotent: no file writes, no bootstrap re-run, exit 0 | 4 (Phase 3 idempotency invariant) |
| 12 | `code-audit init --from <checkout>` still works; state.json records the absolute path | 4 |
| 12a | `os.DirFS(src)` and `embeddedExtractors()` produce **structurally equivalent** copy plans against a synthetic source tree. Equivalence is defined on `relDest` (relative path), file count, and SHA — absolute `srcAbs` paths differ by construction (one is `/tmp/...`, the other is embedded-FS-internal) and are excluded from the comparison. Test asserts the trimmed plan structures are equal. | 4 |
| 12b | `--from <dir-with-symlink-loop>` does NOT recurse into the symlink (regression test for the behavior change from `filepath.WalkDir`) | 4 |
| 12c | Embedded files with `#!` shebang as first two bytes get `0o755` executable mode; non-shebang files get `0o644`. **Edge cases covered:** (i) 0-byte file → `0o644` (no shebang possible); (ii) 1-byte file containing `#` → `0o644` (too short to be a shebang); (iii) 2-byte file `#!` → `0o755`; (iv) file starting with `# comment` (no `!`) → `0o644`; (v) file starting with arbitrary binary bytes that happen to be `0x23 0x21` → `0o755` (false positive accepted as the natural cost of a 2-byte heuristic; the TS extractor and all currently-planned extractors have no such files, and a binary-with-`#!`-prefix is sufficiently pathological to treat as a script). | 4 |
| 12d | `Init` with `--from <dir-with-missing-extractor-subdir>` succeeds (the copy plan handles partial source trees — only directories present in src appear in the plan); pairs with Phase 5's test 19b which exercises the discovery-time analogue | 4 |
| 12e | `Init --from <non-git-dir>` succeeds; state.json records `source_commit_sha: ""` (no panic, no failure); confirms `gitHeadSHA` error handling stays graceful | 4 |

### Phase 5 — auto-extract trigger in `extract`

#### Lock + state.json coordination protocol

The flock and state.json together form a two-layer coordination mechanism. The lock serialises *writers*; state.json carries *outcome* so a second caller can tell whether the first writer succeeded.

```
EnsureExtractor(ctx, name):
    lockPath := ~/.config/audit/extractors/<name>/.audit-init/lock
    mkdir -p its parent dir
    fd, err := flock(lockPath, LOCK_EX, timeout=60s)
    if err: return "another process is bootstrapping <name>; retry shortly"
    defer flock(fd, LOCK_UN); fd.Close()

    # Re-check state INSIDE the lock — another process may have just succeeded.
    state := loadState(dest)  # missing → empty
    extState := state.Extractors[name]  # zero-value if absent

    # Compute current embedded source SHA combined (deterministic over the embedded subtree).
    embeddedSHA := combinedSHA(embeddedExtractors(), name)

    # If we have a satisfactory state, exit early.
    if extState.BootstrapStatus == "ok" && extState.SourceSHA == embeddedSHA && onDiskMatches(state, name):
        return nil  # nothing to do; another caller already did it OR we were idempotent

    # Either the disk is missing/incomplete, the embedded source moved, or the prior bootstrap failed.
    # Lay down source (auto-extract or auto-upgrade) using the same buildCopyPlan / classifyFiles
    # machinery from Init, scoped to just `extractors/<name>/`.
    changed, err := layDownExtractor(name, embeddedFS, state)
    if err: return err  # bubble up; state.json is NOT updated on lay-down failure (lock released; next call retries from same state)

    # Run bootstrap if source was newly extracted OR any file changed OR prior status was not "ok".
    if changed || extState.BootstrapStatus != "ok":
        if manifest.Runtime.Bootstrap is non-empty:
            err := runBootstrap(...)
            extState.BootstrapStatus = "ok" if err == nil else "failed"
            extState.LastError = err.String() if err != nil else ""
        else:
            extState.BootstrapStatus = "n-a"
        extState.BootstrappedAt = time.Now().UTC()
        extState.SourceSHA = embeddedSHA
        # CRITICAL: write state.json BEFORE releasing the lock so the next holder sees the outcome.
        saveState(dest, state)
        if err != nil: return err  # bootstrap failed; status is persisted
```

Key invariants:

- **Lock holders write state.json before releasing.** A failed bootstrap is recorded as `failed` so the next caller observes it and decides to retry.
- **Idempotency check is content-based, not stat-based.** Reading state.json + comparing SHAs (rather than just `os.Stat(extractorDir)`) means a concurrent caller who arrives after the lock-holder wrote state but before the lock-holder released also sees the up-to-date outcome.
- **State.json is the source of truth across processes.** The lock only serialises mutation; the JSON file carries the outcome.
- **Lay-down failures don't update state.json.** If `os.OpenFile` fails mid-copy, state.json stays at the prior value; next retry classifies files fresh.

#### `extract` integration

**Discovery API change (lands in Phase 3 alongside the state.json schema work, NOT in Phase 5).** The earlier draft had this in Phase 5, but Phase 4's `Init` refactor needs the `Tier` enum in scope to compile its tests (12a–12e check resolved-source-against-tier semantics). Moving the API change to Phase 3 closes the sequencing gap: Phase 3 adds `Tier` + signature; Phase 4 consumes it; Phase 5 enforces the gate at the extract call site.

`ResolveExtractorsDir` at `internal/discovery/discovery.go:91` currently returns `(path string, label string, error)`. The `label` string is what today distinguishes tiers ("`--extractors-dir`", "`cwd`", "`AUDIT_HOME`", "`~/.config/audit/extractors`"), but string matching across packages is fragile. Refactor the signature to return an explicit tier enum:

```go
// internal/discovery/discovery.go
type Tier int

const (
    TierUnknown    Tier = iota
    TierFlag             // --extractors-dir / --queries-dir
    TierCwd              // cwd-relative extractors/ or pipeline/queries/
    TierAuditHome        // $AUDIT_HOME
    TierConfigDir        // ~/.config/audit/extractors (the auto-extract target)
    TierEmbedded         // queries-only fallback (no extractor tier)
)

func ResolveExtractorsDir(opts ExtractorOpts) (path string, tier Tier, label string, err error)
```

`label` stays for `code-audit status` display; `tier` is the load-bearing typed value used for control flow.

**Caller inventory** (verified via `grep -rn "ResolveExtractorsDir"` excluding tests):
- `internal/cli/extract.go:58` — currently `xdir, _, err := ...`; gains the new `tier` middle return value, gates `EnsureExtractor` on it (per Phase 5 step 1).
- `internal/cli/status.go:56` — currently `xpath, xlabel, xerr := ...`; gains `tier`, used to enrich the printed source line (e.g., "ConfigDir (auto-bootstrap)" vs. "Cwd (live)").
- No other internal callers. Test files at `discovery_test.go` need a signature update but the assertions stay equivalent.

All three updates land in the same PR as the discovery API change to avoid mid-PR compile breakage.

1. In `internal/cli/extract.go`, the **tier-gating logic** sits at exactly one call site (specify with a code comment so future maintainers see the load-bearing invariant):
   ```go
   // Auto-extract gate: only fires when the discovery chain fell through to
   // TierConfigDir (~/.config/audit/extractors). Earlier tiers (Flag, Cwd,
   // AuditHome) signal "user is managing source"; we never mutate those.
   // Pinned by tests 19, 19a, 19b.
   if tier == discovery.TierConfigDir {
       if err := EnsureExtractor(ctx, name); err != nil {
           return err
       }
   }
   ```
2. If the resolved tier is `TierFlag`, `TierCwd`, or `TierAuditHome`, skip `EnsureExtractor` entirely. The user/contributor is managing source themselves.
3. `EnsureExtractor` lives in a new file `internal/cli/bootstrap.go` (separate from `init.go` to keep the `Init` command and the `EnsureExtractor` flow visually distinct, even though they share `layDownExtractor`).

   **Test file split for Phase 5.** Tests divide along the natural seam between *what* and *where*:
   - `internal/cli/bootstrap_test.go` (NEW) owns tests of `EnsureExtractor`/`layDownExtractor` mechanics: tests 13, 14, 15, 16, 17, 17a, 18, 18a — anything about extraction, lock, state.json, bootstrap retry.
   - `internal/cli/extract_test.go` (EXTENDS the existing file) owns tests of the tier-gating logic *inside `extract.go`*: tests 19, 19a, 19b — verifying which tier wins and whether `EnsureExtractor` is even called. The assertions here use a spy on `EnsureExtractor` (interface or function variable) rather than the real implementation, keeping the tier-gating test orthogonal to bootstrap mechanics.
4. **Manifest parse-early invariant.** `EnsureExtractor` parses the extractor's `manifest.toml` (via `manifest.Parse`) **before** calling `layDownExtractor`. A malformed manifest (TOML parse error, missing required fields, schema version out of range) causes `EnsureExtractor` to return the parse error and **not** mutate state.json. The user sees the same error they'd get from the existing `extract` command's manifest-parse step (`extract.go` parses post-discovery; we just move it slightly earlier in the call chain). Pinned by test 18a.

**Tests** (all in `internal/cli/bootstrap_test.go` unless noted):

| # | Test | Phase-dep |
|---|---|---|
| 13 | Fresh `~/.config/audit/extractors/` empty → first `extract` triggers auto-extract + bootstrap → extract succeeds | 5 |
| 14 | Second `extract` with no source changes performs no bootstrap, no file writes (verify via mtimes or sha-cache) | 5 |
| (14a removed — duplicates test 10b in Phase 3; Phase 5's idempotency coverage is test 14 on Extract only) | | |
| 15 | Stale CLEAN files auto-upgrade silently; bootstrap re-runs; state.json's `bootstrapped_at` advances | 5 |
| 16 | Stale DIRTY files print stderr warning naming each file; proceed with on-disk version; bootstrap does NOT re-run | 5 |
| 17 | Two concurrent `extract` calls on a fresh install with explicit synchronization (a `sync.WaitGroup` releases both goroutines simultaneously; the test injects a `runtime.Gosched()` after lock acquisition in `EnsureExtractor` to force interleaving). Assertions: spy on `os/exec` records exactly **1** invocation across both callers; the second caller's `EnsureExtractor` returns `nil`; mtimes of the extractor dir, snapshotted after both callers join, match the snapshot taken at caller 1's completion (no post-caller-1 writes). Designed for determinism, not timing-based. | 5 |
| 17a | Concurrent `extract` where first call's bootstrap fails → first writes `failed`+`LastError` to state.json before releasing lock → second call sees `failed`, retries bootstrap | 5 |
| 18 | Bootstrap failure recorded in state.json (`bootstrap_status: failed`, `LastError` populated); next call retries; on success, transitions to `ok` | 5 |
| 18a | Malformed manifest (TOML parse error or out-of-range schema version) causes `EnsureExtractor` to return the parse error and **not** write to state.json; next call retries (assuming the user fixes the manifest) | 5 |
| 19 | cwd-local `extractors/typescript/` present → tier 2 wins in discovery → `EnsureExtractor` not called → no auto-extract attempted regardless of `~/.config/` state | 5 |
| 19a | `--extractors-dir <empty-path>` given → tier 1 wins → `EnsureExtractor` not called even though resolved path is empty (no surprise mutation of user-specified dirs) | 5 |
| 19b | cwd-local `extractors/` present but missing the requested extractor → tier 2 wins → `EnsureExtractor` not called → extract fails with "no such extractor" rather than silently bootstrapping into `~/.config/` | 5 |

### Phase 6 — `code-audit status` surface

Extend `internal/cli/status.go` to print a per-extractor block:

```
extractors:
  typescript: ~/.config/audit/extractors/typescript [embedded]
    bootstrap: ok (2026-05-31T22:11:08Z)
```

For `failed`, surface the last error one-line. For `pending`, note "will run on next `extract`."

**Tests.** Snapshot test covering each `bootstrap_status` value.

### Phase 7 — docs

1. `README.md` Quick start — drop the `init --from` line for the brew flow. New flow:
   ```bash
   brew install jakebromberg/tap/code-audit
   code-audit extract typescript --root /path/to/your/repo
   # First call auto-bootstraps (~30s); subsequent calls are fast.
   ```
2. `README.md` "From source" section — drop the `init --from <checkout>` + `npm install` post-step.
3. `README.md` — add a new "Environment variables" subsection under "How discovery works" listing `AUDIT_HOME` (tier 3 in the discovery chain — point to `~/.config/audit` to use a non-default location; unset to fall through to the default tier 4). Confirm no new env vars are introduced by this change; the auto-extract path adds zero environment variables.
4. `CLAUDE.md` Operational notes — explicit itemized changes:
   - **Remove** the line currently at `CLAUDE.md:77`: "The TypeScript extractor's `node_modules/` is gitignored. Run `npm install` inside `extractors/typescript/` once per clone." (`npm install` is now automatic via Phase 3's bootstrap.)
   - **Replace** the source-build line I added earlier (`go install ./cmd/code-audit` + `code-audit init --from <checkout>`) with: `go install ./cmd/code-audit` then `code-audit extract <name>` — bootstrap is automatic. Contributors who want the explicit init flow: `code-audit init --from <checkout>` still works and is the right call for live-editing extractor source.
4. New ADR-0008 `extractor-embedding-and-auto-bootstrap.md` — documents:
   - Source-vs-runtime distinction (sources embedded; Node/Swift/Python runtime stays external)
   - Auto-extract trigger gate (tier-4 only)
   - The state.json schema additions (Extractors map, bootstrap_status enum)
   - Manifest schema bump (1 → 2; bootstrap field; schema-1-rejects-bootstrap rule)
   - **Executable-bit heuristic** (shebang detection as v1 default; `[runtime].executable_patterns` regex as the opt-in for future extractors)
   - **`node_modules` under `~/.config/audit/extractors/` rationale** (atomic upgrade semantics require bundling runtime state with source; splitting into `.cache/` introduces `NODE_PATH` complexity and breaks atomicity — LE5 settled)
   - **Symlink-traversal semantics** (`fs.WalkDir` does not follow symlinks; observable change from prior `filepath.WalkDir` behavior; migration guidance for users with symlink-based source trees: check files in directly, or run a pre-extract setup step that materializes the symlinks)
   - **Downgrade migration** (state.json is forward-compatible only; old binaries silently drop the `extractors` field on write; next new-binary run treats it as fresh-map and re-bootstraps once — auto-recovery, no manual intervention required)

   **Scope boundary:** ADR-0008 does *not* amend the discovery chain from ADR-0006. The chain (tiers 1–4) is unchanged. ADR-0008 specifies only what happens when the chain resolves to tier 4 and tier 4 is empty / stale (auto-extract + bootstrap), and how the auto-extract phase walks the source tree (no symlink following). Future ADRs that change the chain itself supersede ADR-0006, not 0008. The chain (tiers 1–4) is unchanged. ADR-0008 specifies only what happens when the chain resolves to tier 4 and tier 4 is empty / stale (auto-extract + bootstrap). Future ADRs that change the chain itself supersede ADR-0006, not 0008.
5. ADR-0006 — add a "see ADR-0008" cross-reference; rephrase "leave extractors external" → "leave extractor *runtime* external; bundle extractor source (per ADR-0008)."

## Tests — TDD index

Each test below is owned by the phase that adds the corresponding code. Red-green-refactor: a failing test lands before the implementation in the same phase. Tests are grouped per-phase in their respective sections above (Phases 1–6); this index summarises them.

| Phase | Test file | Test IDs | Summary |
|---|---|---|---|
| 1 | `internal/genembed/main_test.go` | 1, 2, 3, 4, 4a, 4b, 4c, 4d, 4e, 4f, 4g | Generator flatten/tree/skip/ext/symlink/empty-dir/refusal behavior; drift-guard against `embed.go`'s `//go:generate` CSV |
| 2 | `internal/manifest/parser_test.go` | 5a, 5b, 6, 7a, 7b, 7c | Schema 1 + 2 parsing, schema-1-rejects-bootstrap, bootstrap field optionality, version range |
| 3 | `internal/cli/init_test.go` | 8, 8a, 8b, 9, 10, 10a, 10b, 10c, 10d, 10e | `runBootstrap` invocation/cwd/stderr/cap/ctx, state.json per-extractor map round-trip, missing `extractors` default, backward-compat round-trip via JSON literal, init idempotency, n-a path, nil-map-write-safety, downgrade-recovery simulation |
| 4 | `internal/cli/init_test.go` | 11, 11a, 11b, 12, 12a, 12b, 12c, 12d, 12e | `init` with/without `--from`, idempotency, source-FS interchangeability, symlink no-recurse, shebang exec bit, partial source tree, non-git-dir grace |
| 5 | `internal/cli/bootstrap_test.go` (NEW) | 13, 14, 15, 16, 17, 17a, 18, 18a | `EnsureExtractor`/`layDownExtractor` mechanics: triggering, Extract-layer idempotency, staleness, concurrency, failure-retry, manifest-parse-early |
| 5 | `internal/cli/extract_test.go` (extends existing) | 19, 19a, 19b | Tier-gating verified via spy on `EnsureExtractor` (interface seam): tier-4 calls it; tiers 1–3 do not |
| 6 | `internal/cli/status_test.go` | 20 | Snapshot test for status output: `ok` / `failed` / `pending` / `n-a` rendering |

**Test ownership note.** Tests 8–10c in `init_test.go` own `runBootstrap`'s mechanics (cwd, stderr capture, context cancellation, output cap) and the state.json schema's serialization. Tests 14 and 14a in `bootstrap_test.go` verify the **Extract-layer** idempotency on top of that machinery — that `EnsureExtractor`'s state check causes no `runBootstrap` invocation when state.json says we're current. The two test sets don't duplicate: Phase 3 tests `runBootstrap` directly; Phase 5 tests the conditional-invocation logic that sits above it. Cross-reference comments in both files note this split.

**Pre-merge gates per phase split** (assuming the α/β PR split below):

- **PR α (Phases 1–3)** runs tests 1–10a. Phase 5 tests are scaffolded (file exists, `t.Skip("waiting on Phase 4")`) and tracked as a follow-up in the PR description so the reviewer sees them.
- **PR β (Phases 4–7)** removes the `t.Skip` calls, lands tests 11–20, and verifies all 30+ tests pass together.

## Docs updates (summary)

- `README.md` — Quick start, Install, From source, **new Environment variables subsection** (`AUDIT_HOME`).
- `CLAUDE.md` — Operational notes (itemized in Phase 7: remove the npm-install line; replace the source-build instructions).
- `docs/adr/0008-extractor-embedding-and-auto-bootstrap.md` — new.
- `docs/adr/0006-bundling-and-discovery.md` — amended to cross-reference 0008.
- `extractors/typescript/manifest.toml` — schema bump + bootstrap field.

## Rollout

Pre-1.0 project; no feature flag needed. The error message at `init.go:67-70` ("`--from required in v1`") was a placeholder anticipating exactly this change; removing it is non-breaking. Existing users with state.json from the older binary get one slow `extract` call (bootstrap re-runs because their `extractors` map is missing) then steady state.

**PR split (likely necessary given ~1200-line estimate):**

- **PR α** — Phases 1–3. Embeds extractor source, generalizes the generator, adds bootstrap execution machinery to `init`. `init --from <checkout>` now runs `npm install` automatically. No new auto-extract path yet; brew users still can't run extractors. Binary size grows.
- **PR β** — Phases 4–7. `--from` becomes optional, auto-extract fires on the brew path, status surfaces bootstrap state, docs and ADR-0008 land. This is the user-visible payoff.

If PR α stays under ~600 lines (plausible — phases 1–3 are mostly mechanical), the work can land as one PR. Decide after Phase 3 is implemented.

## Out of scope

Recorded so the boundary is visible:

- **Network fetch.** No `init --from github:...` or release-tarball download. Embedded source is the only source for the brew path.
- **Multi-version extractor support.** Only one extractor source on disk at a time. `~/.config/audit/extractors/<binary-version>/...` directories are not introduced.
- **Bootstrap parallelism across extractors.** Each extractor's lock is independent, but `code-audit report` does not pre-warm all extractors in parallel. Sequential is fine for v1.
- **Windows.** `.goreleaser.yaml` already targets darwin/linux only; `flock(2)` is POSIX. Windows support is a separate concern.
- **A `code-audit doctor` subcommand** that diagnoses bootstrap state, runtime version, etc. Worth considering as a follow-up.
- **Removing `setup_hint`** from the manifest. It still serves as the human-readable fallback printed on bootstrap failure and in `code-audit status` for `bootstrap_status: failed`.
