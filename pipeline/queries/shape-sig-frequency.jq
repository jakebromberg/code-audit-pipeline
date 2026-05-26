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
# cluster_id format:  shape-sig-frequency:<shape_sig>

include "_canonical";

($ENV.PACKAGE         // "")    as $pkg_filter
| ($ENV.KIND_PREFIX   // "")    as $kind_filter
| (($ENV.INCLUDE_GENERATED // "") == "true") as $include_gen
| (($ENV.MIN_COUNT    // "2")   | tonumber) as $min
| (($ENV.SAMPLE_SIZE  // "3")   | tonumber) as $sample
| [.[]
    | select(.shape_sig != null and .shape_sig != "")
    | select($include_gen or ((.generated // false) != true))
    | select($pkg_filter == "" or .package == $pkg_filter)
    | select($kind_filter == "" or ((.kind // "") | startswith($kind_filter)))]
| group_by(.shape_sig)
| map(select(length >= $min))
| map({
    cluster_id: cluster_id_single_name("shape-sig-frequency"; .[0].shape_sig),
    query: "shape-sig-frequency",
    shape_sig: .[0].shape_sig,
    count: length,
    sample_names: (map(.name) | unique | .[0:$sample])
  })
| sort_by(-.count, .shape_sig)
| .[]
| if output_format == "jsonl" then
    @json
  else
    "\(.count)  \(.shape_sig)  (e.g. \(.sample_names | join(", "))) cid=\(.cluster_id)"
  end
