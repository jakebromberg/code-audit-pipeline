# exact-duplicates.jq — find type clusters with the same shape_sig
#
# Run:  jq -rf exact-duplicates.jq catalog.json    (-r for raw multi-line output)
#
# Output: one cluster per group, ordered by cluster size (largest first).
# An asterisk (*) marks declarations touched during the audit window.

# V2 substrate: filter `generated: true` to suppress OpenAPI-codegen-internal duplication noise
# (codegen output declares every type both in its own file and again in a consolidated `.d.ts`,
# producing 50+ "duplicate" clusters that an agent already understands as codegen, not drift).
# Cross-package-shadows still surfaces main↔shared/generated collisions, which is the real signal.
[ .[] | select(.shape_sig != null and .shape_sig != "" and (.generated // false) != true) ]
| group_by(.shape_sig)
| map(select(length > 1))
| map({
    shape_sig: .[0].shape_sig,
    field_count: (.[0].fields | length),
    decls: map({name, kind, package, file, line, touched_in_window})
  })
| sort_by(-(.decls | length))
| .[]
| "[\(.field_count) fields, \(.decls | length) decls]\n"
  + (.decls
      | map("  \(if .touched_in_window then "*" else " " end) \(.name) (\(.kind)) — \(.package):\(.file):\(.line)")
      | join("\n"))
