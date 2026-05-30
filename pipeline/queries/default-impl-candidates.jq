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
# the constraint). Lower it for broader recall against thin substrates — e.g.,
# the round-1 smoke test uses `--argjson min_conformers 2` to surface plants
# 3.2, 3.3, 3.4 alongside 3.1 even before all four plants are fully synthesized.
#
# Architectural caveat: the query does NOT verify that the distinct types share
# a protocol — that requires protocol-conformance edges (methodology §6.2), a
# separate substrate enrichment not in this PR. Until conformance edges land,
# the candidate set is broader than the strict Cat 3 shape; the agent + the
# downstream specifics-tolerance flags filter the noise.
#
# Performance: 0.01s on the planted catalog (N=1154 functions). group_by is
# O(N log N); the per-group distinct-types check is O(k) for each hash group.
#
# Output: one row per cluster, ordered by conformer-count desc then body-line-
# count desc.
#
# cluster_id format:  default-impl-candidates:LocA+LocB+...
#                     (sorted location keys — package:file:line:name)
#
#! shape: cluster

include "_canonical";

# `type_of` lives in `_canonical.jq` as a shared naming utility.

entries as $all
| [ $all[]
    | select((.generated // false) != true)
    | select((.body_line_count // 0) >= 3)
  ] as $fns
| [ $fns
    | group_by(.body_hash)
    | .[]
    # Fast-path: drop body-hash groups smaller than min_conformers before
    # computing distinct types. distinct_types <= length, so the second
    # filter below is the load-bearing check; this one short-circuits the
    # `unique` work for hash groups that obviously can't qualify.
    | select(length >= $min_conformers)
    # Cluster must span >= min_conformers DISTINCT types (across any packages).
    | (map(type_of(.name)) | unique) as $types
    | select(($types | length) >= $min_conformers)
    | (map(.package) | unique) as $pkgs
    | { cluster_id: cluster_id_sorted_names("default-impl-candidates"; map(loc_key(.))),
        query: "default-impl-candidates",
        shape: "cluster",
        packages: $pkgs,
        pkg_count: ($pkgs | length),
        body_hash: .[0].body_hash,
        body_line_count: .[0].body_line_count,
        distinct_type_count: ($types | length),
        distinct_types: $types,
        members: map({name, kind, package, file, line, async, param_count}) }
  ]
| sort_by(-(.distinct_type_count), -(.body_line_count))
| .[]
| if output_format == "jsonl" then
    @json
  else
    "[\(.distinct_type_count) types across \(.pkg_count) pkg(s), \(.body_line_count) lines, \(.members | length) decls] cid=\(.cluster_id)\n"
    + "    packages: \(.packages | join(", "))\n"
    + "    types: \(.distinct_types | join(", "))\n"
    + (.members
       | map("    \(.name)\(if .async then " (async)" else "" end) [\(.kind), arity=\(.param_count)] — \(.package):\(.file):\(.line)")
       | join("\n"))
  end
