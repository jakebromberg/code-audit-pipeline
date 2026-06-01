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
# Returns null on failure rather than crashing.
def parse_iso:
  if (. // null) == null then null
  else (try (fromdateiso8601) catch null)
  end;

# "comparison now" — index.json carries `generated_at`. Use it as the
# reference point for age computation so the report is reproducible given
# only the index. (A wrapper that wants wall-clock "now" can override via
# --argjson now_epoch ...; default is index.json's generated_at.)
($ENV.NOW_OVERRIDE // null) as $now_override
| ((.generated_at // null) | parse_iso) as $generated_epoch
| (
    if $now_override != null then ($now_override | tonumber? // $generated_epoch)
    else $generated_epoch
    end
  ) as $now_epoch
| stale_threshold_days as $threshold
| ($threshold * 86400) as $threshold_seconds
| .repos as $all_repos
| (
    [
      $all_repos[]
      | select(.status == "ok" and .latest != null)
      | (.latest.published_at | parse_iso) as $pub
      | {
          repo: .repo,
          commit_sha: .latest.commit_sha,
          short_sha: .latest.short_sha,
          published_at: .latest.published_at,
          age_seconds: (if $pub != null and $now_epoch != null then ($now_epoch - $pub) else null end)
        }
      | .age_hours = (if .age_seconds != null then (.age_seconds / 3600.0 | floor) else null end)
      | .age_days = (if .age_seconds != null then (.age_seconds / 86400.0 | . * 10 | floor / 10) else null end)
    ]
  ) as $covered_rows
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
      | (.latest.published_at // null | parse_iso) as $pub
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
      | select(.age_seconds != null and .age_seconds > $threshold_seconds)
      | {repo, age_days, observed_threshold: $threshold}
    ]
  ) as $divergent_stale
| (
    [
      $all_repos[]
      | select(.extractor_errors // 0 > 0)
      | {repo: .repo, extractor_errors: .extractor_errors}
    ]
  ) as $errored_rows
| (
    # Median age across covered repos (in hours), null if no ages computed.
    ($covered_rows | map(.age_hours) | map(select(. != null)) | sort) as $ages
    | if ($ages | length) == 0 then null
      elif ($ages | length) == 1 then $ages[0]
      else $ages[(($ages | length) / 2 | floor)]
      end
  ) as $median_age_hours
| ($covered_rows | map(.age_hours) | map(select(. != null)) | max) as $max_age_hours
| (
    .coverage.total_known_repos // ($all_repos | length)
  ) as $expected
| ($covered_rows | length) as $covered_count
| {
    scope: {covered: $covered_count, expected: $expected},
    threshold_days: $threshold,
    comparison_at: (.generated_at // null),
    median_age_hours: $median_age_hours,
    max_age_hours: $max_age_hours,
    covered: $covered_rows,
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
    "scope: \($result.scope.covered)/\($result.scope.expected) repos covered  |  threshold: \($result.threshold_days)d  |  \($result.missing | length) missing, \($result.stale | length) stale, \($result.errored | length) errored"
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
