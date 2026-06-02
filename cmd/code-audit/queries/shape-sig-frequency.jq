# shape-sig-frequency.jq — list shape_sig values by frequency.
#
# Discovery helper for migration-progress.jq: identifies candidate `old_sig` /
# `new_sig` values when the driver is doing forensic archaeology rather than
# tracking a refactor whose anchor types are already known by name.
#
# Run:  jq -L pipeline/queries -rf pipeline/queries/shape-sig-frequency.jq catalog.json
#
# Optional filters / knobs (env vars):
#   PACKAGE=main              restrict to one package
#   KIND_PREFIX=interface     restrict to kinds starting with <string>
#   INCLUDE_GENERATED=true    do not exclude generated:true rows (excluded by default)
#   MIN_COUNT=2               floor on cluster size (default 2)
#   SAMPLE_SIZE=3             names to show per sig (default 3)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -rf pipeline/queries/shape-sig-frequency.jq catalog.json
#
# Output: one row per shape_sig, ordered by count desc then shape_sig asc.
#
# cluster_id format:  shape-sig-frequency:<shape_sig-slug>
# The shape_sig is whitespace-slugged (runs of whitespace → `-`) for the
# cluster_id only. Per the canonical contract, `shape_sig` is allowed to carry
# spaces (e.g. `album_title:string | null|...` from TS-normalized union types),
# but cluster_ids must be single whitespace-free tokens — downstream parsers
# split on whitespace. The verbatim shape_sig stays in the `shape_sig` field.
# Colons and pipes are preserved (existing queries like subset-pairs already
# embed `:` in cluster_ids), so the slug stays human-readable.
#
#! query: shape-sig-frequency
#! shape: metric
#! catalog: type-catalog
#! env: PACKAGE string ""
#! env: KIND_PREFIX string ""
#! env: INCLUDE_GENERATED string ""
#! env: MIN_COUNT string "2"
#! env: SAMPLE_SIZE string "3"
#! formats: text, jsonl
#! desc: shape_sig values by frequency — discovery helper for migration-progress.

include "_canonical";

($ENV.PACKAGE         // "")    as $pkg_filter
| ($ENV.KIND_PREFIX   // "")    as $kind_filter
| (($ENV.INCLUDE_GENERATED // "") == "true") as $include_gen
| (($ENV.MIN_COUNT    // "2")   | tonumber) as $min
| (($ENV.SAMPLE_SIZE  // "3")   | tonumber) as $sample
| [entries[]
    | select(.shape_sig != null and .shape_sig != "")
    | select($include_gen or ((.generated // false) != true))
    | select($pkg_filter == "" or .package == $pkg_filter)
    | select($kind_filter == "" or ((.kind // "") | startswith($kind_filter)))]
| group_by(.shape_sig)
| map(select(length >= $min))
| map(
    .[0].shape_sig as $sig
    | ($sig | gsub("\\s+"; "-")) as $sig_slug
    | {
        cluster_id: cluster_id_single_name("shape-sig-frequency"; $sig_slug),
        query: "shape-sig-frequency",
        shape: "metric",
        shape_sig: $sig,
        count: length,
        sample_names: (map(.name) | unique | .[0:$sample])
      }
  )
| sort_by(-.count, .shape_sig)
| .[]
| if output_format == "jsonl" then
    @json
  else
    "\(.count)  \(.shape_sig)  (e.g. \(.sample_names | join(", "))) cid=\(.cluster_id)"
  end
