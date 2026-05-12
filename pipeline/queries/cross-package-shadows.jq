# cross-package-shadows.jq — find types in the "main" package whose name also
# exists in "shared" (the canonical types package). Strong signal that the main-
# package declaration should be an import instead.
#
# Run:  jq -L pipeline/queries -rf pipeline/queries/cross-package-shadows.jq catalog.json
#        (-r for raw text output)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -rf pipeline/queries/cross-package-shadows.jq catalog.json
#
# Requires --package names matching the generic extractor: "main" and "shared".
# If you use a non-default extractor that emits different package names, adjust
# the comparisons below.
#
# cluster_id format:  cross-package-shadows:Name  (per shadowed name)

include "_canonical";

. as $all
| ([ $all[] | select(.package == "shared" and (.kind == "interface" or .kind == "type-alias-object")) ]
   | map(.name) | unique) as $shared_names
| [ $all[]
    | select(.package == "main")
    | select(.kind | startswith("type-alias") or . == "interface" or . == "zod-object")
    | select(.name as $n | $shared_names | index($n))
    | {
        cluster_id: cluster_id_single_name("cross-package-shadows"; .name),
        query: "cross-package-shadows",
        name, kind, package, file, line, touched_in_window, shape_sig
      }
  ]
| sort_by(.name)
| .[]
| if output_format == "jsonl" then
    @json
  else
    "  \(if .touched_in_window then "*" else " " end) \(.name) [\(.kind)] — \(.file):\(.line) cid=\(.cluster_id)"
    + (if .shape_sig then "  sig=" + (.shape_sig | .[0:80]) else "" end)
  end
