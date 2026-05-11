# name-collisions.jq — find type names declared in multiple files
#
# Run:  jq -rf name-collisions.jq catalog.json    (-r for raw multi-line output)
#
# Useful for catching: same name across different files (often unintentional
# shadowing), and same name with semantically different shapes (the
# "antipattern of name overloading").

group_by(.name)
| map(select(length > 1))
| map(select((map(.file) | unique | length) > 1))
| map({
    name: .[0].name,
    decls: map({kind, package, file, line, touched_in_window, shape_sig})
  })
| sort_by(-(.decls | length), .name)
| .[]
| "\(.name) (\(.decls | length))\n"
  + (.decls
      | map("  \(if .touched_in_window then "*" else " " end) [\(.kind)] \(.package):\(.file):\(.line)"
            + (if .shape_sig then "  sig=" + (.shape_sig | .[0:80]) else "" end))
      | join("\n"))
