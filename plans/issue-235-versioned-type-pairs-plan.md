# Plan: `versioned-type-pairs` query (#235)

## Goal

Add a substrate-side jq cluster query under `pipeline/queries/` that groups type-catalog entries by base name after stripping a trailing `V?\d+` suffix and emits clusters with ≥ 2 distinct full names per `(package, base_name)`. The cluster carries a `shapes_match` flag (true when every member shares one `shape_sig`) and version-sorted members. No extractor changes; pure consumer of the existing `type-catalog.json`.

This is the simplest of the four stalled-migration queries under #226's bullet. Filing it first lets the conventions get exercised before the harder three (`deprecated-with-active-callers`, `sibling-cadence-divergence`, `coexisting-old-and-new-imports`) follow.

## Files

| Path | Change |
|---|---|
| `pipeline/queries/versioned-type-pairs.jq` | NEW. The query. |
| `pipeline/queries/_tests/fixtures/versioned-type-pairs.input.json` | NEW. Fixture catalog covering pair, triple, no-pair, shape-divergence, and protocol-suffix false-positive cases. |
| `pipeline/queries/_tests/test_queries_integration.sh` | EDIT. Register two assertions: `assert_jsonl_has_prefix` for envelope + uniqueness, and a small semantic test for member ordering and `shapes_match`. |

## Implementation

### Base-name strip

The regex applied to each entry's `.name`:

```
gsub("(?i)V?[0-9]+$"; "")
```

Outcomes:

| Input name | Stripped base | Version (parsed) |
|---|---|---|
| `Track` | `Track` | 0 (no suffix) |
| `TrackV1` | `Track` | 1 |
| `TrackV2` | `Track` | 2 |
| `Trackv3` | `Track` | 3 |
| `Track2` | `Track` | 2 (bare digits) |
| `IPv4` | `IP` | 4 (false positive — documented) |
| `Track1V2` | `Track1V` | 2 — pathological; rare; out of scope to handle |

The `(?i)V?` is intentional. `V?[0-9]+` covers both `FooV2` and `Foo2`; case-insensitive `V` matches `Foov2` if it occurs.

`gsub` is jq's regex substitution. It is supported by both stedolan/jq and gojq (the parity harness already exercises gsub elsewhere — `migration-progress.jq:69` calls it).

### Version extraction

Per entry: capture the suffix as integer.

```
($e.name | match("(?i)V?([0-9]+)$"; "x")) as $m
| (if $m == null then 0 else ($m.captures[0].string | tonumber) end) as $version
```

`0` is the sentinel for the unsuffixed baseline. This sorts ahead of any explicit version, so the baseline always appears first.

### Filtering

Mirrors `name-collisions.jq` exactly:

```
[ entries[]
  | select((.generated // false) != true)
  | select(.kind | startswith("type-alias") or . == "interface" or . == "zod-object" or . == "drizzle-table")
]
```

`INCLUDE_GENERATED=true` overrides the generated filter (matching `migration-progress.jq`).

`PACKAGE` and `KIND_PREFIX` env knobs match the convention in `migration-progress.jq:52-58`.

### Grouping rule

Group entries by `[.package, .base_name]`. For each group:

- Drop if `(members | map(.name) | unique | length) < 2` — single-name groups (e.g., a stand-alone `Track` with no sibling) are noise.
- Drop if every member's parsed version is `0` — the group has no version-suffixed member, so the base-name match is coincidence, not a migration signal.

### Envelope

```jsonc
{
  "cluster_id": "versioned-type-pairs:<package>/<base_name>",
  "query": "versioned-type-pairs",
  "shape": "cluster",
  "base_name": "Track",
  "package": "main",
  "shapes_match": true,
  "members": [
    { "name": "Track",   "kind": "interface", "version": 0, "package": "main", "file": "src/track.ts",    "line": 8,  "shape_sig": "...", "touched_in_window": false },
    { "name": "TrackV2", "kind": "interface", "version": 2, "package": "main", "file": "src/track-v2.ts", "line": 12, "shape_sig": "...", "touched_in_window": true  }
  ]
}
```

- `shapes_match`: `members | map(.shape_sig) | unique | length == 1` (and the unique value is non-null).
- `members`: sorted by `version` ascending, then `file`, then `line` for stability when two members share a version (shouldn't happen on a real catalog but is defensive).

### Cluster_id

`versioned-type-pairs:<package>/<base_name>`. Single-name slot uses the `cluster_id_single_name` helper with the slot value `"\(package)/\(base_name)"`. This keeps it parseable by the existing `:` split convention while embedding the two-key composite as a `/`-joined segment. No spaces in package or type names by language rule, so the slot is whitespace-safe.

### Sorting between clusters

`sort_by(.package, .base_name)`. Stable, alphabetical.

### Text mode

```
TrackV2 ↔ Track  (shapes match, 2 members) cid=versioned-type-pairs:main/Track
    Track    [interface] main:src/track.ts:8       sig=id:string|title:string
  * TrackV2  [interface] main:src/track-v2.ts:12   sig=id:string|title:string|tags:string[]
```

The `*` marker on touched-in-window members matches the convention in `migration-progress.jq:102` and `dead-code.jq:74`.

The header line names the highest-version member, then `↔`, then `base_name` for readability. The `shapes_match` flag renders as "shapes match" / "shapes diverge". cid trails the line as the standard convention.

## Tests

### Fixture: `_tests/fixtures/versioned-type-pairs.input.json`

Synthetic entries chosen to exercise every branch:

1. `Track` + `TrackV2` — same shape (`id:string`). Expect: emitted, `shapes_match=true`, two members sorted 0 then 2.
2. `Episode` + `EpisodeV2` + `EpisodeV3` — diverged shapes. Expect: emitted, `shapes_match=false`, three members sorted 0/2/3.
3. `Listener` — no sibling. Expect: not emitted.
4. `LegacyShow` + `Show` — `Show` strips to `Show`; `LegacyShow` strips to `LegacyShow`. Different base names → not grouped. Expect: not emitted. (Out of scope for this query; tracked as follow-up.)
5. `IPv4` + `IPv6` — known false positive class. `IPv4` → base `IP`, version 4; `IPv6` → base `IP`, version 6. Both share package, so they group. Expect: **emitted** with `shapes_match=true` (both `{addr:string}` in the fixture). Documented as a known false positive.
6. `OldZ` + `OldZV2` — `OldZ` (version 0) + `OldZV2` (version 2), different shapes, in package `shared`. Expect: emitted in the `shared` package, separate cluster from the `main` package groups.
7. Plus a `generated: true` entry that would otherwise pair, to confirm generated exclusion. Expect: not emitted (excluded by default filter); will be emitted under `INCLUDE_GENERATED=true`.

### Integration assertions

```bash
VTP_FIXTURE="$FIXTURES_DIR/versioned-type-pairs.input.json"
```

1. `assert_jsonl_has_prefix versioned-type-pairs.jq "$VTP_FIXTURE" "versioned-type-pairs:"` — envelope + cluster_id uniqueness.
2. A small semantic check (analog to `assert_migration_progress_semantic`) verifying:
   - Three clusters emitted by default (Track, Episode, IPv4-IPv6).
   - `Track` cluster: `shapes_match=true`, two members, versions [0, 2].
   - `Episode` cluster: `shapes_match=false`, three members, versions [0, 2, 3].
   - `OldZ` cluster: present in `shared`.
3. `INCLUDE_GENERATED=true` test confirms the generated-paired entry now appears.
4. `PACKAGE=main` filter test: `OldZ`/`shared` cluster drops; counts adjust.
5. `KIND_PREFIX=interface` filter test: drops `zod-object`/`drizzle-table` members.
6. `assert_text_has_cid` — text mode renders `cid=` markers.

### gojq parity

The existing `test_gojq_parity.sh` harness picks up new queries automatically when they live under `pipeline/queries/`. Confirm by running it locally.

## CLI / manifest

This query is purely a `pipeline/queries/*.jq` file. No manifest registration is required — manifests cover extractors, not queries. The renderer (`internal/render/`) discovers cluster envelopes via the `query` / `shape` fields, which this envelope provides.

## Front-matter

```
#! query: versioned-type-pairs
#! shape: cluster
#! catalog: type-catalog
#! env: PACKAGE string ""
#! env: KIND_PREFIX string ""
#! env: INCLUDE_GENERATED string ""
#! formats: text, jsonl
#! desc: Surface type-catalog declarations sharing a base name after stripping V<n>/<n> suffix.
```

Verified against the schema in `extractors/typescript/manifest.toml` and the front-matter grammar enforced by `cmd/code-audit/`.

## Local CI

Before pushing:

```bash
cd "$(git rev-parse --show-toplevel)"
gofmt -l . | tee /tmp/gofmt.out  # must be empty
go vet ./...
go test ./...
pipeline/queries/_tests/test_queries_integration.sh
pipeline/queries/_tests/test_gojq_parity.sh
```

All green before the PR opens.

## Acceptance

- `pipeline/queries/versioned-type-pairs.jq` exists and conforms to the cluster envelope and front-matter grammar.
- Fixture + integration assertions land under `pipeline/queries/_tests/`.
- Local CI (vet, test, integration, parity) passes.
- PR opens with `Closes #235` and is registered against `main`.

## Non-goals (explicitly out of scope)

- The `NewFoo` / `LegacyFoo` / `OldFoo` prefix variant — a separate query.
- The bare `Foo2` cluster outside the `(?i)V?` suffix shape — partially covered (the bare-digit clause matches it), but no dedicated handling.
- Function-catalog support — types only at v1; the same heuristic could trivially extend if there's a use case, but no current ask.
- Cross-package pairing (`main.Track` ↔ `shared.TrackV2`) — out; grouping is `(package, base_name)` because shadow detection is a separate query.
- Acceptlist for the protocol-suffix false-positive class — out; documented and surfaced.
