# pat-candidates.jq — find protocol pairs that suggest a missing PAT (protocol with associated type).
#
# Run:  jq -L pipeline/queries -r --argjson max_slot_diffs 1 -f pipeline/queries/pat-candidates.jq type-catalog.json
#        (-r for raw multi-line text output)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -r --argjson max_slot_diffs 1 -f pipeline/queries/pat-candidates.jq type-catalog.json
#
# Surfaces V7 refactor-recommendation Category 4 candidates: type pairs whose
# member-name sets match exactly, but whose full `name:type` field strings
# differ at ≤ max_slot_diffs slots. The differing slot is the candidate
# associated type — replace it with `associatedtype X` in a common parent
# protocol and the two types collapse into one PAT.
#
# Both `interface` (Swift protocol) and `type-alias-object` (Swift struct) are
# considered. The methodology's plant 4.1 (`NowPlayingItem` / `PlaycutSelection`)
# is a struct pair the agent is expected to lift into a new PAT-shaped protocol;
# the canonical Cat 4 framing is protocol-pair, but the substrate signal lives
# in struct shape just as readily. Cross-kind pairs are emitted too (struct ↔
# protocol with identical field-name sets), since those are real lift candidates.
#
# Strict shape match: both protocols must have identical sorted field-name sets
# AND identical field count. The diff is on the typed field strings, where the
# difference counts each "name:typeA" / "name:typeB" mismatch as one slot diff.
# A diff_count of 0 would mean identical shape_sig (already covered by
# exact-duplicates); 1 is the canonical PAT signature; 2+ is a fuzzier match
# the methodology generally classifies elsewhere.
#
# Cross-package pairs are KEPT. Cat 4's lift target is often a Shared/ package
# upstream of both conformers; restricting to same-package would hide the
# methodology's plant 4.1 (`NowPlayingItem` in AppServices ↔ `PlaycutSelection`
# in app:iOS).
#
# Overlap with other queries: a same-package interface pair with identical name
# sets + 1 slot diff fires here AND in `protocol-inheritance-candidates.jq`
# (which keys on name-set overlap, not identity). Same shape, two lenses — the
# agent picks the PAT framing vs the missing-parent framing. Cluster_id prefixes
# differ, so no scorer collision.
#
# Slot-diff caveat: each diffing position counts as one slot diff regardless of
# whether the difference is at the type ("foo:A" vs "foo:B") or at the
# optionality ("foo?:A" vs "foo:A"). An optionality-only diff is a less
# interesting PAT candidate than a type-only diff; the agent's discrimination
# handles it. A future tightening could decompose `slot_diff_count` into
# `type_diff_count` and `optionality_diff_count`.
#
# Field-name extraction uses `sort` (not `unique`) — duplicate-name fields are
# preserved as separate slots. Swift protocols / structs don't legally declare
# duplicate field names, so in practice `sort` and `unique` produce the same
# multiset; using `sort` makes the diff-counting loop (zip-and-mismatch) correct
# even if a future extractor surface introduces duplicate-name records.
# `protocol-inheritance-candidates.jq` uses `unique` because it computes a name-
# set INTERSECTION, where dedup is the right semantic.
#
# `--argjson max_slot_diffs 1` is REQUIRED. The canonical PAT shape is exactly
# 1 slot diff; raise to 2-3 for fuzzier near-PAT pairs.
#
# Performance: 1.3s on the planted catalog (N=815 types, ~120 interface/struct
# survivors of the kind+length filter). Pair iteration is O(N²); the per-pair
# work is O(field_count) for the sort + zip. Scales as O(N² * field_count);
# expect ~30s on a 5000-type catalog (extrapolated from the 1.3s baseline; not
# measured) before further tuning.
#
# Output: one row per protocol pair, ordered by field_count desc then slot diff
# asc (cleanest matches first).
#
# cluster_id format:  pat-candidates:LocA+LocB
#                     (sorted location keys — package:file:line:name)
#
#! shape: pair

include "_canonical";

[ entries[]
  | select((.generated // false) != true)
  | select(.kind == "interface" or .kind == "type-alias-object")
  | select(.fields != null and (.fields | length) >= 2)
] as $protos
| [
    range(0; $protos | length) as $i
    | range($i + 1; $protos | length) as $j
    | $protos[$i] as $a | $protos[$j] as $b
    | ($a.fields | map(split(":") | .[0]) | map(sub("\\?$"; "")) | sort) as $a_names
    | ($b.fields | map(split(":") | .[0]) | map(sub("\\?$"; "")) | sort) as $b_names
    | select($a_names == $b_names)
    | ($a.fields | sort) as $af | ($b.fields | sort) as $bf
    | select(($af | length) == ($bf | length))
    # Count slot diffs by zipping sorted fields and counting mismatches.
    | ([ range(0; $af | length) | select($af[.] != $bf[.]) ] | length) as $diff_count
    | select($diff_count >= 1 and $diff_count <= $max_slot_diffs)
    | { cluster_id: cluster_id_sorted_pair("pat-candidates"; loc_key($a); loc_key($b)),
        query: "pat-candidates",
        shape: "pair",
        field_count: ($af | length),
        slot_diff_count: $diff_count,
        shared_member_names: $a_names,
        left_slots: [ range(0; $af | length) | select($af[.] != $bf[.]) | $af[.] ],
        right_slots: [ range(0; $bf | length) | select($af[.] != $bf[.]) | $bf[.] ],
        left: $a, right: $b }
  ]
| sort_by(-(.field_count), .slot_diff_count, .left.name)
| .[]
| if output_format == "jsonl" then
    @json
  else
    "[\(.field_count) fields, \(.slot_diff_count) slot diff(s)] \(.left.name) (\(.left.kind)) <-> \(.right.name) (\(.right.kind)) cid=\(.cluster_id)\n"
    + "    left:  \(.left.package):\(.left.file):\(.left.line)\n"
    + "    right: \(.right.package):\(.right.file):\(.right.line)\n"
    + "    shared names: \(.shared_member_names | join(", "))\n"
    + "    left slot(s):  \(.left_slots | join(" | "))\n"
    + "    right slot(s): \(.right_slots | join(" | "))"
  end
