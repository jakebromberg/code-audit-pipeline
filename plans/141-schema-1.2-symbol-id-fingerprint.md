# Plan — Schema 1.2: `symbol_id`, `fingerprint_v`, `generated_at`, `extractor.source_sha` (closes #141)

## Status of the world (the prerequisite that changes the framing)

Issue #141 was filed against a 1.0 bare-array catalog. Between filing and now the envelope half of #141 shipped under the `1.1` tag (commit `3be4a8ca extractor: extends + references edges + schema v1.1 wrapper`):

- `docs/pipeline-contract.md` already documents `schema_version: "1.1"`, `extractor.{name,language,version}`, `entries: [...]`.
- `extractors/typescript/type-catalog.mjs` already emits the wrapper (`SCHEMA_VERSION = '1.1'`).
- `pipeline/queries/_canonical.jq` already provides the `entries` helper accepting both bare-array and wrapper forms; every cluster query consumes `entries[]`, not `.[]`.
- `internal/catalog/envelope.go` reads the envelope and is forward-compatible with `fingerprint_v` and `generated_at` (`envelope_test.go` line 55 uses `"1.2"` as a forward-compat fixture).
- The Swift extractor's type/function catalog emitters do not currently emit a wrapper because they were authored after 1.1 shipped but landed under different work; `extractors/swift/Sources/swift-catalog/main.swift` to be re-checked during implementation, but per the design notes #137 was supposed to be the v2 ratification.

So the unshipped part of #141 — the part this PR closes — is the **per-entry `symbol_id`**, **top-level `fingerprint_v`**, **top-level `generated_at`**, **`extractor.source_sha` provenance**, the **explicit version-bump rules** (patch / minor / major), the **`pipeline/validate-catalog.mjs` validator**, the **`symbol-id-collisions.jq` audit query**, and the **round-trip stability test**. Per the version-bump rules being introduced here, all of these are *additive* — new optional fields, no removed semantics — so the bump is **1.1 → 1.2**, not 1.1 → 1.1.

This deviates from the literal text of issue #141 (which calls the bump "1.1"). Calling it 1.2 is the honest read: 1.1 already covered the envelope and TS provenance block; this PR adds `symbol_id`, `fingerprint_v`, `generated_at`, `extractor.source_sha`. The PR body will explain the rename.

## Scope

In:

- Add per-entry `symbol_id` (formula `sha1(package + "/" + file + "/" + name + "/" + kind).toLowerCase()`).
- Add top-level `fingerprint_v` (string, default `"shape_sig:1"` for the current `shape_sig` algorithm).
- Add top-level `generated_at` (ISO-8601 string).
- Add `extractor.source_sha` (git SHA of the extractor's source tree, or `"unknown"`).
- Document the version-bump rules (patch = doc clarification; minor = additive; major = redefines/removes).
- Bump TS extractor (`type-catalog.mjs`, `function-catalog.mjs`) and `file-hashes.mjs` envelope-emitting paths from `1.1` to `1.2`. Confirm the Swift extractor's emitters as part of implementation; if they already emit a wrapper, also bump; if they don't, leave them alone (`pipeline/validate-catalog.mjs` will accept a bare array for the deprecation window, same as `_canonical.jq` does).
- Add `pipeline/validate-catalog.mjs` (small Node script with no deps beyond stdlib).
- Add `pipeline/queries/symbol-id-collisions.jq` audit query (front-matter compliant, cluster shape, both text and JSONL modes).
- Add a round-trip stability test shell harness in `pipeline/queries/_tests/test_envelope_roundtrip.sh`.
- Update `docs/case-study.md` and `README.md` example JSON snippets to reflect 1.2.
- Re-run `go generate ./...` and commit regenerated embeds (per CLAUDE.md operational notes — CI enforces with `git status --porcelain -- cmd/code-audit/queries cmd/code-audit/extractors`).

Out:

- Diff machinery (#117 family) — explicitly downstream; this PR only ratifies the fields the diff tool will read.
- Cross-repo refusal logic on `fingerprint_v` mismatch — also #117 / #118 follow-up.
- Schema v2 two-tier (`language_data.*`, `relations[]`, `core_projection_complete`, `omitted_features[]`) — that's #137 (the next PR, stacked on this one).

## Implementation order (TDD-first)

Standard red-green-refactor; the validator and the collisions audit query are the natural unit-test surfaces.

### Step 1 — Contract document

Edit `docs/pipeline-contract.md`:

1. Bump every `schema_version: "1.1"` example to `"1.2"`. There are four (type-catalog wrapper at line 21, references-graph artifact at line 285, files artifact at line 401, function-catalog at line 473). Leave `package-graph`'s `schema_version: "1"` alone — that's an integer-scheme catalog kind.
2. Under the type-catalog wrapper example (around line 19-66), add four new fields:
   - `"fingerprint_v": "shape_sig:1"` at top level.
   - `"generated_at": "2026-06-04T19:00:00Z"` at top level.
   - `"source_sha": "<git sha or 'unknown'>"` inside `extractor`.
   - `"symbol_id": "<sha1 hex>"` inside the entry object (optional, not in the required-fields list).
3. After the existing `## Schema versioning and back-compat` section, add a new `### Version-bump rules` subsection:

   > **Patch (1.x.y → 1.x.(y+1))** — documentation clarification only. No schema change. Consumers see no observable difference.
   >
   > **Minor (1.x → 1.(x+1))** — additive change. A new optional per-entry field; a new optional top-level key; a new permitted `kind` value. Existing consumers continue to work; new consumers can read the new field.
   >
   > **Major (1.x → 2.0)** — redefines or removes existing semantics. Renaming a kind, changing `shape_sig` normalization, removing a field. The diff machinery (#117) refuses to compare across major bumps; warns across minor.
   >
   > 1.2 is a minor bump: `symbol_id`, `fingerprint_v`, `generated_at`, `extractor.source_sha` are all additive and optional from a consumer's perspective. Existing queries continue to work against 1.2 catalogs unchanged.

4. After the version-bump rules, add a `### Identity and provenance` subsection documenting:
   - **`symbol_id`** — `sha1(package + "/" + file + "/" + name + "/" + kind).toLowerCase()`. Hex string. Optional per entry; consumers synthesize the same value on read when absent. Extractors should emit when they can. The audit query `pipeline/queries/symbol-id-collisions.jq` flags any catalog where the formula collides. Real codebases have not surfaced a collision in the 595-entry case-study corpus.
   - **`fingerprint_v`** — algorithm tag for shape-clustering signatures (`"shape_sig:1"` is the current `sorted | join("|") | lower` definition). Bumping the algorithm bumps the tag. Cluster queries that compare `shape_sig` across catalogs check this matches before joining. Convention: `"<algorithm>:<version>"`.
   - **`generated_at`** — ISO-8601 timestamp recorded at extraction time. Diff and snapshot tooling use it; queries do not depend on it.
   - **`extractor.source_sha`** — git SHA of the extractor's own source tree. For extractors vendored as binaries or run outside a git checkout, `"unknown"` plus a stderr warning at extraction time (and at diff time). This is the load-bearing field for "did the extractor itself change between two catalogs?"

### Step 2 — Tests first (red)

#### 2a. `pipeline/queries/_tests/test_envelope_roundtrip.sh`

Shell test that:

1. Constructs a tiny bare-array catalog `[{...}, {...}]` in a tmpdir.
2. Wraps it: `jq '{schema_version: "1.0", entries: .}' < bare.json > wrapped.json`.
3. Unwraps it: `jq '.entries' < wrapped.json > unwrapped.json`.
4. Asserts `diff bare.json unwrapped.json` is empty (byte-identical).

This is the literal round-trip stability KPI from #141.

#### 2b. `pipeline/queries/_tests/test_validate_catalog.sh`

Shell test that drives `pipeline/validate-catalog.mjs`:

1. Valid 1.2 catalog with all fields → exit 0, no stderr noise.
2. Valid 1.1 catalog without new fields → exit 0 (back-compat).
3. Bare-array catalog → exit 0 with a stderr warning.
4. Missing `schema_version` on a wrapper → exit 1.
5. Wrong `schema_version` format (`"v1.2"` instead of `"1.2"`) → exit 1.
6. Catalog with `symbol_id` present but mismatched against the derived sha1 → exit 1.
7. Entry missing a required field (`name` or `kind` or `package` or `file` or `line`) → exit 1 with file:line context.
8. `entries` not an array → exit 1.

#### 2c. `pipeline/queries/_tests/test_symbol_id_collisions.sh` (or extend `test_queries_integration.sh`)

Drive `symbol-id-collisions.jq` against fixtures:

1. Catalog with no collisions → empty output in text mode, no rows in JSONL.
2. Catalog with two entries sharing `(package, file, name, kind)` but different lines → one cluster of size 2.
3. Catalog where `symbol_id` is absent on entries → query synthesizes from `(package, file, name, kind)` and still detects the collision.

Prefer extending `test_queries_integration.sh` (the existing harness covers every query end-to-end). Add a fixture catalog at `pipeline/queries/_tests/fixtures/symbol-id-collisions-sample.json` (matching the filename used in Step 7's files-touched table).

### Step 3 — `pipeline/validate-catalog.mjs` (green)

Node script, no external deps. CLI: `pipeline/validate-catalog.mjs <catalog.json>` → exit 0 on valid, exit 1 with diagnostic on stderr.

Validation rules:

- Read and `JSON.parse` the file.
- If top-level is an array: emit `WARNING: pre-1.1 bare-array catalog at <path>; consumers should upgrade to wrapper` on stderr and validate the entries as below. Exit 0.
- If top-level is an object: require `schema_version` matching `/^1\.\d+$/`. Require `entries` to be an array. `extractor`, `fingerprint_v`, `generated_at` are validated when present but optional.
- For each entry: require `name` (string), `kind` (string), `package` (string), `file` (string), `line` (number ≥ 1). `extends`, `references`, `references_count` are required on entries other than `kind: "import"` rows (which have their own shape — but the validator is permissive about per-kind variation; require fields documented in the contract's "Required fields" section).
- If an entry has `symbol_id`, compute `sha1(package + "/" + file + "/" + name + "/" + kind).toLowerCase()` and compare. Mismatch → fail with the entry's `(package, file, name, kind)` and both hashes printed. **This check applies to all entries regardless of envelope form (bare-array or wrapped) — a bare-array entry that carries a `symbol_id` is still subject to the formula check.**

Implementation: about 80-120 lines of Node. `crypto.createHash('sha1')` for the sha; no other module imports beyond `node:fs`, `node:crypto`, `node:process`.

### Step 4 — `pipeline/queries/symbol-id-collisions.jq` (green)

Front-matter compliant query. Schema:

```jq
# symbol-id-collisions.jq
# ...

#! query: symbol-id-collisions
#! shape: cluster
#! catalog: type-catalog
#! formats: text, jsonl
#! desc: Flag entries sharing a derived symbol_id (audit query for sha1 collisions in the contract).

include "_canonical";

# Derive symbol_id when absent — use the same formula as docs/pipeline-contract.md.
# Note: jq has no sha1; we group by the input tuple instead. The "collision" is on the
# input tuple (package, file, name, kind), which is what sha1 is supposed to hash.
# This is a strictly stronger check than the sha1 hash comparison — a tuple collision
# guarantees a sha1 collision (the formula is deterministic) without us needing to
# compute sha1 in jq.

[ entries[] | {
    key: "\(.package)/\(.file)/\(.name)/\(.kind)",
    decl: .
  } ]
| group_by(.key)
| map(select(length > 1))
| map({
    cluster_id: ("symbol-id-collisions:" + .[0].key),
    query: "symbol-id-collisions",
    shape: "cluster",
    members: map(.decl)
  })
| .[]
| if output_format == "jsonl" then @json
  else
    "cid=\(.cluster_id)  members=\(.members | length)\n" +
    (.members | map("  \(.package)/\(.file):\(.line) \(.kind) \(.name)") | join("\n"))
  end
```

(Refine against canonical envelope helpers in `_canonical.jq` during implementation — the above is structural sketch.)

### Step 5 — TS extractor bump

Edit `extractors/typescript/type-catalog.mjs`:

1. `const SCHEMA_VERSION = '1.2';`
2. Compute `extractor.source_sha` at startup: shell out to `git rev-parse HEAD` inside the extractor's source dir. If the call fails (not a git checkout, `git` missing from PATH, or the source tree was extracted from the embedded binary via #241), set `"unknown"` and emit exactly this stderr line: `warning: extractor source not in a git checkout; source_sha recorded as "unknown"`. Cache the result so we don't shell out per file. The exact stderr-warning format is documented in the new "Identity and provenance" section of `pipeline-contract.md` (Step 1) so consumers can grep it.
3. Compute `generated_at` once at startup: `new Date().toISOString()`. **Cache it and pass it to every sibling-artifact write** (the catalog itself, `references.json`, `files.json`). Same wall-clock value across every artifact produced by one extractor invocation. Extend `writeSiblingArtifact` in `_lib/artifacts.mjs` to accept `generated_at` and `fingerprint_v` parameters and embed them in the wrapper.
4. Add `fingerprint_v: "shape_sig:1"` to the envelope.
5. For each entry, compute `symbol_id`: `crypto.createHash('sha1').update(\`${pkg}/${file}/${name}/${kind}\`).digest('hex')`. Entry is built once; compute the hash at construction time. Emit `symbol_id` on every entry.

Mirror the changes in `extractors/typescript/function-catalog.mjs` and `extractors/file-hashes/file-hashes.mjs` — same `SCHEMA_VERSION` bump, same `source_sha` / `generated_at` / `fingerprint_v` additions, same stderr-warning format. The `symbol_id` formula on function-catalog uses the same fields (`name` is `ClassName.methodName` for methods, which is fine).

Check `extractors/typescript/_lib/artifacts.mjs` (`writeSiblingArtifact`) — it accepts `schema_version` and `extractorMeta` as parameters. Extend its signature to also accept `generated_at` and `fingerprint_v` so the sibling artifacts (`references.json`, `files.json`) inherit the bump.

**Swift extractor explicit status.** `extractors/swift/Sources/swift-catalog/main.swift` currently writes a bare JSON array (no envelope) for the type and function catalogs (`package-graph` already has its own `schema_version: "1"`). This PR does NOT change Swift. Queries continue to work because `_canonical.jq`'s `entries` helper accepts both forms. The case-study corpus (KPI check) and any cross-language reports will mix envelope versions until #137 (Schema v2 ratification) bumps Swift. The validator (Step 3) emits a stderr warning on bare arrays so the mismatch is observable; queries themselves never break.

### Step 6 — Embeds

After all canonical edits in `pipeline/queries/` and `extractors/`, run `go generate ./...` to refresh `cmd/code-audit/queries/` and `cmd/code-audit/extractors/`. The `internal/genembed` tool walks the source directory and overwrites the destination — every new `.jq` file in `pipeline/queries/` (including `symbol-id-collisions.jq`) gets a generated copy automatically. Verify with `git status --porcelain -- cmd/code-audit/queries cmd/code-audit/extractors` that the new file is present (and that all updated TS extractor files appear) before staging. CI's gate runs the same `git status --porcelain` check and fails if anything is out of sync.

Also `git add` the new embed files explicitly (they are NOT in `.gitignore` per the recent `fix(release)` commit) so the commit captures them.

### Step 7 — Doc snippet sweep

Update example JSON snippets that bake `schema_version` literally:

- `docs/case-study.md` — grep for `"schema_version"` and bump.
- `README.md` — same.
- `docs/substrate.md` — same.
- `CLAUDE.md` — grep for any schema-version or contract reference; bump if present (likely a no-op since CLAUDE.md is principle-level, not example-level).

Any test fixture that bakes `"1.1"` and is NOT testing backward compat should be bumped to `"1.2"`. Tests that explicitly exercise back-compat (e.g., `envelope_test.go` line 47 testing a bare array, line 55 testing forward-compat with `"1.2"`) stay as-is — those are the regression guards.

## KPIs (from #141, restated for 1.2)

- **All existing queries pass against a 1.2 envelope catalog with no line changes.** The query side already consumes `entries[]` via `_canonical.jq`; `1.2` is a top-level metadata bump, no per-entry shape change. Regression: run `test_queries_integration.sh` against a fixture with `1.2` wrapper.
- **Round-trip stability.** `test_envelope_roundtrip.sh` is the explicit assertion.
- **Zero `symbol_id` collisions on the case-study corpus.** Run the new query against `pipeline/queries/_tests/fixtures/case-study-595.json` (if present) — if a fixture corpus this large doesn't exist, settle for "zero collisions on the integration-test fixtures" and document the case-study claim as a manual check.
- **Schema-version refusal works.** Out of scope here; documented as a hook the diff machinery (#117) will use. The validator's behavior — exit 1 on malformed `schema_version` — is the runtime version of the refusal.

## Risks and open questions

- **`source_sha` in a `go install`-d binary.** The TS extractor is shipped as `.mjs` files embedded in the Go binary (`cmd/code-audit/extractors/typescript/`). The embedded copy has no `.git` directory. When the binary auto-extracts the extractor under `~/.cache/code-audit/extractors/` (per #241) and runs it, `git rev-parse HEAD` will fail and the extractor will record `"unknown"`. That's the intended behavior for "vendored binary." The binary itself knows its build SHA via `debug.ReadBuildInfo` (#247) and could pass it as a CLI flag (`--source-sha <hex>`) for downstream consumers; that's a follow-up enhancement, not in scope.
- **`fingerprint_v` registry.** Today there's only `"shape_sig:1"`. Adding `"body_hash:1"` for function-catalog body clustering and `"field_names_sig:1"` for the field-names-only sig variant (#118's needs) is natural growth; the registry stays prose-documented in the contract until a second algorithm variant ships.
- **Schema-bump churn.** Going from 1.1 → 1.2 within a few commits is a smell. The mitigation is that 1.1's introduction (envelope) and 1.2's introduction (provenance + identity) are both *additive* — consumers don't break across either bump. A consumer that already handles 1.1 handles 1.2 by ignoring the new optional fields.
- **The TS extractor's `source_sha` shells out to `git`.** If `git` isn't on the PATH (rare on dev machines, plausible in CI containers), shelling out fails. Same fallback: record `"unknown"`, emit a stderr warning. Test this path in `test_smoke.sh`.
- **Coordination with Lane A (#217 + #222).** Lane A adds `conforms_to: string[]` to the type record (a per-entry additive field; minor bump). If Lane A lands first, this PR rebases cleanly — `conforms_to` is an entry field, doesn't touch the envelope. If this PR lands first, Lane A bumps `1.2` → `1.3` for its addition. No collision on `docs/pipeline-contract.md` other than line-position drift in the schema-version examples.

## Files touched (estimate)

| File | Change | Lines (rough) |
|---|---|---|
| `docs/pipeline-contract.md` | Add 4 fields, version-bump rules, identity-and-provenance section | +80 / −10 |
| `extractors/typescript/type-catalog.mjs` | Bump SCHEMA_VERSION, add source_sha + generated_at + fingerprint_v + symbol_id | +40 |
| `extractors/typescript/function-catalog.mjs` | Same | +30 |
| `extractors/file-hashes/file-hashes.mjs` | Same | +20 |
| `pipeline/validate-catalog.mjs` | New file | +120 |
| `pipeline/queries/symbol-id-collisions.jq` | New file | +40 |
| `pipeline/queries/_tests/test_envelope_roundtrip.sh` | New file | +30 |
| `pipeline/queries/_tests/test_validate_catalog.sh` | New file | +60 |
| `pipeline/queries/_tests/fixtures/symbol-id-collision-sample.json` | New file | +30 |
| `pipeline/queries/_tests/test_queries_integration.sh` | Add symbol-id-collisions cases | +40 |
| `cmd/code-audit/queries/symbol-id-collisions.jq` | Regenerated embed | +40 |
| `cmd/code-audit/extractors/typescript/type-catalog.mjs` | Regenerated embed | +40 |
| `cmd/code-audit/extractors/typescript/function-catalog.mjs` | Regenerated embed | +30 |
| `cmd/code-audit/extractors/file-hashes/file-hashes.mjs` | Regenerated embed | +20 |
| `docs/case-study.md` | Bump schema_version in examples | +2 / −2 |
| `README.md` | Bump schema_version in examples | +2 / −2 |

Estimated diff: ~650 lines including the regenerated embeds. Under the 1000-line CLAUDE.md cap. If implementation reveals more sites (e.g., goldens) that drive it over, split the embed regen into a follow-up sub-PR but ship the canonical sources in one PR.

## CI gates to pass locally before pushing

- `go generate ./...` runs clean.
- `git status --porcelain -- cmd/code-audit/queries cmd/code-audit/extractors` is empty.
- `go vet ./...` clean.
- `go test ./...` green.
- `cd extractors/typescript && npm test` green.
- `extractors/typescript/tests/test_smoke.sh` green.
- `pipeline/queries/_tests/test_canonical.sh` green.
- `pipeline/queries/_tests/test_queries_integration.sh` green.
- `pipeline/queries/_tests/test_gojq_parity.sh` green.
- `pipeline/queries/_tests/test_envelope_roundtrip.sh` green (new).
- `pipeline/queries/_tests/test_validate_catalog.sh` green (new).

## Issue / PR plumbing

- Issue #141 stays open until this PR merges; PR body says `Closes #141`.
- Cross-reference the triage tracker `#256` in the PR body for context.
- Anonymity: no Claude attribution in commit message, PR title, or PR body.
