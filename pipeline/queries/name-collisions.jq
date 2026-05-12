# name-collisions.jq — find type names declared in multiple files
#
# Run:  jq -L pipeline/queries -rf pipeline/queries/name-collisions.jq catalog.json
#        (-r for raw multi-line text output)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -rf pipeline/queries/name-collisions.jq catalog.json
#
# Useful for catching: same name across different files (often unintentional
# shadowing), and same name with semantically different shapes (the
# "antipattern of name overloading").
#
# cluster_id format:  name-collisions:Name  (the colliding name)

include "_canonical";

# V2 substrate: filter generated codegen entries (see exact-duplicates.jq for rationale).
[ .[] | select((.generated // false) != true) ]
| group_by(.name)
| map(select(length > 1))
| map(select((map(.file) | unique | length) > 1))
| map({
    cluster_id: cluster_id_single_name("name-collisions"; .[0].name),
    query: "name-collisions",
    name: .[0].name,
    decls: map({kind, package, file, line, touched_in_window, shape_sig})
  })
| sort_by(-(.decls | length), .name)
| .[]
| if output_format == "jsonl" then
    @json
  else
    "\(.name) (\(.decls | length)) cid=\(.cluster_id)\n"
    + (.decls
        | map("  \(if .touched_in_window then "*" else " " end) [\(.kind)] \(.package):\(.file):\(.line)"
              + (if .shape_sig then "  sig=" + (.shape_sig | .[0:80]) else "" end))
        | join("\n"))
  end
