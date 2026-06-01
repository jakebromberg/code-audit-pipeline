# Audit publication setup — for sibling repo maintainers

This doc walks a maintainer of a sibling repo (e.g. `wxyc/dj-site`, `wxyc/wxyc-ios`) through hooking that repo up to the cross-repo `code-audit` substrate. The goal: a passing workflow that uploads a catalog under `by-repo/<repo>/<timestamp>_<sha>/` on every push to main.

If you're just looking to copy the workflow file and read the input docs, jump to [Consumer workflow](#consumer-workflow). The infra setup is one-time per organization and handled by an admin.

## What you're wiring up

```
sibling repo                       this repo (code-audit-pipeline)
  push to main                       .github/workflows/publish-catalog-reusable.yml
       │                              │
       ▼                              ▼
  .github/workflows/audit-publish.yml  audit-core composite ─▶ extractors emit catalogs
                              │
                              ▼
                       pipeline/publish-catalog.sh ──▶ R2 bucket: by-repo/<repo>/<ts>_<sha>/
                                                       └──────▶ index.json (refreshed)
```

The reusable workflow is the only thing the sibling repo touches. Everything downstream (composite, extractors, publish script, refresh logic) lives in `code-audit-pipeline` and updates lockstep when you bump the workflow's `@v1` ref.

## One-time infra setup (org admin)

### 1. Create the R2 bucket

In the Cloudflare R2 dashboard, create a bucket — e.g. `wxyc-code-audit`. R2 bucket names are unique per Cloudflare account, not globally; pick a name that reflects the org.

Note the **account ID** displayed under "S3 API"; you'll need it for the endpoint URL: `https://<account-id>.r2.cloudflarestorage.com`.

The bucket can be private. Catalogs are read via the same S3 endpoint by `pipeline/fetch-catalogs.sh`, which authenticates with the same credentials as the publisher. There is no need for a public bucket.

### 2. Pick an auth path

You have two options. **OIDC is strongly recommended.**

| | OIDC role | Static R2 keys |
|---|---|---|
| Secrets stored | none (role ARN is non-sensitive) | access key + secret in repo secrets |
| Rotation | per-job, automatic | manual; expire on schedule |
| Scope | scoped per repo via trust-policy claims | bucket-wide |
| Setup difficulty | medium (trust policy + IAM policy) | low |
| Recommended for | production rollouts | initial trials, throwaway repos |

#### Option A — OIDC (recommended)

The flow GitHub → Cloudflare OIDC isn't directly supported (R2 trusts AWS IAM, not GitHub's OIDC provider). The two working paths:

1. **AWS-mediated:** create an AWS IAM role that the GitHub OIDC provider can assume; the role has an IAM policy granting `s3:PutObject` on the R2 bucket (R2 honors S3-API IAM if you front it with an AWS account that holds R2 credentials in Secrets Manager). Complex; not the path most orgs take.
2. **Cloudflare API token + GitHub secrets:** generate a scoped R2 API token in Cloudflare (Object Read & Write on a single bucket prefix), store as a GitHub repo secret. This is *not* OIDC strictly, but it's the path of least resistance for Cloudflare R2 today. Treat the token like a long-lived secret: rotate quarterly.

The reusable workflow supports either: if you pass `role-to-assume`, it calls `aws-actions/configure-aws-credentials@v4`; if you only pass the `r2-access-key-id` / `r2-secret-access-key` secrets, it exports them as environment variables.

For the rest of this doc we'll assume the Cloudflare-API-token path with secrets, since that's what most teams will use.

#### Option B — static R2 keys (simplest)

In the Cloudflare dashboard → Manage R2 API Tokens → Create API Token:

- Permission: **Object Read & Write**
- Scope: **Apply to specific buckets**, select your audit bucket
- TTL: 90 days (set a calendar reminder to rotate)

Copy the `Access Key ID` and `Secret Access Key`. In each sibling repo that will publish:

- Settings → Secrets and variables → Actions → New repository secret
- `R2_ACCESS_KEY_ID` = the access key from above
- `R2_SECRET_ACCESS_KEY` = the secret

For org-wide use, store as **organization secrets** with a repo allowlist instead of per-repo secrets.

### 3. IAM / bucket policy (OIDC path only)

If you chose Option A, the bucket policy must allow the AWS IAM role to write under `by-repo/*` and read/write `index.json`. Minimal policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCatalogWrites",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": [
        "arn:aws:s3:::wxyc-code-audit/by-repo/*",
        "arn:aws:s3:::wxyc-code-audit/index.json"
      ]
    },
    {
      "Sid": "AllowListForRefresh",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::wxyc-code-audit",
      "Condition": {
        "StringLike": { "s3:prefix": ["by-repo/*"] }
      }
    }
  ]
}
```

The `s3:ListBucket` permission is required by `refresh-index.mjs`, which lists `by-repo/*/latest.json` to rebuild the index.

The trust policy (the part that says "this GitHub repo's OIDC identity may assume the role") should pin the audience and the `sub` claim to your org and repo:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::000000000000:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:wxyc/*:ref:refs/heads/main" }
    }
  }]
}
```

The `sub` wildcard above grants every repo under `wxyc/*` push-only access from main. Tighten if your needs are stricter (e.g. specific repos), loosen with caution.

## Consumer workflow

Copy [`.github/templates/audit-publish.yml.example`](../.github/templates/audit-publish.yml.example) into your repo at `.github/workflows/audit-publish.yml`. The whole file is one screen:

```yaml
name: Publish code-audit catalog
on:
  push: { branches: [main] }
  schedule: [{ cron: '17 7 * * *' }]
  workflow_dispatch:
permissions: { contents: read, id-token: write }
jobs:
  publish:
    uses: jakebromberg/code-audit-pipeline/.github/workflows/publish-catalog-reusable.yml@v1
    with:
      bucket-name: wxyc-code-audit
      bucket-endpoint: https://<account-id>.r2.cloudflarestorage.com
    secrets: inherit
```

The reusable workflow handles language detection, toolchain install, extractor execution, R2 auth wiring, upload, and `index.json` refresh. You do not need to know the catalog format, the extractor inventory, or the bucket layout — those are stable contracts behind the `@v1` ref.

### Inputs reference

| Input | Default | Purpose |
|---|---|---|
| `bucket-name` | required | S3-API bucket name. |
| `bucket-endpoint` | required | S3-API endpoint URL. R2: `https://<account-id>.r2.cloudflarestorage.com`. |
| `bucket-region` | `auto` | Region tag for the AWS SDK. R2 ignores it; override only for non-R2 backends. |
| `role-to-assume` | `''` | OIDC role ARN. When set, takes precedence over static-key secrets. |
| `audit-binary-version` | `v1` | code-audit release tag. Pin to a major series for patch updates without breaking changes; pin a fully-qualified `v1.2.3` to freeze. |
| `languages` | `''` (auto-detect) | Comma-separated override. Use only when marker-file detection is wrong (rare). |
| `root` | `.` | Repo root to scan. |
| `include-tests` | `false` | Pass `--include-tests` to every extractor. |
| `include-file-hashes` | `false` | **See known gap below.** Default `false` until #141 lands. |
| `runner` | `ubuntu-latest` | Runner label. Override to `macos-latest` for Swift-containing repos. |

### Secrets reference

| Secret | Required when | Purpose |
|---|---|---|
| `r2-access-key-id` | `role-to-assume` is empty | R2 access key. |
| `r2-secret-access-key` | `role-to-assume` is empty | R2 secret access key. |

Use `secrets: inherit` in the caller workflow so the reusable picks these up automatically when set as repo/org secrets. Explicit forwarding (`secrets: { r2-access-key-id: ${{ secrets.FOO }} }`) is also supported.

### Polyglot repos

A repo with both TypeScript and Swift forces the whole job onto a macOS runner — pass `runner: macos-latest`. A future iteration will split detection into a pre-job that picks the runner automatically; for now the choice is the caller's. TS-only repos should leave `runner` at its default (`ubuntu-latest`) for cost.

## Verifying publication

After the first run, three things should be true:

1. **Workflow ran green.** Check the Summary tab of the run for the `## code-audit publication` block; it lists the published prefix and catalog count.
2. **Catalog files landed in R2.** Browse the bucket: `by-repo/<your-flattened-repo>/<timestamp>_<short-sha>/*.json`.
3. **`index.json` mentions your repo.** Download `index.json` from the bucket root; your repo should appear in `.repos[]`.

To smoke-test the round-trip locally:

```bash
# From a code-audit-pipeline checkout:
AUDIT_BUCKET_URL="https://<account-id>.r2.cloudflarestorage.com/<bucket-name>" \
  bash pipeline/fetch-catalogs.sh --quiet
ls ~/.cache/code-audit/by-repo/<your-flattened-repo>/
```

If the fetch fails, the publish path likely uploaded under a different key shape than the fetch path expects — open an issue with the bucket listing.

## Known gaps

### `include-file-hashes` defaults to `false`

The `file-hashes` extractor still emits a bare JSON array; `publish-catalog.sh` enforces the v1.1 wrapper schema and rejects bare arrays. Until #141 (file-hashes wrapper migration) lands, leaving `include-file-hashes: false` is the only way to keep the publish step green. Once #141 ships, this doc and the workflow's default will flip to `true`.

Downstream queries that *consume* the catalog assume per-file hashes exist. Flipping `include-file-hashes: true` early (after #141) will not break consumers; flipping it true before #141 will fail the publish.

### Selftest cannot exercise the publish path

`code-audit-pipeline`'s own CI builds the binary from source and exercises the composite end-to-end, but does not exercise this reusable workflow against a real bucket — the smoke test for OIDC + real R2 only runs when a consumer repo's first publish lands. If publication fails immediately on adoption, the most likely cause is bucket policy / OIDC trust misconfiguration; the workflow's `Configure R2 credentials` step prints actionable errors when secrets are missing, but the AWS SDK's error messages on policy mismatches are notoriously terse.

### No automatic Swift detection routing

A polyglot TS+Swift repo currently runs the whole job on a macOS runner because the maintainer set `runner: macos-latest`. A pre-job that runs `detect-languages.sh` on ubuntu and then dispatches the real publish job onto the right runner would let TS-only repos benefit even when sharing a workflow template with Swift-containing repos. Tracked as a follow-up to #154.

## Troubleshooting

- **`AccessDenied` from R2 on upload.** Bucket policy / token scope. Token must have `Object Read & Write` on the bucket; OIDC roles need the IAM policy above.
- **`InvalidAccessKeyId` from R2.** The static keys are wrong, or the OIDC trust policy didn't match (and the workflow silently fell back to env-var keys that aren't set). Check `AWS_ACCESS_KEY_ID` is not empty in the configure step's logs.
- **`publish-catalog.sh: REFUSED: file-hashes.json is not a v1.1 wrapper-shaped catalog`.** You set `include-file-hashes: true` before #141 landed. Flip back to `false`.
- **`audit-core: cannot resolve action repository`.** You're invoking the composite directly via a local path while in a context with no git remote — should not happen in the reusable-workflow path, which checks out the pipeline repo explicitly.
- **macOS job times out installing toolchains.** Cold cache. The composite reinstalls Node + builds the TS extractor's `node_modules/` on every run; a follow-up will add `actions/cache` to amortize this.

## Operational signals to watch

- `index.json` should be refreshed within minutes of every push. If it lags, `refresh-index.mjs` is failing — check the publish job's `[4/4] Refreshing index.json...` log.
- A repo that stops publishing for >7 days drops out of the cross-repo queries (the `stale-repo` filter in `fetch-catalogs.sh` enforces this). Either your push triggers stopped firing, or the nightly cron has been failing — check the workflow run history.
