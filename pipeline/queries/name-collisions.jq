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
#
#! query: name-collisions
#! shape: cluster
#! catalog: type-catalog
#! formats: text, jsonl
#! desc: Same name declared in multiple packages — first-pass shadow signal.

include "_canonical";

# Positive kind filter — mirrors cross-package-shadows.jq's pattern. Robust to
# future kind additions: only known shape-of-named-members kinds participate in
# the name-collision grouping. Excludes `kind: "import"` rows (introduced by
# --include-imports) which would otherwise inflate clusters with consumer-edge
# references to the same exported name.
# V2 substrate: filter generated codegen entries (see exact-duplicates.jq for rationale).
[ entries[]
  | select((.generated // false) != true)
  | select(.kind | startswith("type-alias") or . == "interface" or . == "zod-object" or . == "drizzle-table")
]
| group_by(.name)
| map(select(length > 1))
| map(select((map(.file) | unique | length) > 1))
| map({
    cluster_id: cluster_id_single_name("name-collisions"; .[0].name),
    query: "name-collisions",
    shape: "cluster",
    name: .[0].name,
    members: map({kind, package, file, line, touched_in_window, shape_sig})
  })
| sort_by(-(.members | length), .name)
| .[]
| if output_format == "jsonl" then
    @json
  else
    "\(.name) (\(.members | length)) cid=\(.cluster_id)\n"
    + (.members
        | map("  \(if .touched_in_window then "*" else " " end) [\(.kind)] \(.package):\(.file):\(.line)"
              + (if .shape_sig then "  sig=" + (.shape_sig | .[0:80]) else "" end))
        | join("\n"))
  end
