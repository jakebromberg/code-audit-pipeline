# C — Catalog storage substrate (Cloudflare R2 landing zone)

**Parent:** [#118 — Cross-repo queries — merging N catalogs across the org](https://github.com/jakebromberg/code-audit-pipeline/issues/118).
**Sibling:** [#117 — per-repo temporal snapshot store](https://github.com/jakebromberg/code-audit-pipeline/issues/117).
**Coordinates with:** [D — Per-repo CI publication](118-D-ci-publication.md).
**Blocks:** D, E.

## 1. Context summary

The substrate is the **landing zone where per-repo JSON catalogs are published on every push to `main`**, plus the **local tooling that pulls them into `/tmp/wxyc-audit/catalogs/`** so `jq` queries can merge them. It is read-mostly: one publish on each repo's CI push, many reads from auditors' laptops.

**What it stores.** Object-shaped catalogs per `(repo, commit_sha)`. One `index.json` enumerates the latest published catalog per repo so a fetcher can resolve URLs without listing the bucket.

**What it does not store.** Historical per-commit snapshots over time — that's #117's per-repo temporal store. The two surfaces can share infrastructure (same bucket, different prefixes) but have different keying, retention, and access patterns:

| Concern | #118 substrate (this) | #117 snapshot store |
|---|---|---|
| Keying | `(repo, latest)` mutable pointer + content-addressable per-SHA | `(repo, every-snapshot, immutable)` |
| Query shape | "merge N latest" | "diff t0 vs t1 within one repo" |
| Retention | last few revisions per repo for rollback | per #117's tag-keep / day-keep / week-keep policy |
| Caller | `pipeline/fetch-catalogs.sh` | `pipeline/diff.mjs` |

They can coexist as `catalogs/<repo>/latest.json` and `snapshots/<repo>/<date>__<sha>.json.zst` under the same bucket, but they are distinct surfaces — the substrate is *flat-current* while snapshots are *temporal-archival*.

**Local end-to-end workflow.**

```
$ pipeline/fetch-catalogs.sh           # pulls index.json, then 30 latest.json files
$ cd /tmp/wxyc-audit/catalogs/
$ jq -s 'map(.entries) | add' */latest.json > merged-entries.json
$ jq -f /path/to/cross-package-shadows.jq merged-entries.json
$ jq -r --arg pkg "@wxyc/shared" -f consumers-of.jq merged-entries.json
```

The substrate's job ends when `merged-entries.json` exists locally. Everything downstream is unchanged `jq`.

## 2. Functional requirements

### 2.1 File layout

```
catalogs/
  index.json                                       # manifest, see schema below
  by-repo/
    wxyc-dj-site/
      latest.json                                  # NOT a symlink — see 2.3
      2026-05-25T14-33-21Z_abc123.json             # ISO-8601 + short SHA
      2026-05-24T09-12-08Z_def456.json             # last N kept for rollback
    wxyc-shared/
      latest.json
      ...
```

Refinements from #118's proposed layout:

- `by-repo/` prefix isolates this substrate from the snapshot store (`snapshots/`) and any future surface that lives in the same bucket.
- **Use sortable ISO-8601 timestamps** (`2026-05-25T14-33-21Z_abc123.json`) so bucket listing is chronologically sorted by default. The `latest.json` lookup still goes through `index.json`, but human-debugging the bucket via `aws s3 ls` (or `wrangler r2 object list`) is much easier.
- Slashes in repo names are flattened to dashes (`wxyc/dj-site` → `wxyc-dj-site`) so the path is a single bucket prefix segment. The full canonical name lives inside `index.json` and inside each catalog's metadata block.

### 2.2 `index.json` schema

```json
{
  "schema_version": "1.0",
  "generated_at": "2026-05-25T14:33:21Z",
  "bucket": "wxyc-catalogs",
  "region": "auto",
  "repos": [
    {
      "repo": "wxyc/dj-site",
      "path_segment": "wxyc-dj-site",
      "latest": {
        "key": "by-repo/wxyc-dj-site/2026-05-25T14-33-21Z_abc123.json",
        "commit_sha": "abc1234567890abcdef1234567890abcdef12",
        "short_sha": "abc123",
        "published_at": "2026-05-25T14:33:21Z",
        "extractor": {"name": "type-catalog", "language": "typescript", "version": "1.3.0"},
        "size_bytes": 184320,
        "entry_count": 595,
        "sha256": "..."
      },
      "history_keys": [
        "by-repo/wxyc-dj-site/2026-05-24T09-12-08Z_def456.json"
      ],
      "status": "ok"
    },
    {
      "repo": "wxyc/legacy-thing",
      "path_segment": "wxyc-legacy-thing",
      "latest": null,
      "status": "stale",
      "last_seen": "2026-04-01T00:00:00Z",
      "reason": "no successful publish in 60 days"
    }
  ],
  "coverage": {
    "total_known_repos": 30,
    "ok": 28,
    "stale": 1,
    "failed_last_run": 1
  }
}
```

The `coverage` block is the input to `pipeline/coverage.jq` (see [E](118-E-operational-safety.md)) — every cross-repo report prints `28/30 repos covered` as its first line.

### 2.3 `latest.json` semantics — JSON pointer, not symlink

`latest.json` is a JSON file containing a pointer, not an S3 symlink (S3 has no symlinks) and not a duplicated copy of the SHA-keyed object.

```json
{
  "kind": "latest-pointer",
  "repo": "wxyc/dj-site",
  "target_key": "by-repo/wxyc-dj-site/2026-05-25T14-33-21Z_abc123.json",
  "commit_sha": "abc1234...",
  "published_at": "2026-05-25T14:33:21Z",
  "sha256": "..."
}
```

Rationale:

1. **No duplicated bytes.** A pointer is ~300 bytes; the catalog can be 500KB. Duplicating per push triples storage cost vs the bucket lifecycle savings.
2. **Atomic swap.** PUT is atomic per object; replacing `latest.json` flips the pointer instantly without a window where two readers see inconsistent state.
3. **Content-addressable verification.** `sha256` lets the fetcher detect a stale pointer (pointed object expired) and fall back to listing `history_keys` from `index.json`.

The fetcher does two GETs per repo (`latest.json` → resolved SHA-keyed object), but the extra round-trip is dwarfed by the catalog download itself.

### 2.4 Per-repo path convention

`by-repo/<flattened-repo-name>/<iso8601-utc>_<short-sha>.json`. SHA-keyed objects are **immutable** (write-once); only `latest.json` and `index.json` are mutable.

### 2.5 What gets uploaded on each CI run (contract with D)

Per push to `main` for repo `R` at SHA `S`:

1. `PUT by-repo/<R>/<timestamp>_<short-sha>.json` (the SHA-keyed catalog, immutable)
2. `PUT by-repo/<R>/latest.json` (the pointer)
3. `PATCH index.json` (atomically rewrite: see §7 — prefer rewriting from a bucket listing over append-on-write)

The catalog is published as the extractor's bare stdout JSON wrapped in the top-level object block per [A](118-A-schema-v2.md). The CI workflow ([D](118-D-ci-publication.md)) is responsible for producing the file; the substrate only defines what bucket keys it goes to.

### 2.6 Retention

**Per repo, keep the last 10 SHA-keyed catalogs** in `by-repo/<R>/`. Older ones are pruned by bucket lifecycle rule — pruning is bucket-managed, not in `publish-catalog.sh`.

Why 10 and not 1: enables rollback if a bad extractor version corrupts `latest.json`, and gives auditors a small window for "merge as of yesterday" without invoking the snapshot store. Tag/release-keyed snapshots live in `snapshots/` per #117 with their own (forever) retention.

### 2.7 Access patterns

- **Reads**: bursty during audits (one auditor running `fetch-catalogs.sh` makes 30 GETs + 30 conditional GETs in ~3 seconds), otherwise quiet. **Reads are anonymous (public bucket per resolved decisions).**
- **Writes**: ~5-15 per day per repo across 30 repos ≈ 150-450 writes/day total. Pure object PUT.

### 2.8 Auth / permissions model

**Public-read** on the bucket (per resolved decisions — all repos are public on GitHub anyway). **Writes** require IAM credentials.

- **Public read**: no auth setup as adoption friction for any contributor running `fetch-catalogs.sh`.
- **Write**: each repo's GitHub Actions runner has a scoped IAM/CF-API-token role allowing `PutObject` only to `by-repo/<its-own-repo-name>/*` and read-modify-write on `index.json`. Use GitHub OIDC federation with the storage provider so no long-lived secrets sit in CI.

## 3. Non-functional requirements

### 3.1 Cost analysis at scale

Inputs: 30 repos × 5 pushes/day × ~100KB per catalog (case-study showed 595 entries ≈ 184KB; assume ~100KB median, ~500KB tail).

- **Storage**: 30 repos × 10 retained catalogs × 100KB = **30MB steady-state**. Even at 500KB tails: 150MB. R2: **~$0.002/month** at steady state.
- **PUT requests**: 30 × 5 × 3 PUTs (catalog + pointer + index) = 450 PUTs/day = ~13,500/month. R2 Class A: ~$0.06/month.
- **GET requests**: Assume 3 auditors × 1 fetch/day each × 62 GETs (index + 30 × 2 per repo) = 186 GETs/day = ~5,600/month. R2 Class B: $0.001/month.
- **Egress**: R2 charges $0 for egress.

**Total monthly cost: under $0.10 at typical usage.** Practically free.

### 3.2 Latency

- **Cold cache `fetch-catalogs.sh`, 30 repos**: GET index.json (~50KB, 200ms) → 30 parallel GETs of latest.json pointers (~300 bytes each, 100ms each batched) → 30 parallel GETs of SHA-keyed catalogs (~100KB each, ~500-2000ms in parallel). Total target: **<10s for 30 repos** with `curl -Z` parallelism. **KPI target: <30s budget for cold cache** (generous).
- **Warm cache** (HEAD-check ETags via `If-None-Match`): 30 × HEAD requests (~50ms each in parallel) + only-changed downloads. Typical: **<2s** if nothing changed since last fetch.
- **Merge step** (`jq -s 'map(.entries) | add'`): 30 × ~1000 entries = 30K rows. Per #118's analysis, sub-second.

### 3.3 Backup / disaster recovery

The substrate is **fully regeneratable** — every catalog can be re-produced by re-running the extractor at the recorded SHA. Worst-case recovery:

- Bucket destroyed → trigger each repo's CI manually (e.g., `workflow_dispatch`) → catalogs republish within an hour for 30 repos.
- Local working copy staleness while waiting: the `index.json` `generated_at` field reveals freshness; auditors run extractors locally as a fallback.

**Enable bucket versioning** as cheap insurance against accidental delete or mis-publish.

### 3.4 Concurrency

- **Two CI runs publishing the same repo simultaneously** (force-push, fast successive merges): both succeed because PUTs are atomic per key. The last-written `latest.json` wins; both SHA-keyed catalogs persist. `index.json` updates race — see §7's "rewrite from bucket listing" pattern, which is concurrency-safe: each writer lists `by-repo/<R>/` to compute the latest, then PUTs `index.json` with conditional `If-Match` on its ETag, retrying on 412 conflict.
- **Two repos publishing simultaneously**: independent bucket keys, no contention. The shared `index.json` PATCH is the only point of contention and is handled by ETag-CAS retry.

### 3.5 Consistency

**Eventual, as #118 explicitly accepts.** A reader who fetches at time T sees `index.json` produced at some time T0 ≤ T; individual repo catalogs were each produced at their own T_R0 ≤ T. Every row carries its `commit_sha` and the catalog metadata carries `generated_at`, so consumers needing point-in-time can filter.

**The substrate makes no guarantee of cross-repo consistency** — `wxyc-dj-site` may be at SHA `abc` (15 min old) while `wxyc-shared` is at SHA `def` (3 hours old). This is fine for cross-cutting queries; auditors who need point-in-time use the snapshot store (#117).

## 4. Storage backend — decision: Cloudflare R2

Per resolved decisions, R2 is the chosen backend:

1. **Zero egress fees** — important if PR-time CI runs (#120) end up fetching catalogs frequently.
2. **S3 API compatible** — implementation works against AWS S3 unchanged if R2 is unavailable later.
3. **Cheaper steady-state storage than S3** ($0.015/GB vs $0.023/GB).
4. **Same OIDC story works.**

Document the env-var contract (§7) so swapping providers is one config change.

## 5. KPIs

| KPI | Target | Why |
|---|---|---|
| `fetch-catalogs.sh` cold-cache wall time (30 repos) | **< 30s** | Auditor productivity; matches case-study's "under 2 seconds" pipeline philosophy |
| `fetch-catalogs.sh` warm-cache wall time (30 repos, ETag-checked) | **< 5s** | Repeat audits within a session shouldn't re-download unchanged catalogs |
| `index.json` size at 30 repos | **< 100KB** | Single GET parses fast |
| Merged catalog file (`merged-entries.json`) size | **< 50MB** | `jq -s` stays sub-second |
| Monthly substrate cost (storage + requests + egress) | **< $5** | Order-of-magnitude headroom over the <$0.10 expected baseline |
| Per-publish wall time (CI side: catalog upload + index.json refresh) | **< 10s after extractor completes** | D's CI budget |
| Publish retry success rate without manual intervention | **>= 99%** | ETag-CAS retries on `index.json` collisions converge silently |
| Coverage at any time (fraction of known repos with `status: ok`) | **>= 90%** | One repo broken is acceptable; three broken is a process issue |
| Time from `main` push to substrate-visible | **< 5 min p95** | Per #118's eventual-consistency posture |

## 6. Testing strategy

### 6.1 Local mock substrate (unit tests)

Implement a **directory-tree mock** that mirrors the bucket structure exactly:

```
test-fixtures/mock-substrate/
  index.json
  by-repo/
    fake-repo-1/latest.json
    fake-repo-1/2026-05-25T14-33-21Z_abc123.json
    ...
```

`fetch-catalogs.sh` accepts `AUDIT_BUCKET_URL=file:///path/to/fixture`; the file-based path lets tests run hermetically with no network. Cover:

- Cold fetch reads all expected files.
- Warm fetch (with cached files matching `sha256` from index) issues zero downloads.
- Missing `latest.json` → fetcher falls back to newest `history_keys` entry from index.
- `status: stale` repo in index → fetcher skips it cleanly, reports in summary.
- Malformed `index.json` → fetcher fails closed with a clear error.

### 6.2 Integration tests against a real bucket

A dedicated **test bucket** (`wxyc-catalogs-test`). Integration tests:

- Publish a synthetic catalog → verify it appears in `by-repo/.../latest.json` and `index.json`.
- Simulate two concurrent publishes for the same repo (background jobs) → verify both SHA-keyed catalogs exist and `index.json` converges to one consistent state.
- Simulate `index.json` ETag conflict → verify retry logic converges.

Run in CI on push to the substrate code, behind a feature flag. Skip locally by default.

### 6.3 Drift detection between `index.json` and bucket contents

Add `pipeline/verify-index.sh` (or jq query against `wrangler r2 object list`'s JSON output) that:

- Lists every `by-repo/<R>/latest.json` in the bucket.
- Compares against `index.json.repos[*].latest.key`.
- Reports orphaned keys (in bucket but not index) and dangling references (in index but not bucket).

Run on a schedule (cron / CI nightly) and on every publish-rewrite as a self-check. **Drift is a smell** — should be zero in steady state; non-zero means the index rewriter has a bug.

### 6.4 Fetch script behavior under partial failures

- One repo's `latest.json` returns 404 → fetcher logs warning, skips, continues. Final exit code: 0 if `>= 1` repo fetched, with a nonzero summary count.
- Network timeout mid-fetch → retry with exponential backoff (3 attempts, max 30s total per repo).
- `sha256` mismatch between `index.json` claim and downloaded bytes → fetcher discards the file and retries; if mismatch persists, surface as error.
- Concurrent fetch invocations (two auditors on shared CI box) → use atomic rename (`download to .tmp, mv to final`) so partial writes don't pollute the next fetcher's warm cache.

## 7. Implementation recommendations

### 7.1 Files to add

- **`pipeline/fetch-catalogs.sh`** — pulls `index.json`, then parallel-fetches `latest.json` pointers and resolved catalogs into `/tmp/wxyc-audit/catalogs/`. ~80 lines of bash; uses `curl -Z` for HTTP/2 multiplexing. Honors `If-None-Match` for warm-cache short-circuit.
- **`pipeline/publish-catalog.sh`** — CI-side counterpart. Given a catalog file path and a repo identity, performs: PUT SHA-keyed object, PUT `latest.json`, ETag-CAS rewrite of `index.json`. ~60 lines of bash + `wrangler r2 object put` (or `aws s3 cp` for S3-API providers).
- **`pipeline/refresh-index.mjs`** — small Node script that rebuilds `index.json` by listing the bucket from scratch. **Run by `publish-catalog.sh` on every write, AND by a nightly cron, AND as the recovery procedure after any bucket-level incident.** This is the substrate's source of truth: `index.json` is a *derived view*, never the canonical record. **Prefer rewriting from a bucket listing over append-on-write** — the latter is faster but accumulates drift; the former is self-healing.
- **`pipeline/verify-index.sh`** — drift detector (per §6.3).
- **`pipeline/queries/coverage.jq`** — reads `index.json`, emits the "28/30 repos covered, 1 stale" header for every cross-repo report (designed in [E](118-E-operational-safety.md)).
- **`docs/substrate.md`** — operator guide: bucket setup, IAM/token policies, env-var contract, retention rules, recovery procedures.

### 7.2 Index management: rewrite from listing, not append-on-write

`refresh-index.mjs` algorithm:

```
1. LIST objects under by-repo/ (paginated; ~30 prefixes × ~10 objects each = ~300 keys).
2. For each repo prefix:
   - Find the latest SHA-keyed object by timestamp in the key.
   - HEAD that object to get its metadata block from the catalog itself.
   - Build the `latest` record for index.json.
   - History keys = remaining sorted timestamps.
3. Compute coverage block from per-repo status.
4. PUT index.json with If-Match on its current ETag; retry up to 5 times on 412.
```

This is **idempotent and self-healing** — running it after manual bucket edits restores correctness without losing data. Concurrency-safe by construction.

The alternative (append-on-write) is faster but fragile: a missed update permanently corrupts the index until manually repaired. The full rebuild is ~300 LIST + HEAD operations ≈ ~$0.00012 per rebuild; negligible.

### 7.3 Environment variable contract

```
AUDIT_BUCKET=wxyc-catalogs                # bucket name
AUDIT_BUCKET_URL=https://catalogs.wxyc.org   # CDN / direct URL for reads
AUDIT_REGION=auto                         # R2 "auto", or AWS region
AUDIT_ENDPOINT=https://<account>.r2.cloudflarestorage.com   # R2 endpoint, empty for AWS
AUDIT_LOCAL_CACHE=/tmp/wxyc-audit/catalogs   # local fetch destination
R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY   # writes only; reads anonymous via AUDIT_BUCKET_URL
```

Reads go through `AUDIT_BUCKET_URL` (public CDN or signed URL host); writes use the S3-compatible API at `AUDIT_ENDPOINT`. The split lets the read path be CDN-fronted (zero egress on R2) while writes use direct API.

### 7.4 Docker image — defer

Provide bash + curl + jq as the only fetch-side dependencies. A Docker image with `wrangler`/`aws` CLIs preinstalled is convenient but adds maintenance burden. **Ship a `scripts/setup-deps.sh` that installs what's needed on macOS/Linux runners.** Revisit if multiple consumers ask for the image.

### 7.5 Interaction with D (CI workflow)

The contract between this substrate and D:

- **D's responsibility**: at the end of each `main`-branch CI run, invoke `pipeline/publish-catalog.sh --catalog <path> --repo <name> --sha <sha>`. Provide R2 credentials via OIDC federation.
- **This substrate's responsibility**: define `publish-catalog.sh`'s behavior, contract, and exit semantics. Failed publish → nonzero exit → D's workflow can decide to block-or-warn (recommend: warn-only; substrate is best-effort, downstream queries handle missing repos).
- **Shared concern**: schema version compatibility. `publish-catalog.sh` validates that the catalog has the required top-level metadata block (per [A](118-A-schema-v2.md)) before uploading; refuses to publish if missing.

## 8. Open questions / decisions still needed

1. **Bucket ownership and paying party.** Personal Cloudflare account during MVP? Org account once adopted? Decide before terraforming.
2. **Encryption at rest.** R2 encrypts at rest by default; no decision needed.
3. **Content-addressable by file hash vs always per-SHA.** Per-SHA is simpler (each commit produces a unique file); content-addressable would deduplicate identical re-publishes (e.g., a docs-only commit whose catalog is bit-identical). At 100KB × 5 pushes/day per repo, dedup savings are pennies — **defer**.
4. **Multi-region / DR.** R2 is global; no decision needed at MVP. Revisit if latency-sensitivity emerges.
5. **Schema version negotiation.** When the catalog schema bumps (per A's breaking change), how do consumers handle a substrate with mixed versions? `fetch-catalogs.sh` should refuse to merge across major schema versions and surface which repos are on the old version. Coordinate with [A](118-A-schema-v2.md)'s `schema_version` field.
6. **Should `index.json` be a single file or split per repo?** At 30 repos, single file is fine (~50KB). At 300 repos, per-repo `index.json` may scale better and avoid the ETag-CAS hotspot. Defer; revisit at 100+ repos.

## 9. Sub-ticket boilerplate

**Title:** `Cross-repo substrate (#118): R2 catalog landing zone + fetch tooling`

**Direction:**

> The cross-repo merge surface (#118) needs a deterministic landing zone for per-repo catalogs and a local fetcher that pulls them for `jq` queries. This ticket scopes the substrate: a single Cloudflare R2 bucket hosting `index.json` + `by-repo/<repo>/{latest.json, SHA-keyed catalogs}`, plus `pipeline/fetch-catalogs.sh` (read path), `pipeline/publish-catalog.sh` (CI write path, the contract with D), and `pipeline/refresh-index.mjs` (the self-healing index rebuilder). The substrate explicitly excludes the temporal snapshot store from #117 — same bucket potentially, different prefix and lifecycle. Eventual consistency is accepted (per #118); each row carries its `commit_sha` so consumers can filter. Storage cost at 30 repos ≈ $0.10/month on R2 (zero egress); latency target for cold-cache 30-repo fetch under 30s. The index is always derived from a bucket listing rather than appended-on-write, which makes the substrate self-healing under partial failures and concurrent publishes. Bucket is public-read (all source repos are public on GitHub anyway).

## Key file references

- [`/Users/jake/Developer/code-audit-pipeline/docs/future-directions.md`](../future-directions.md) — §1 storage scale reasoning
- [`/Users/jake/Developer/code-audit-pipeline/docs/case-study.md`](../case-study.md) — `/tmp/wxyc-audit/` scratch convention; <2s pipeline cost setting performance baseline
- [`/Users/jake/Developer/code-audit-pipeline/docs/pipeline-contract.md`](../pipeline-contract.md) — catalog object shape (needs the top-level metadata block per [A](118-A-schema-v2.md))
- [`/Users/jake/Developer/code-audit-pipeline/CLAUDE.md`](../../CLAUDE.md) — gitignored-outputs rule (substrate publishes catalogs that are gitignored locally)
- [`/Users/jake/Developer/code-audit-pipeline/pipeline/classify.jq`](../../pipeline/classify.jq) — existing pipeline style (jq + minimal bash; substrate scripts should match)
