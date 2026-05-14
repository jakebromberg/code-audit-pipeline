# default-impl-candidates.jq — find function-body clusters that suggest a missing default impl.
#
# Run:  jq -L pipeline/queries -r --argjson min_conformers 3 \
#         --slurpfile types <type-catalog.json> \
#         -f pipeline/queries/default-impl-candidates.jq function-catalog.json
#        (-r for raw multi-line text output)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -r --argjson min_conformers 3 \
#                --slurpfile types <type-catalog.json> \
#                -f pipeline/queries/default-impl-candidates.jq function-catalog.json
#
# Surfaces V7 refactor-recommendation Category 3 candidates: ≥ min_conformers
# functions with byte-identical normalized bodies, declared on distinct types
# that share at least one protocol via the V7 §6.2 `conforms_to` enrichment.
# A cluster of N identical method bodies across N types with at least one
# common protocol is the substrate signal for "the method should live as a
# protocol extension default, not be copy-pasted onto each conformer."
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
# Shared-protocol join. The query loads `type-catalog.json` via `--slurpfile types`
# to look up each cluster member's `conforms_to[]`. The cluster's
# `shared_protocols` is the intersection of all member types' `conforms_to[]`;
# if that intersection is empty, the cluster doesn't surface (no protocol to
# default-impl onto). Side effect: free functions (no enclosing type) drop
# out because they have no type-catalog record to look up.
#
# Class-vs-protocol caveat (acknowledged, not closed): the V7 §6.2 enrichment
# captures the inheritance-clause name list — for classes, the first entry
# MAY be a parent class rather than a protocol, and the syntax layer can't
# distinguish them. A cluster whose "shared_protocols" turns out to be a
# shared parent class will still surface; the agent's downstream judgment
# discriminates default-impl-on-protocol from lift-into-superclass. The
# distinct class-inheritance-edge enrichment is V7 §6.3 round 2 scope.
#
# `--argjson min_conformers 3` is REQUIRED. The methodology's canonical Cat 3
# shape is "≥ 3 conformers" (the synthesis tally in the candidates doc carries
# the constraint). Lower it for broader recall against thin substrates — e.g.,
# the round-1 smoke test uses `--argjson min_conformers 2` to surface plants
# 3.2, 3.3, 3.4 alongside 3.1 even before all four plants are fully synthesized.
#
# Performance: 0.02s on the planted catalog (N=1154 functions, ~250 distinct
# types after `type_of` projection). group_by + the from_entries lookup are
# both O(N log N).
#
# Output: one row per cluster, ordered by conformer-count desc then body-line-
# count desc.
#
# cluster_id format:  default-impl-candidates:LocA+LocB+...
#                     (sorted location keys — package:file:line:name)

include "_canonical";

# Build a name → conforms_to[] lookup over the slurped type-catalog. Records
# that don't declare any conformances (or whose `conforms_to` is null for
# kinds without an inheritance clause, like typealiases) map to []. Same-name
# collisions across packages collapse to the LAST entry; in practice
# default-impl-candidates' type_of names are qualified enough that collisions
# are rare, and an over-tight intersection from a collision just means the
# cluster doesn't surface (false negative, not false positive).
($types[0] | map({key: .name, value: (.conforms_to // [])}) | from_entries) as $conforms_index

| (. as $all
   | [ $all[]
       | select((.generated // false) != true)
       | select((.body_line_count // 0) >= 3)
     ]) as $fns

| [ $fns
    | group_by(.body_hash)
    | .[]
    # Fast-path: drop body-hash groups smaller than min_conformers before
    # computing distinct types. distinct_types <= length, so the type-count
    # filter below is the load-bearing one; this short-circuits the `unique`
    # work for hash groups that obviously can't qualify.
    | select(length >= $min_conformers)
    | (map(type_of(.name)) | unique) as $types_in_cluster
    | select(($types_in_cluster | length) >= $min_conformers)
    # V7 §6.2 shared-protocol filter: each type's conforms_to[] is looked up;
    # the cluster's shared_protocols is their intersection. Free functions
    # (no enclosing type) miss the lookup → conforms_to = [] → intersection
    # collapses → cluster drops out.
    | ($types_in_cluster | map($conforms_index[.] // [])) as $per_type_conforms
    | (if ($per_type_conforms | length) == 0
       then []
       else $per_type_conforms[0]
            | reduce ($per_type_conforms[1:][]) as $next ([.[]];
                [.[] | select($next | index(.))])
       end) as $shared_protocols
    | select(($shared_protocols | length) >= 1)
    | (map(.package) | unique) as $pkgs
    | { cluster_id: cluster_id_sorted_names("default-impl-candidates"; map(loc_key(.))),
        query: "default-impl-candidates",
        packages: $pkgs,
        pkg_count: ($pkgs | length),
        body_hash: .[0].body_hash,
        body_line_count: .[0].body_line_count,
        distinct_type_count: ($types_in_cluster | length),
        distinct_types: $types_in_cluster,
        shared_protocols: $shared_protocols,
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
    + "    shared protocols: \(.shared_protocols | join(", "))\n"
    + (.decls
       | map("    \(.name)\(if .async then " (async)" else "" end) [\(.kind), arity=\(.param_count)] — \(.package):\(.file):\(.line)")
       | join("\n"))
  end
