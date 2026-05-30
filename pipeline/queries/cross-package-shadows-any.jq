# cross-package-shadows-any.jq — find type names that appear in MORE THAN ONE
# package. Strong signal that one of the redeclarations should be an import.
#
# Run:  jq -L pipeline/queries -rf pipeline/queries/cross-package-shadows-any.jq catalog.json
#        (-r for raw text output)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -rf pipeline/queries/cross-package-shadows-any.jq catalog.json
#
# Unlike cross-package-shadows.jq (which asymmetrically reports main-package
# names that exist in shared, assuming shared is canonical), this query is
# symmetric and N-package: any name appearing in ≥2 distinct packages surfaces,
# with all occurrences listed. Intended for codebases with multiple internal
# packages where no single one is the canonical types module.
#
# cluster_id format:  cross-package-shadows-any:Name  (per shadowed name)
#
#! shape: cluster

include "_canonical";

entries as $all
| [ $all[]
    | select(.kind | startswith("type-alias") or . == "interface" or . == "zod-object")
    | select((.generated // false) != true)
  ]
| group_by(.name)
| map(select((map(.package) | unique | length) > 1))
| map({
    cluster_id: cluster_id_single_name("cross-package-shadows-any"; .[0].name),
    query: "cross-package-shadows-any",
    shape: "cluster",
    name: .[0].name,
    members: map({package, kind, file, line, shape_sig, touched_in_window})
  })
| sort_by(-(.members | length), .name)
| .[]
| if output_format == "jsonl" then
    @json
  else
    "\(.name)  [\(.members | length) packages, \(.members | map(.package) | unique | length) distinct] cid=\(.cluster_id)\n"
    + (.members
        | map("    \(if .touched_in_window then "*" else " " end) \(.package): \(.kind) — \(.file):\(.line)"
              + (if .shape_sig then "  sig=" + (.shape_sig | .[0:80]) else "" end))
        | join("\n"))
  end
