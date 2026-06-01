# preflight-versions.jq — refuse cross-repo merge on extractor major-version
# skew or on missing/malformed extractor blocks.
#
# Input: the substrate's index.json (the path passed as the sole positional
# argument). The substrate already records each repo's
# `.latest.catalogs[].extractor` block — preflight reads those directly
# rather than re-slurping every catalog file, since refresh-index.mjs
# guarantees the metadata matches the catalogs in the cache.
#
# Run:
#   jq -L pipeline/queries -rf pipeline/queries/preflight-versions.jq index.json
#   OUTPUT_FORMAT=jsonl jq -L pipeline/queries -rf pipeline/queries/preflight-versions.jq index.json
#
# Exit:
#   0 — all extractors share the same major version within each
#       (language, name) group. Minor skew is reported as a warning but
#       still passes.
#   1 — major-version skew, missing extractor block, or unparseable
#       extractor version on any ok-status repo. The merged catalog is
#       unsafe to query.
#
# Multi-language behavior: comparisons are scoped per `(language, name)`
# extractor group, so a TypeScript v1.x merge alongside Python v0.x is fine
# (the two extractors emit non-overlapping rows). A type-catalog v1.3 and
# function-catalog v2.0 in the same repo also coexist; cross-repo skew
# only triggers when the SAME extractor differs across repos.
#
# Output (text mode): a multi-line human-readable summary on stdout.
#   The last line carries the status verdict, suitable for grep.
#
# Output (jsonl mode): one JSON object on stdout with shape:
#   { status: "ok" | "minor-skew" | "refused",
#     reason: "..." (only when refused),
#     extractors: [ {ext_id, versions: [{version, repos}]} ],
#     refusal_details: { missing, malformed, major_skews } (only when refused) }
#
#! query: preflight-versions
#! shape: metric
#! catalog: index
#! formats: text, jsonl
#! desc: Refuse cross-repo merge on extractor major-version skew.

include "_canonical";

# parse_major(version) — return the integer major, or null if unparseable.
# Strips optional leading `v` ("v1.3.2" → 1).
def parse_major(version):
  if (version | type) != "string" then null
  else
    (version | sub("^v"; "") | split(".") | .[0] // null) as $first
    | if $first == null or $first == "" then null
      else ($first | tonumber? // null)
      end
  end;

# Pull one row per (repo, catalog) from index.json. Only ok-status repos
# contribute; stale/missing ones have no catalogs to merge.
#
# Defensive: `.extractor.version` panics in jq if `.extractor` is a
# non-null non-object (number, string, array). We treat any non-object
# as "missing extractor" so a malformed publisher gets a clean refusal,
# not a stack trace.
def catalog_rows:
  [
    (.repos // [])[]
    | select(.status == "ok" and .latest != null)
    | .repo as $repo
    | (.latest.catalogs // [])[]
    | (
        if (.extractor // null) == null then null
        elif (.extractor | type) != "object" then null
        else .extractor
        end
      ) as $ext
    | {
        repo: $repo,
        kind: .kind,
        extractor: $ext,
        raw_extractor: .extractor,
        version: ($ext.version // null),
        language: ($ext.language // null),
        ext_name: ($ext.name // null)
      }
    | .major = parse_major(.version)
  ];

catalog_rows as $rows
| ($rows | map(select(.extractor == null))
        | map({repo, kind, raw: .raw_extractor})) as $missing
| ($rows | map(select(.extractor != null and (.version == null or .major == null)))
        | map({repo, kind, version})) as $malformed
| ($rows | map(select(.extractor != null and .major != null))) as $valid
| ($valid | group_by((.language // "") + "/" + (.ext_name // ""))) as $groups
| (
    $groups | map({
      ext_id: ((.[0].language // "?") + "/" + (.[0].ext_name // "?")),
      versions: (
        group_by(.version)
        | map({
            version: .[0].version,
            major: .[0].major,
            repos: (map(.repo) | unique)
          })
        | sort_by(.version)
      )
    })
  ) as $grouped
| ($grouped | map(select((.versions | map(.major) | unique | length) > 1))) as $major_skews
| ($grouped | map(select(
    (.versions | map(.major) | unique | length) == 1
    and (.versions | length) > 1
  ))) as $minor_skews
| (
    if ($missing | length) > 0 then "refused"
    elif ($malformed | length) > 0 then "refused"
    elif ($major_skews | length) > 0 then "refused"
    elif ($minor_skews | length) > 0 then "minor-skew"
    else "ok"
    end
  ) as $status
| (
    if $status == "refused" then
      if ($missing | length) > 0 then
        "missing extractor block on \($missing | length) catalog(s)"
      elif ($malformed | length) > 0 then
        "malformed extractor version on \($malformed | length) catalog(s)"
      else
        "major version skew in \($major_skews | length) extractor group(s)"
      end
    else null
    end
  ) as $reason
| {
    status: $status,
    reason: $reason,
    extractors: $grouped,
    refusal_details: (
      if $status == "refused" then
        {missing: $missing, malformed: $malformed, major_skews: $major_skews}
      else null
      end
    )
  } as $result
| (
    if output_format == "jsonl" then
      $result | @json
    else
      # Text mode: per-extractor table followed by a status verdict.
      "extractor versions in merge set (\($valid | length) catalog(s) across \($valid | map(.repo) | unique | length) repo(s)):\n"
      + (
          $grouped
          | map(
              "  \(.ext_id):  "
              + (.versions | map("\(.version) (\(.repos | length) repo\(if (.repos | length) == 1 then "" else "s" end): \(.repos | join(", ")))") | join(",  "))
            )
          | join("\n")
        )
      + "\n"
      + (
          if $status == "refused" then
            "REFUSED: \($reason)\n"
            + (
                if ($missing | length) > 0 then
                  "  missing extractor: "
                  + ($missing | map("\(.repo) (\(.kind))") | join(", ")) + "\n"
                else "" end
              )
            + (
                if ($malformed | length) > 0 then
                  "  malformed extractor: "
                  + ($malformed | map("\(.repo) (\(.kind), version=\(.version // "null"))") | join(", ")) + "\n"
                else "" end
              )
            + (
                if ($major_skews | length) > 0 then
                  ($major_skews | map(
                      "  major skew in \(.ext_id): "
                      + (.versions | map("\(.version) ↔ \(.repos | join(","))") | join(" vs "))
                    ) | join("\n")) + "\n"
                else "" end
              )
            + "STATUS: refused"
          elif $status == "minor-skew" then
            "WARNING: minor version skew (proceeding):\n"
            + ($minor_skews | map(
                "  \(.ext_id): " + (.versions | map(.version) | join(", "))
              ) | join("\n"))
            + "\nSTATUS: minor-skew"
          else
            "STATUS: ok"
          end
        )
    end
  ),
  # After emitting the output, halt with exit code 1 if refused. halt_error
  # writes its input to stderr; passing "" means no extra stderr noise
  # beyond what's already been formatted into stdout.
  (if $status == "refused" then ("" | halt_error(1)) else empty end)
