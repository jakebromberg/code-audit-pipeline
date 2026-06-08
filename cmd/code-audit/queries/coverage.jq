# coverage.jq — surface scope, missing, stale, and errored repos from a
# cross-repo substrate's index.json. Designed to run on every cross-repo
# query so its consumers can read the report knowing what scope it covered.
#
# Input: the substrate's index.json. The substrate's `repos[].status` field
# is the source of truth for `ok` / `stale` / `missing`, computed by
# refresh-index.mjs against the env-configured stale threshold at
# publish-time. coverage.jq surfaces that pre-computed status AND re-derives
# the age vs. CROSS_REPO_STALE_DAYS at query-time, so any divergence between
# the two threshold reads becomes visible.
#
# Run:
#   jq -L pipeline/queries -rf pipeline/queries/coverage.jq index.json
#   OUTPUT_FORMAT=jsonl jq -L pipeline/queries -rf pipeline/queries/coverage.jq index.json
#
# Exit: 0 always. Coverage is informational; refusals belong to
#       preflight-versions.jq.
#
# Output (text mode): a multi-line header on stdout, suitable for prepending
# to a cross-repo query's findings. First line carries the headline scope
# metrics; subsequent lines list missing/stale repos by name.
#
# Output (jsonl mode): one JSON object on stdout with shape:
#   { scope: {covered, expected},
#     threshold_days: 7,
#     comparison_at: "2026-05-31T12:00:00Z",
#     covered: [{repo, commit_sha, published_at, age_hours}],
#     missing: [{repo, reason}],
#     stale:   [{repo, age_days, threshold_days}],
#     errored: [] }                         # always [] until extractors emit errors
#
#! query: coverage
#! shape: metric
#! catalog: index
#! formats: text, jsonl
#! desc: Scope / missing / stale / errored coverage report for a cross-repo merge.

include "_canonical";

# Parse an ISO-8601 UTC timestamp ("2026-05-31T12:00:00Z") into epoch seconds.
# Returns null on any failure, never crashes.
#
# Normalizes three publisher quirks before passing to fromdateiso8601:
#   - fractional seconds (".123" before Z / offset / EOL) — jq's builtin
#     rejects them; gojq accepts; we strip for parity
#   - "+00:00" / "+0000" UTC offset → "Z" (jq accepts only the Z form;
#     gojq accepts both)
# Non-UTC offsets (e.g. "-05:00") still return null — the substrate
# emits Z-form exclusively, so non-UTC is a publisher bug worth surfacing
# as null rather than silently shifting the comparison point.
#
# Defensive: non-string non-null inputs (numbers, arrays, objects from a
# malformed publisher) return null instead of crashing the sub() call.
def parse_iso:
  if (. // null) == null then null
  elif type != "string" then null
  else
    (sub("\\.[0-9]+Z$"; "Z")
     | sub("\\.[0-9]+\\+00:?00$"; "+00:00")
     | sub("\\+00:?00$"; "Z")) as $normalized
    | (try ($normalized | fromdateiso8601) catch null)
  end;

# "Comparison now" — default to wall-clock UTC (`now` builtin) so the
# stale comparison reflects real time, not whenever the index was last
# generated. Tests and reproducibility callers can pin the reference
# point via NOW_OVERRIDE (epoch seconds). The output's `comparison_at`
# field records the resolved value so consumers can audit it.
((($ENV.NOW_OVERRIDE // "") | select(length > 0)) // null) as $now_override
# Optional --catalog-kind scope. When set (the wrapper sets it from
# `--catalog-kind` / `CROSS_REPO_CATALOG_KIND`), only repos whose
# `.latest.catalogs[]` includes a matching kind count as covered —
# otherwise the header would report "N/N covered" for repos that publish
# nothing the merge will consume.
| (($ENV.CROSS_REPO_CATALOG_KIND // "") | select(length > 0) // null) as $required_kind
| ((.generated_at // null) | parse_iso) as $generated_epoch
| (
    if $now_override != null then ($now_override | tonumber? // now)
    else now
    end
  ) as $now_epoch
| stale_threshold_days as $threshold
| ($threshold * 86400) as $threshold_seconds
# Defensive: tolerate index.json without `.repos`, and downgrade any
# `.latest` that isn't a JSON object (publisher mid-transition, schema
# drift) to null so per-row `.latest.X` accesses don't crash.
| ((.repos // []) | map(
    if (.latest != null) and ((.latest | type) != "object")
    then .latest = null else .
    end
  )) as $all_repos
| (
    # Project per-repo `covered` rows. `age_seconds` is computed but
    # NOT emitted on the public envelope — its raw float varies by
    # sub-millisecond between jq invocations (via the `now` builtin),
    # which breaks the gojq parity test. The public fields are integer
    # `age_hours` and one-decimal `age_days`, both stable.
    [
      $all_repos[]
      | select(.status == "ok" and .latest != null)
      | select($required_kind == null
               or ((.latest.catalogs // []) | any(.kind == $required_kind)))
      | (.latest.published_at | parse_iso) as $pub
      | (if $pub != null and $now_epoch != null then ($now_epoch - $pub) else null end) as $age_seconds
      | {
          repo: .repo,
          commit_sha: .latest.commit_sha,
          short_sha: .latest.short_sha,
          published_at: .latest.published_at,
          age_hours: (if $age_seconds != null then ($age_seconds / 3600.0 | floor) else null end),
          age_days: (if $age_seconds != null then ($age_seconds / 86400.0 | . * 10 | floor / 10) else null end),
          _age_seconds: $age_seconds
        }
    ]
  ) as $covered_rows
# An ok-status repo that doesn't publish `$required_kind` isn't in the
# merge; surface it under `irrelevant[]` so the operator sees the
# bookkeeping (covered + irrelevant + missing + stale = total).
| (
    if $required_kind == null then []
    else
      [ $all_repos[]
        | select(.status == "ok" and .latest != null)
        | select(((.latest.catalogs // []) | any(.kind == $required_kind)) | not)
        | { repo: .repo,
            kinds: ((.latest.catalogs // []) | map(.kind) | unique) }
      ]
    end
  ) as $irrelevant_rows
| (
    [
      $all_repos[]
      | select(.status == "missing")
      | {repo: .repo, reason: (.reason // "absent")}
    ]
  ) as $missing_rows
| (
    [
      $all_repos[]
      | select(.status == "stale")
      | (.latest // null | if . == null then null else .published_at end | parse_iso) as $pub
      | {
          repo: .repo,
          age_days: (if $pub != null and $now_epoch != null then (($now_epoch - $pub) / 86400.0 | . * 10 | floor / 10) else null end),
          threshold_days: $threshold,
          reason: (.reason // "stale per index.json")
        }
    ]
  ) as $stale_rows
| (
    # Re-derived stale check against the query-time threshold. If an ok
    # repo's age exceeds the threshold *now*, surface the divergence in
    # the structured output (a sign the env var changed between publish
    # and query, or the index is older than it claims).
    [
      $covered_rows[]
      | select(._age_seconds != null and ._age_seconds > $threshold_seconds)
      | {repo, age_days, observed_threshold: $threshold}
    ]
  ) as $divergent_stale
| (
    [
      $all_repos[]
      # Parenthesize the // fallback: jq's precedence parses
      # `.extractor_errors // 0 > 0` as `.x // (0 > 0)` = `.x // false`,
      # which keeps every row with the key set — even when value is 0.
      # The intent is "missing OR zero → exclude", so default first.
      | select(((.extractor_errors // 0) | tonumber? // 0) > 0)
      | {repo: .repo, extractor_errors: .extractor_errors}
    ]
  ) as $errored_rows
| (
    # Median age across covered repos (in hours), null if no ages computed.
    # Even-length arrays average the two middle elements; odd-length pick
    # the center. Picking the upper-middle (the previous behavior) inflates
    # the displayed median for length-2 to match the max.
    ($covered_rows | map(.age_hours) | map(select(. != null)) | sort) as $ages
    | ($ages | length) as $n
    | if $n == 0 then null
      elif $n == 1 then $ages[0]
      elif ($n % 2) == 1 then $ages[($n / 2 | floor)]
      else (($ages[$n/2 - 1] + $ages[$n/2]) / 2)
      end
  ) as $median_age_hours
| ($covered_rows | map(.age_hours) | map(select(. != null)) | max) as $max_age_hours
| (
    # When `$required_kind` is set OR the wrapper has stripped `.coverage`
    # (via its --repos subset rewrite), trust the per-row tally so the
    # header reads e.g. `1/1` not `1/3`. Otherwise the substrate's
    # precomputed `.coverage.total_known_repos` is authoritative.
    ($covered_rows | length)
      + ($irrelevant_rows | length)
      + ($missing_rows | length)
      + ($stale_rows | length)
  ) as $expected_derived
| (
    if $required_kind != null then $expected_derived
    else (.coverage.total_known_repos // $expected_derived)
    end
  ) as $expected
| ($covered_rows | length) as $covered_count
| (
    # ISO-8601 the resolved `now_epoch` so the operator can audit which
    # reference point produced the staleness verdict.
    if $now_epoch != null then ($now_epoch | todateiso8601) else null end
  ) as $comparison_at
| {
    scope: {covered: $covered_count, expected: $expected},
    catalog_kind: $required_kind,
    threshold_days: $threshold,
    comparison_at: $comparison_at,
    index_generated_at: (.generated_at // null),
    median_age_hours: $median_age_hours,
    max_age_hours: $max_age_hours,
    covered: ($covered_rows | map(del(._age_seconds))),
    irrelevant: $irrelevant_rows,
    missing: $missing_rows,
    stale: $stale_rows,
    divergent_stale: $divergent_stale,
    errored: $errored_rows
  } as $result
| if output_format == "jsonl" then
    $result | @json
  else
    # Text-mode header. The first line is the one-glance summary; the
    # following lines drill into named repos.
    "scope: \($result.scope.covered)/\($result.scope.expected) repos covered"
    + (if $result.catalog_kind != null then " (\($result.catalog_kind))" else "" end)
    + "  |  threshold: \($result.threshold_days)d"
    + "  |  \($result.missing | length) missing, \($result.stale | length) stale, \($result.errored | length) errored"
    + (if ($result.irrelevant | length) > 0 then ", \($result.irrelevant | length) irrelevant" else "" end)
    + (
        if $result.median_age_hours != null then
          "  |  ages: \($result.median_age_hours)h median, \($result.max_age_hours)h max"
        else ""
        end
      )
    + (
        if ($result.missing | length) > 0 then
          "\nmissing: " + ($result.missing | map("\(.repo) (\(.reason))") | join(", "))
        else ""
        end
      )
    + (
        if ($result.irrelevant | length) > 0 then
          "\nirrelevant (no \($result.catalog_kind) catalog): "
          + ($result.irrelevant | map(.repo) | join(", "))
        else ""
        end
      )
    + (
        if ($result.stale | length) > 0 then
          "\nstale (>\($result.threshold_days)d): " + ($result.stale | map(
            "\(.repo)" + (if .age_days != null then " (\(.age_days)d old)" else "" end)
          ) | join(", "))
        else ""
        end
      )
    + (
        if ($result.divergent_stale | length) > 0 then
          "\nWARNING: \($result.divergent_stale | length) ok-status repo(s) exceed query-time threshold of \($result.threshold_days)d:\n  "
          + ($result.divergent_stale | map("\(.repo) (\(.age_days)d)") | join(", "))
        else ""
        end
      )
    + (
        if ($result.errored | length) > 0 then
          "\nerrored: " + ($result.errored | map(.repo) | join(", "))
        else ""
        end
      )
  end
