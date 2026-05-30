# protocol-inheritance-candidates.jq — find same-package protocol pairs sharing ≥N member names.
#
# Run:  jq -L pipeline/queries -r --argjson min_overlap 2 -f pipeline/queries/protocol-inheritance-candidates.jq type-catalog.json
#        (-r for raw multi-line text output)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -r --argjson min_overlap 2 -f pipeline/queries/protocol-inheritance-candidates.jq type-catalog.json
#
# Surfaces "sibling-with-missing-parent" candidates per V7 refactor-recommendation
# Category 2: two protocols (kind == "interface") in the same package whose
# member-name sets overlap on ≥ min_overlap names. The shared surface is a
# candidate for lifting into a common parent protocol; the non-shared members
# stay on the children. Filtering to same-package keeps the candidate set close
# to the package-scoped lift the methodology models — cross-package overlap is
# already covered by Cat 1 / Cat 4 queries.
#
# Comparison is on field NAMES only (`?` optionality and types ignored), same
# convention as near-duplicates.jq / subset-pairs.jq. Each interface must have
# `(.fields | length) >= 2` to suppress noisy single-method protocols.
#
# `--argjson min_overlap 2` is REQUIRED — jq errors at compile time on an
# undefined variable. The Phase A.2 candidates doc uses `>= 2` as the kernel.
#
# Performance: 0.01s on the planted catalog (N=815 types; pair iteration is
# O(N²) over interfaces, but the same-package filter prunes most pairs
# cheaply).
#
# Output: one row per protocol pair, ordered by overlap desc then package.
# Each row names both protocols, the shared member-name set, and each side's
# extras.
#
# cluster_id format:  protocol-inheritance-candidates:LocA+LocB
#                     (sorted location keys — package:file:line:name)
#
#! shape: pair

include "_canonical";

[ entries[]
  | select((.generated // false) != true)
  | select(.kind == "interface")
  | select(.fields != null and (.fields | length) >= 2)
] as $protos
| [
    range(0; $protos | length) as $i
    | range($i + 1; $protos | length) as $j
    | $protos[$i] as $a | $protos[$j] as $b
    | select($a.package == $b.package)
    | ($a.fields | map(split(":") | .[0]) | map(sub("\\?$"; "")) | unique) as $af
    | ($b.fields | map(split(":") | .[0]) | map(sub("\\?$"; "")) | unique) as $bf
    | ([$af[] | select(. as $f | $bf | index($f) != null)] | unique) as $shared
    | select(($shared | length) >= $min_overlap)
    | { cluster_id: cluster_id_sorted_pair("protocol-inheritance-candidates"; loc_key($a); loc_key($b)),
        query: "protocol-inheritance-candidates",
        shape: "pair",
        package: $a.package,
        overlap: ($shared | length),
        shared_members: $shared,
        left_only:  [$af[] | select(. as $f | $shared | index($f) == null)],
        right_only: [$bf[] | select(. as $f | $shared | index($f) == null)],
        left: $a, right: $b }
  ]
| sort_by(-(.overlap), .package, .left.name)
| .[]
| if output_format == "jsonl" then
    @json
  else
    "[\(.package)  overlap=\(.overlap)] \(.left.name) <-> \(.right.name) cid=\(.cluster_id)\n"
    + "    left:  \(.left.package):\(.left.file):\(.left.line)\n"
    + "    right: \(.right.package):\(.right.file):\(.right.line)\n"
    + "    shared: \(.shared_members | join(", "))\n"
    + "    left-only:  \(.left_only | join(", "))\n"
    + "    right-only: \(.right_only | join(", "))"
  end
