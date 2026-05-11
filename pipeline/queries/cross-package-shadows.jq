# cross-package-shadows.jq — find types in the "main" package whose name also
# exists in "shared" (the canonical types package). Strong signal that the main-
# package declaration should be an import instead.
#
# Run:  jq -rf cross-package-shadows.jq catalog.json    (-r for raw output)
#
# Requires --package names matching the generic extractor: "main" and "shared".
# If you use a non-default extractor that emits different package names, adjust
# the comparisons below.

. as $all
| ([ $all[] | select(.package == "shared" and (.kind == "interface" or .kind == "type-alias-object")) ]
   | map(.name) | unique) as $shared_names
| [ $all[]
    | select(.package == "main")
    | select(.kind | startswith("type-alias") or . == "interface" or . == "zod-object")
    | select(.name as $n | $shared_names | index($n))
  ]
| sort_by(.name)
| .[]
| "  \(if .touched_in_window then "*" else " " end) \(.name) [\(.kind)] — \(.file):\(.line)"
  + (if .shape_sig then "  sig=" + (.shape_sig | .[0:80]) else "" end)
