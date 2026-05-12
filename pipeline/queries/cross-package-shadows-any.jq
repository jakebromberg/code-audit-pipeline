# cross-package-shadows-any.jq — find type names that appear in MORE THAN ONE
# package. Strong signal that one of the redeclarations should be an import.
#
# Run:  jq -rf cross-package-shadows-any.jq catalog.json
#
# Unlike cross-package-shadows.jq (which asymmetrically reports main-package
# names that exist in shared, assuming shared is canonical), this query is
# symmetric and N-package: any name appearing in ≥2 distinct packages surfaces,
# with all occurrences listed. Intended for codebases with multiple internal
# packages where no single one is the canonical types module.

. as $all
| [ $all[]
    | select(.kind | startswith("type-alias") or . == "interface" or . == "zod-object")
    | select((.generated // false) != true)
  ]
| group_by(.name)
| map(select((map(.package) | unique | length) > 1))
| map({
    name: .[0].name,
    locations: map({package, kind, file, line, shape_sig, touched_in_window})
  })
| sort_by(-(.locations | length), .name)
| .[]
| "\(.name)  [\(.locations | length) packages, \(.locations | map(.package) | unique | length) distinct]\n"
  + (.locations
      | map("    \(if .touched_in_window then "*" else " " end) \(.package): \(.kind) — \(.file):\(.line)"
            + (if .shape_sig then "  sig=" + (.shape_sig | .[0:80]) else "" end))
      | join("\n"))
