# Cross-repo catalog substrate — operator guide

The substrate is the bucket layout + the read/write/refresh tooling that moves per-repo catalogs in and out of cross-repo audits. It is the answer to "merge catalogs from 30 repos and run one `jq` query." This guide covers the **operator** side: bucket provisioning, IAM, env-var setup, recovery. For the consumer-facing read path, see [`docs/pipeline-contract.md`](pipeline-contract.md).

Substrate scope is deliberately narrow: it doesn't run extractors, doesn't compute queries, doesn't track time-series. It hosts catalog JSON, indexes what's there, and serves reads. The temporal snapshot store (#117) is a separate surface that may share the bucket under a different prefix.

## Components

| Tool | Role | Caller |
|---|---|---|
| [`pipeline/fetch-catalogs.sh`](../pipeline/fetch-catalogs.sh) | Read path: pull `index.json` + per-repo catalogs into a local cache | Auditor at a laptop |
| [`pipeline/publish-catalog.sh`](../pipeline/publish-catalog.sh) | Write path: upload one repo's catalogs, write `latest.json`, trigger index refresh | Each repo's CI on push to `main` (lands under #154) |
| [`pipeline/refresh-index.mjs`](../pipeline/refresh-index.mjs) | Rebuild `index.json` from the bucket listing (idempotent, self-healing) | `publish-catalog.sh`, nightly cron, manual recovery |
| [`pipeline/verify-index.sh`](../pipeline/verify-index.sh) | Drift detector: report orphan prefixes and dangling references | After every publish; scheduled CI cron |
| [`pipeline/run-cross-repo-query.sh`](../pipeline/run-cross-repo-query.sh) | Cross-repo query wrapper: fetch → preflight → coverage → query | Auditor running any cross-repo query |

All four substrate tools (and the wrapper) also support a `--bucket-fs DIR` (or `file://` URL) local-filesystem mode for hermetic tests and local dev — no S3 / R2 dependency.

## Bucket layout

```
catalogs/                                                 (bucket root)
  index.json                                              (mutable; rebuilt from bucket listing)
  by-repo/
    wxyc-dj-site/
      latest.json                                         (mutable pointer; ~500 bytes)
      2026-05-30T18-11-07Z_22f00f0/
        type-catalog.json                                 (immutable)
        function-catalog.json                             (immutable)
        file-hashes.json                                  (immutable)
        package-graph.json                                (when extractor emits one)
      2026-05-29T22-48-00Z_05baf17/                       (history; bucket lifecycle prunes)
        ...
```

Slashes in canonical repo names (`wxyc/dj-site`) collapse to a single path segment (`wxyc-dj-site`). The full name persists inside each catalog's `extractor` block and inside `latest.json`'s `repo` field, so the bucket key is just an access convention.

**SHA-keyed prefixes are immutable** (write-once). Only `latest.json` (per repo) and `index.json` (per bucket) are mutable.

**Timestamps in keys are sortable ISO-8601 UTC** with `:` replaced by `-` (S3 keys don't tolerate `:`). `aws s3 ls by-repo/<repo>/` therefore returns chronologically-sorted history without parsing.

## One-time bucket provisioning

The pipeline expects an **S3-API-compatible bucket with public-read on objects**. Cloudflare R2 is the documented backend; AWS S3 works unchanged via the same scripts.

### Cloudflare R2 (recommended)

1. **Create the bucket** via the R2 dashboard (or `wrangler r2 bucket create wxyc-catalogs`). Name is project-specific; defaults the tooling assumes match the env-var contract below.
2. **Enable public access** on the bucket so the read path is anonymous (`fetch-catalogs.sh` doesn't carry any creds). For an R2 bucket: enable an `r2.dev` URL OR put the bucket behind a Cloudflare CDN domain you control. Either way, set `AUDIT_BUCKET_URL` to that read URL.
3. **Create scoped API tokens** for writes:
   - One per source repo's CI runner.
   - Permissions: `Object Read & Write` scoped to `by-repo/<that-repo>/*` and `index.json`.
   - Set the token via GitHub OIDC federation (no long-lived secrets in repo settings).
4. **Bucket lifecycle rule** to prune old snapshot prefixes — keep the last 10 per repo. Drop the rest after 30 days. (R2 supports lifecycle via the API; configure with `wrangler` or the dashboard once it's stable.)
5. **Enable versioning** on the bucket for cheap delete/overwrite insurance.

The first-pass setup is a manual one-time task — by design. Infrastructure-as-code (Terraform / Pulumi) is reasonable for the project's future, but at the substrate's current scale it's overkill.

### AWS S3 (alternative)

The script's `--bucket-name`/`--bucket-endpoint` flags accept any S3-API endpoint. For AWS S3: leave `--bucket-endpoint` empty (the aws CLI uses the default endpoint for the configured region). Public-read setup uses an S3 bucket policy + Object Ownership "Bucket-owner enforced." Egress fees apply on S3, unlike R2.

## Environment-variable contract

| Var | Purpose | Required for |
|---|---|---|
| `AUDIT_BUCKET_URL` | HTTPS (or `file://`) URL the read path fetches from. CDN-fronted in production. | `fetch-catalogs.sh` |
| `AUDIT_LOCAL_CACHE` | Local cache directory; defaults to `/tmp/wxyc-audit/catalogs`. | `fetch-catalogs.sh` |
| `AUDIT_BUCKET` | S3-API bucket name. | `publish-catalog.sh`, `refresh-index.mjs` |
| `AUDIT_ENDPOINT` | S3-API endpoint URL. For R2: `https://<account>.r2.cloudflarestorage.com`. | `publish-catalog.sh`, `refresh-index.mjs` |
| `AUDIT_REGION` | S3 region. R2 uses `auto`. AWS uses e.g. `us-east-1`. Default `auto`. | Stamped into `index.json` |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (or `R2_*`) | Write-side credentials. Read path is anonymous. | `publish-catalog.sh`, `refresh-index.mjs` |
| `CROSS_REPO_STALE_DAYS` | Stale threshold for "snapshot too old → status: stale." Default 7. | `refresh-index.mjs` |

CLI flags override the env where both are accepted.

## Local workflow (auditor)

The standard entry point is the cross-repo wrapper (`pipeline/run-cross-repo-query.sh`), which composes fetch + preflight + coverage + query in one invocation. It is the canonical way to run any cross-repo query.

```bash
# Standard cross-repo invocation. Fetches, preflights versions, prints a
# coverage header, then runs the query against the merged type-catalog stream.
AUDIT_BUCKET_URL=https://catalogs.wxyc.org \
  pipeline/run-cross-repo-query.sh pipeline/queries/cross-package-shadows-any.jq

# Subset of repos. Unknown repo names abort with a stderr diagnostic
# (typos are not silently dropped).
pipeline/run-cross-repo-query.sh --repos wxyc/dj-site,wxyc/shared \
  pipeline/queries/cross-package-shadows-any.jq

# Different catalog kind (default: type-catalog). Threads through to
# preflight and coverage so unrelated extractor skew doesn't refuse the
# run, and scope counts only repos that publish the kind. Pass any
# query-specific args after `--`:
pipeline/run-cross-repo-query.sh --catalog-kind function-catalog \
  pipeline/queries/function-duplicates.jq -- --argjson threshold 0.7

# Trust an already-warm cache; skip fetch:
pipeline/run-cross-repo-query.sh --skip-fetch pipeline/queries/<q>.jq

# JSONL caller — coverage header becomes a single #~ {...} line that
# strips cleanly for downstream consumers:
OUTPUT_FORMAT=jsonl pipeline/run-cross-repo-query.sh <q>.jq \
  | grep -v '^#~ ' | jq -c .
```

Every merged entry carries `origin_repo: "<owner>/<name>"`. Cross-repo collision queries can read it to distinguish "same symbol in 2 repos" from "two intra-repo duplicates"; single-repo queries that don't reference the field are unaffected.

The wrapper enforces the operational-safety guardrails from #155: a major-version skew across the merged catalogs aborts the run before the query starts, and a coverage header is prepended to the query's output so the consumer can always see which repos contributed to the result. See [`pipeline-contract.md` § Cross-repo substrate guardrails](pipeline-contract.md#cross-repo-substrate-guardrails-coveragejq-preflight-versionsjq-run-cross-repo-querysh) for the contract.

### Manual (bypass the wrapper)

For one-off debugging when you want to skip the safety net:

```bash
# Pull every repo's latest catalogs into /tmp/wxyc-audit/catalogs/
AUDIT_BUCKET_URL=https://catalogs.wxyc.org \
  pipeline/fetch-catalogs.sh

# Merge type-catalogs across every repo for a cross-repo query
jq -s 'map(.entries) | add' \
  /tmp/wxyc-audit/catalogs/by-repo/*/2*/type-catalog.json \
  > /tmp/wxyc-audit/merged-types.json

# Run a query against the merged stream
jq -L pipeline/queries -rf pipeline/queries/cross-package-shadows-any.jq \
  /tmp/wxyc-audit/merged-types.json
```

Manual invocation is unsafe in steady state — it omits preflight (so an extractor major-version skew silently corrupts the results) and omits coverage (so the consumer can't tell what scope the report ran over). The wrapper exists to make that the default, not an opt-in.

## CI workflow (per repo, lands under #154)

The CI step is one script invocation after the extractors finish:

```bash
# Pseudocode for a repo's CI step (real version in #154)
mkdir -p ./_audit-out
node /path/to/extractors/typescript/type-catalog.mjs \
  --root . --output _audit-out/type-catalog.json
node /path/to/extractors/typescript/function-catalog.mjs \
  --root . --output _audit-out/function-catalog.json

pipeline/publish-catalog.sh \
  --repo wxyc/dj-site \
  --sha "$GITHUB_SHA" \
  --catalogs-dir _audit-out \
  --bucket-name "$AUDIT_BUCKET" \
  --bucket-endpoint "$AUDIT_ENDPOINT"
```

`publish-catalog.sh` validates each catalog against the v1.1+ wrapper shape before uploading (currently the TS extractor emits v1.2; v1.1 wrappers continue to validate). Bare-array catalogs are refused (exits nonzero).

## Recovery procedures

### `index.json` is corrupt or wrong

Just re-run `refresh-index.mjs`. The script lists the bucket from scratch and rewrites the index. Idempotent — running it twice produces the same output.

```bash
node pipeline/refresh-index.mjs \
  --bucket-name "$AUDIT_BUCKET" --bucket-endpoint "$AUDIT_ENDPOINT"
```

The previous index is overwritten (versioning preserves the prior copy if you ever need it back).

### Bucket destroyed

The substrate is **fully regeneratable**. Trigger each source repo's CI manually (`workflow_dispatch`); catalogs republish within an hour for 30 repos. While you wait, auditors can extract locally as a fallback.

### Drift between `index.json` and bucket

`verify-index.sh` reports orphan prefixes (in bucket but not indexed) and dangling references (claimed by index but missing from bucket). Both are smells — should be zero in steady state.

```bash
# Local-fs mode (tests / dev)
pipeline/verify-index.sh --bucket-fs /path/to/local/bucket

# S3 mode (production)
pipeline/verify-index.sh --bucket-name "$AUDIT_BUCKET" --bucket-endpoint "$AUDIT_ENDPOINT"
```

Non-zero exit means drift. The fix is usually a single `refresh-index.mjs` run.

### Mixed schema versions across repos

`fetch-catalogs.sh` doesn't refuse to merge across schema versions yet — every per-repo catalog carries its own `schema_version` field and consumers can filter. The downstream guard (`pipeline/queries/_canonical.jq`) is the line that enforces the contract: cluster queries today accept v1.0 (bare array) AND v1.1+ (wrapper object — `1.1`, `1.2`, etc.) transparently. Major-version bumps would require a coordinated migration; the substrate's job is to surface what's there, not to police it.

## Cost model

Per the brief's analysis at 30-repo scale on R2:

- Storage steady-state: 30 repos × 10 snapshots × ~150KB ≈ **45 MB**, ≈ **$0.001/month**.
- PUT requests: 30 repos × 5 pushes/day × 5 PUTs (4 catalogs + latest.json) = 750/day = ~22,500/month, ≈ **$0.10/month**.
- GET requests: 3 auditors × 1 fetch/day × ~140 GETs = 420/day = ~12,600/month, **negligible**.
- Egress: **$0 on R2** (key reason for choosing it).

**Total expected: well under $1/month at 30-repo scale.** The brief's $5/month budget is order-of-magnitude headroom.

## Determinism + testing

The local-filesystem backend (`--bucket-fs DIR`) makes the whole substrate exercisable hermetically. The test suite lives at [`pipeline/_tests/test_substrate.sh`](../pipeline/_tests/test_substrate.sh) and runs without network. CI integrates it as part of the existing pipeline test job.

When pointing the scripts at a real R2/S3 bucket for the first time, the smart move is to use a test bucket (`wxyc-catalogs-test`) and run the same suite there with `--bucket-name`/`--bucket-endpoint` overrides — see the suite's last section for the integration-test pattern (currently scaffolded; live tests against a real bucket land in a follow-up).

## Open operational decisions (per the brief)

- **Bucket ownership & paying party** — personal CF account during MVP, org account on adoption. Decide before terraforming.
- **Multi-region / DR** — R2 is global already; revisit only if latency becomes a complaint.
- **Single `index.json` vs split-per-repo** — single is fine at 30 repos. At 300 repos the ETag-CAS hotspot may force per-repo `index/<repo>.json` plus a thin enumeration list. Defer.
- **Multi-extractor reconciliation** — when one repo publishes with extractor version A and another with B, mixed-version queries are valid but may exhibit subtle differences. Surface in the coverage report once a real divergence shows up.

## See also

- [`docs/plans/118-C-substrate.md`](plans/118-C-substrate.md) — original design brief
- [`docs/pipeline-contract.md`](pipeline-contract.md) — catalog row schema, `_canonical.jq` helpers, the cross-cutting contract the substrate publishes
- Issue [#118](https://github.com/jakebromberg/code-audit-pipeline/issues/118) — the cross-repo umbrella
- Issue [#154](https://github.com/jakebromberg/code-audit-pipeline/issues/154) — per-repo CI publication (the substrate's first non-test caller)
- Issue [#155](https://github.com/jakebromberg/code-audit-pipeline/issues/155) — operational safety (preflight + coverage, consumes `index.json`'s `coverage` block)
