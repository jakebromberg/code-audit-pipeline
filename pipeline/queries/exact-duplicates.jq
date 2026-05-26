# exact-duplicates.jq — find type clusters with the same shape_sig
#
# Run:  jq -L pipeline/queries -rf pipeline/queries/exact-duplicates.jq catalog.json
#        (-r for raw multi-line text output)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -rf pipeline/queries/exact-duplicates.jq catalog.json
#              (-r required: @json produces a JSON-encoded string; -r emits it raw, one cluster per line)
#
# Output: one cluster per group, ordered by cluster size (largest first).
# An asterisk (*) marks declarations touched during the audit window.
#
# cluster_id format:  exact-duplicates:NameA+NameB+...  (sorted, '+' separator)

include "_canonical";

# V2 substrate: filter `generated: true` to suppress OpenAPI-codegen-internal duplication noise
# (codegen output declares every type both in its own file and again in a consolidated `.d.ts`,
# producing 50+ "duplicate" clusters that an agent already understands as codegen, not drift).
# Cross-package-shadows still surfaces main↔shared/generated collisions, which is the real signal.
[ entries[] | select(.shape_sig != null and .shape_sig != "" and (.generated // false) != true) ]
| group_by(.shape_sig)
| map(select(length > 1))
| map({
    cluster_id: cluster_id_sorted_names("exact-duplicates"; map(.name)),
    query: "exact-duplicates",
    shape_sig: .[0].shape_sig,
    field_count: (.[0].fields | length),
    decls: map({name, kind, package, file, line, touched_in_window})
  })
| sort_by(-(.decls | length))
| .[]
| if output_format == "jsonl" then
    @json
  else
    "[\(.field_count) fields, \(.decls | length) decls] cid=\(.cluster_id)\n"
    + (.decls
        | map("  \(if .touched_in_window then "*" else " " end) \(.name) (\(.kind)) — \(.package):\(.file):\(.line)")
        | join("\n"))
  end
