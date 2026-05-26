# generic-arity-drift.jq — declarations sharing a name but differing in
# type-parameter arity (overload-style drift).
#
# Run:  jq -L pipeline/queries -rf pipeline/queries/generic-arity-drift.jq catalog.json
#        (-r for raw multi-line text output)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -rf pipeline/queries/generic-arity-drift.jq catalog.json
#
# Catches cases like Repository<T> vs Repository<T, K> declared in different
# files — usually a sign these should be unified into one generic declaration
# with the wider parameter set. The output is fully deterministic: it's a
# function of the `generics` field the extractor already emits.
#
# Scope: restricted to `interface` and `type-alias-*` kinds. Zod and Drizzle
# kinds don't carry user-authored `generics` in any current extractor and
# would produce noise rows whenever a zod-object and an interface happen to
# share a name.
#
# cluster_id format:  generic-arity-drift:Name  (the colliding name)

include "_canonical";

# Comma-counted arity. Treat null and "" as zero so non-generic decls cluster
# together (the contract permits omission, the TS extractor emits null).
def arity: if . == null or . == "" then 0 else (split(",") | length) end;

[ entries[]
  | select((.generated // false) != true)
  | select((.kind // "") | startswith("interface") or startswith("type-alias"))
  | . + {_arity: (.generics | arity)} ]
| group_by(.name)
| map(select(length > 1))
| map(select((map(._arity) | unique | length) > 1))
| map({
    cluster_id: cluster_id_single_name("generic-arity-drift"; .[0].name),
    query: "generic-arity-drift",
    name: .[0].name,
    decls: (map({
      kind, package, file, line, touched_in_window,
      arity: ._arity,
      generics: (.generics // "")
    }) | sort_by(.arity, .package, .file, .line))
  })
| sort_by(-(.decls | length), .name)
| .[]
| if output_format == "jsonl" then
    @json
  else
    "\(.name) (\(.decls | length) decls, arities differ) cid=\(.cluster_id)\n"
    + (.decls
        | map("  \(if .touched_in_window then "*" else " " end) [\(.kind)] <\(if .generics == "" then "—" else .generics end)> arity=\(.arity) — \(.package):\(.file):\(.line)")
        | join("\n"))
  end
