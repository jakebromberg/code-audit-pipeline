# generic-struct-candidates.jq — find struct pairs that suggest a generic struct
# parameterization.
#
# Run:  jq -L pipeline/queries -r --argjson max_slot_diffs 1 -f pipeline/queries/generic-struct-candidates.jq type-catalog.json
#        (-r for raw multi-line text output)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -r --argjson max_slot_diffs 1 -f pipeline/queries/generic-struct-candidates.jq type-catalog.json
#
# Surfaces V7 refactor-recommendation Category 5 struct-shaped candidates
# (plants 5.3, 5.4): struct pairs (`kind == "type-alias-object"`) whose
# member-name sets match exactly, but whose full `name:type` field strings
# differ at ≤ max_slot_diffs slots. The differing slot is the candidate
# type parameter — replace it with `<T>` and the two structs collapse into a
# single generic struct `Foo<T>`.
#
# Closely related to `pat-candidates.jq`, which surfaces the same shape but
# without the kind restriction (and intended for the protocol-pair lens).
# Phase D scoring uses both queries' output: a struct-pair row appears in both
# pat-candidates and generic-struct-candidates because the right answer depends
# on whether the lift target is a PAT (associated type on a protocol) or a
# generic struct (type parameter on a concrete container). The two queries are
# the same shape; the agent decides which framing to use.
#
# Same convention as pat-candidates.jq: identical sorted field-name sets,
# diff_count counts mismatched typed-field strings.
#
# Field-name extraction uses `sort` (not `unique`) — see
# `pat-candidates.jq`'s header for the rationale (preserves duplicate-name
# multiset for zip-and-mismatch correctness).
#
# `--argjson max_slot_diffs 1` is REQUIRED. The canonical generic-struct shape
# is exactly 1 slot diff; raise for fuzzier candidates.
#
# Performance: 1.1s on the planted catalog (N=815 types, ~70 struct survivors).
# Pair iteration is O(N²); expect ~25s on a 5000-type catalog (extrapolated
# from the 1.1s baseline; not measured). Faster than pat-candidates because the
# kind restriction prunes earlier.
#
# Output: one row per struct pair, ordered by field_count desc then slot diff
# asc (cleanest matches first).
#
# cluster_id format:  generic-struct-candidates:LocA+LocB
#                     (sorted location keys — package:file:line:name)

include "_canonical";

[ entries[]
  | select((.generated // false) != true)
  | select(.kind == "type-alias-object")
  | select(.fields != null and (.fields | length) >= 2)
] as $structs
| [
    range(0; $structs | length) as $i
    | range($i + 1; $structs | length) as $j
    | $structs[$i] as $a | $structs[$j] as $b
    | ($a.fields | map(split(":") | .[0]) | map(sub("\\?$"; "")) | sort) as $a_names
    | ($b.fields | map(split(":") | .[0]) | map(sub("\\?$"; "")) | sort) as $b_names
    | select($a_names == $b_names)
    | ($a.fields | sort) as $af | ($b.fields | sort) as $bf
    | select(($af | length) == ($bf | length))
    | ([ range(0; $af | length) | select($af[.] != $bf[.]) ] | length) as $diff_count
    | select($diff_count >= 1 and $diff_count <= $max_slot_diffs)
    | { cluster_id: cluster_id_sorted_pair("generic-struct-candidates"; loc_key($a); loc_key($b)),
        query: "generic-struct-candidates",
        field_count: ($af | length),
        slot_diff_count: $diff_count,
        shared_member_names: $a_names,
        a_slots: [ range(0; $af | length) | select($af[.] != $bf[.]) | $af[.] ],
        b_slots: [ range(0; $bf | length) | select($af[.] != $bf[.]) | $bf[.] ],
        a: $a, b: $b }
  ]
| sort_by(-(.field_count), .slot_diff_count, .a.name)
| .[]
| if output_format == "jsonl" then
    @json
  else
    "[\(.field_count) fields, \(.slot_diff_count) slot diff(s)] \(.a.name) <-> \(.b.name) cid=\(.cluster_id)\n"
    + "    A: \(.a.package):\(.a.file):\(.a.line)" + (if .a.generics then "  generics=\(.a.generics)" else "" end) + "\n"
    + "    B: \(.b.package):\(.b.file):\(.b.line)" + (if .b.generics then "  generics=\(.b.generics)" else "" end) + "\n"
    + "    shared names: \(.shared_member_names | join(", "))\n"
    + "    A slot(s): \(.a_slots | join(" | "))\n"
    + "    B slot(s): \(.b_slots | join(" | "))"
  end
