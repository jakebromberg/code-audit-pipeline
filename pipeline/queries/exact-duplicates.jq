# exact-duplicates.jq — find type clusters with the same shape_sig
#
# Run:  jq -rf exact-duplicates.jq catalog.json    (-r for raw multi-line output)
#
# Output: one cluster per group, ordered by cluster size (largest first).
# An asterisk (*) marks declarations touched during the audit window.

[ .[] | select(.shape_sig != null and .shape_sig != "") ]
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
