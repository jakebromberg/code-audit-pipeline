# V7 Pre-flight gate — summary (§5 of the implementation plan)

Captured 2026-05-14, against substrate `95f7f720aa4786129625a52ea1088b9a59e4050c`.

The gate has five checks; all-pass is required before Phase D launch.

| # | Check | Status | Notes |
|---|---|---|---|
| §5.0 | Generate `reproducibility.yaml` pre-registration artifact | PASS | committed in this PR |
| §5.1 | Substrate smoke test — verify hash reproducibility | PASS | 31/31 hashes byte-match across two independent serve+extract+query cycles |
| §5.2 | Prompt rendering test on one cluster row | PASS | 9 query types render at 1.9K–3.5K tokens, no unfilled placeholders |
| §5.3 | Single-cluster end-to-end dry run | PASS | HTTP 200, JSON-schema match, model returned `claude-sonnet-4-6`, 21.3 s latency, $0.018 cost; real category `no-action / sample-app-mirror` with confidence 0.82 |
| §5.4 | Cost projection: 150 recs at Sonnet rates ≤ $120 | PASS | $2.68 (real-usage-based); 2.2% of $120 cap |
| §5.5 | Manifest-rubric review + contamination-vectors confirmation | PASS | §2.5 approval committed in `manifest-review-notes.md` with matching hashes; no `// Plant` comments; no `.git`/`.github`/`.claude` in served tree |

## §5.1 — Substrate smoke test details

`scripts/verify-reproducibility.sh` was added as the canonical replay command. Procedure:

1. Tear down `/tmp/wxyc-audit/plants-v7/` and `experiments/v7-refactor-recommendation/{catalogs,clusters-s1,clusters-s2}/`.
2. Re-run `scripts/serve-plants-v7.sh` against `wxyc-ios-64@77f347e7`.
3. Re-run `scripts/generate-clusters-v7.sh`.
4. Run `scripts/verify-reproducibility.sh` — every hash under `reproducibility.yaml > pre_registration.{plant_tree_sha, catalog_hashes, query_output_hashes}` must match byte-for-byte.

Cycle 1 captured the pre-registration hashes; cycle 2 verified all 31 (1 plant_tree + 3 catalogs + 11 S1 + 16 S2). Substrate is byte-deterministic.

## §5.2 — Prompt rendering details

`scripts/render-prompt.py` projects a raw cluster row into the §3 normalized shape and assembles the full user message. The wrapper has no `{{...}}` placeholders — the rendering check is for accidental introduction of any.

Per-query input-token estimates (chars/4, Sonnet 4.6):

| Query | Tokens |
|---|---|
| exact-duplicates | 3467 |
| name-collisions | 3244 |
| function-duplicates | 2422 |
| generic-struct-candidates | 2376 |
| protocol-inheritance-candidates | 2371 |
| pat-candidates | 2370 |
| generic-function-candidates | 2136 |
| default-impl-candidates | 1966 |
| cross-package-shape-near-duplicates-any | 1935 |
| subset-pairs | 1927 |
| near-duplicates-any | 1923 |
| cross-package-shadows-any | 1891 |

All fit comfortably in Sonnet 4.6's 200K context. The 4 V7-new queries (pat/protocol-inh/generic/default-impl) sit in the middle of the range.

## §5.3 — Dry-run results

`scripts/dry-run-cluster.sh` sent one normalized `pat-candidates` row (the `DebugMetricsProvider` cross-package pair) to `https://api.anthropic.com/v1/messages`.

| | Value |
|---|---|
| HTTP status | 200 |
| Model returned | `claude-sonnet-4-6` |
| Latency | 21.3 s |
| Input tokens | 2735 |
| Output tokens | 643 |
| Stop reason | `end_turn` |
| Cost | $0.0179 |
| JSON-schema match | OK |
| Recommendation category | `no-action` |
| `reason_class` | `sample-app-mirror` |
| Confidence | 0.82 |

The agent correctly applied the §1 sample-app-mirror decision rule: one record sits under `Shared/Wallpaper/Examples/WallpaperSampleApp/Sources/DebugHUD.swift` and the agent refused to recommend an action across that boundary. Response wrapped the JSON array in a markdown ``` ```json ``` fence — the validator extracts the array via regex so the fence is tolerated, but the Phase D harness should normalize this.

The API returned bare `claude-sonnet-4-6` despite the methodology §10 requirement for a date-pinned suffix. **Action item before Phase D:** confirm the canonical date-pinned identifier (e.g., via `gh api` or the model documentation) and update `reproducibility.yaml > execution.model_versions.primary_pinned_at`. The bare identifier silently drifts as new Sonnet 4.6 versions ship.

Full response captured at `experiments/v7-refactor-recommendation/preflight/dry-run-response.json`.

## §5.4 — Cost projection

Real-usage basis from §5.3 (the pat-candidates row is a representative middle-of-the-pack input):

| | Value |
|---|---|
| Input tokens/rec | 2735 |
| Output tokens/rec | 643 |
| Cost/rec | $0.0179 |
| 150 recs total | $2.68 |
| % of $120 cap | 2.2% |
| % of methodology Phase-D envelope ($9) | 30% |

Comparison to chars/4 estimate from §5.2: real input tokens 1.15× estimate, real output tokens 1.6× the assumed 400-token rationale. The chars/4 heuristic undercounts; the real-usage projection still sits ~45× under the §5.4 cap. Worst-case at exact-duplicates (the largest renderer, 3467 estimate × 1.15 = ~3990 input tokens) with maximum-length rationales would be ~$0.025/rec or $3.75 for 150 — still under 4% of cap.

The methodology's ~$9 Phase-D figure appears to assume larger output tokens than this dry-run produced; the real figure is closer to $3 unless rationales lengthen substantially under volume.

## §5.5 — Contamination-vectors check

- **§2.5 /review-plan approval**: committed at `experiments/v7-refactor-recommendation/manifest-review-notes.md` (originally `f0a3985`, follow-up fixes in `4b68693`). Recorded artifact hashes (`cc2e5a5e...` / `8704ebd3...`) match the pre-registered values in `reproducibility.yaml`.
- **No `// Plant` body comments**: grep across served tree returns 0 hits (5 hits on Xcode-style file-header echoes of the filename, which are not a contamination vector since `_Plant_` filename prefix is explicitly allowed per V6 §18 postscript).
- **No git-history leak**: served tree has no `.git`, `.github`, or `.claude` directory — plant-naming commits live on `experiment/swift-substrate` in this pipeline repo, not in the served tree.
- **Submodule rename caveat**: `Shared/Wallpaper` is a wxyc-ios-64 submodule; its source SHA is recorded under `submodule_shas.wallpaper` in reproducibility.yaml so the agent's source view is byte-stable.

## Gate disposition

5/5 checks pass. Phase D is unblocked subject to two pre-launch nits:

1. **Pin the Sonnet date-suffix.** ~~The API returned bare `claude-sonnet-4-6`; methodology §10 requires a date-pinned identifier. Update `reproducibility.yaml > execution.model_versions.primary_pinned_at` before the Phase D harness runs.~~ **Resolved 2026-05-14 (§6.1):** the Anthropic public models endpoint exposes only the bare alias for the 4.6 tier; nine candidate date suffixes spanning 2025-08-01 through 2026-04-01 all returned HTTP 404 on `/v1/messages`. The reproducibility manifest now pins via the API-version header (`anthropic-version: 2023-06-01`) + bare alias + per-recommendation capture of the response `model` field; see `reproducibility.yaml > execution` for the full rationale. Repoint if Anthropic publishes a 4.6 date-pinned variant before Phase D execution starts.
2. **Markdown-fenced JSON in agent response.** The §5.3 response wrapped its JSON array in a ` ```json ` fence. The Phase D harness (plan §6.2) needs to handle this — either reject and re-prompt, or extract via the same regex the validator uses.
