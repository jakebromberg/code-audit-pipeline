# default-impl-candidates.jq — find function-body clusters that suggest a missing default impl.
#
# Run:  jq -L pipeline/queries -r --argjson min_conformers 3 -f pipeline/queries/default-impl-candidates.jq function-catalog.json
#        (-r for raw multi-line text output)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -r --argjson min_conformers 3 -f pipeline/queries/default-impl-candidates.jq function-catalog.json
#
# Surfaces V7 refactor-recommendation Category 3 candidates: ≥ min_conformers
# functions with byte-identical normalized bodies, declared on distinct types.
# A cluster of N identical method bodies across N types is the substrate signal
# for "the method should live as a protocol extension default, not be copy-
# pasted onto each conformer."
#
# Distinct types are detected by stripping the last `.method` segment from
# qualified `name` (`ClassName.method` → `ClassName`). Free functions retain
# their full name as the "type" key — they would not normally cluster with
# methods on a type, but the substrate emits free functions and methods through
# the same pipe so the filter must tolerate both.
#
# Packages are NOT constrained. The methodology's plant 3.1 (HSBColor /
# AccentColor / HSBOffset init) spans ColorPalette + Wallpaper, and the
# expected refactor lifts a protocol into a common upstream package. Per-
# package default impl is one shape Cat 3 takes, but not the only one — the
# query surfaces candidates; the agent picks the lift target.
#
# `--argjson min_conformers 3` is REQUIRED. The methodology's canonical Cat 3
# shape is "≥ 3 conformers" (the synthesis tally in the candidates doc carries
# the constraint). Lower it for broader recall against thin substrates.
#
# Output: one row per cluster, ordered by conformer-count desc then body-line-
# count desc.
#
# cluster_id format:  default-impl-candidates:LocA+LocB+...
#                     (sorted location keys — package:file:line:name)

include "_canonical";

def type_of(name):
  # Split on '.' and drop the last segment. For `Foo.bar` returns `Foo`;
  # for `Foo.Bar.baz` returns `Foo.Bar`. For `freeFunction` (no dot) returns
  # the full name — free functions stay distinct from each other.
  (name | split(".")) as $parts
  | if ($parts | length) <= 1 then name
    else ($parts[0:-1] | join("."))
    end;

. as $all
| [ $all[]
    | select((.generated // false) != true)
    | select((.body_line_count // 0) >= 3)
  ] as $fns
| [ $fns
    | group_by(.body_hash)
    | .[]
    | select(length >= $min_conformers)
    # Cluster must span >= min_conformers DISTINCT types (across any packages).
    | (map(type_of(.name)) | unique) as $types
    | select(($types | length) >= $min_conformers)
    | (map(.package) | unique) as $pkgs
    | { cluster_id: cluster_id_sorted_names("default-impl-candidates"; map(loc_key(.))),
        query: "default-impl-candidates",
        packages: $pkgs,
        pkg_count: ($pkgs | length),
        body_hash: .[0].body_hash,
        body_line_count: .[0].body_line_count,
        distinct_type_count: ($types | length),
        distinct_types: $types,
        decls: map({name, kind, package, file, line, async, param_count}) }
  ]
| sort_by(-(.distinct_type_count), -(.body_line_count))
| .[]
| if output_format == "jsonl" then
    @json
  else
    "[\(.distinct_type_count) types across \(.pkg_count) pkg(s), \(.body_line_count) lines, \(.decls | length) decls] cid=\(.cluster_id)\n"
    + "    packages: \(.packages | join(", "))\n"
    + "    types: \(.distinct_types | join(", "))\n"
    + (.decls
       | map("    \(.name)\(if .async then " (async)" else "" end) [\(.kind), arity=\(.param_count)] — \(.package):\(.file):\(.line)")
       | join("\n"))
  end
