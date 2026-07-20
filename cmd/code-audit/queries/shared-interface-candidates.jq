# shared-interface-candidates.jq — find type pairs whose field sets share a large
# MUTUAL intersection: ≥ min_intersection common field names with leftover fields
# on BOTH sides. The recommendation shape is "extract an interface/protocol over
# the intersection and keep both types" — NOT a merge.
#
# Run:  jq -L pipeline/queries -r --argjson min_intersection 5 -f pipeline/queries/shared-interface-candidates.jq catalog.json
#        (-r for raw text output)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -r --argjson min_intersection 5 \
#                -f pipeline/queries/shared-interface-candidates.jq catalog.json
#
# This is the third shape relationship, distinct from the two the suite already
# names, and the residue pattern is what picks each pair's recommendation:
#
#   near-duplicates(-any)   jacc ≥ threshold                 → merge/dedupe
#   subset-pairs            one-sided residue (A ⊂ B)        → composition / Pick / lift
#   THIS QUERY              mutual residue, big intersection → shared interface, keep both
#
# The lanes are lenses, not a partition: a mutual-residue pair with jacc in
# [threshold, 0.9) appears BOTH here and in near-duplicates(-any), which has
# no residue gate. When a pair double-reports, the mutual residue is the
# tiebreaker — it argues for extract-interface over merge even when the
# similarity clears the merge bar.
#
# Canonical instance (wxyc-ios-64): `Playcut` (flowsheet entry) and
# `LikedSongSnapshot` (persisted favorite) share ~13 display fields but each
# carries lifecycle-specific extras — the fix was a `SongDisplayable` protocol
# over the intersection, not a merged model. See
# docs/swift-refactoring-pattern-corpus.md § "Parallel models → shared
# presentation protocol".
#
# Gates (and why):
#   * intersection ≥ $min_intersection — ABSOLUTE size, not just Jaccard: a
#     13-field shared surface is a strong signal even at 50% similarity.
#   * mutual residue — both sides keep fields the other lacks. One-sided
#     residue is subset-pairs' lane; no residue is exact-duplicates'.
#   * 0.25 ≤ jacc < 0.9 — above 0.9 the right recommendation is a merge
#     (near-duplicates-any's lane); below 0.25 the shared names are usually
#     incidental entity boilerplate (id/name/createdAt) on two large types.
#   * both endpoints kind:interface excluded — two overlapping protocols are
#     protocol-inheritance-candidates' lane (same-package today; a cross-
#     package extension of that query is the right home for the gap, not
#     this one). Mixed concrete↔interface pairs DO surface: "this type
#     already nearly satisfies that protocol" is an adjacent finding.
#   * same-name pairs excluded (cross-package-shadows' lane); extensions and
#     enum kinds excluded (partial surfaces / case names aren't field
#     surfaces); generated rows excluded.
#   * ≥1 type-agreeing shared slot — a pair whose ENTIRE intersection is
#     type-conflicting has nothing to put in a protocol requirement list.
#     That shape is an authored-override vs resolved-value pair (optional
#     override fields against their resolved non-optional forms, e.g. a
#     theme-override struct vs the resolved appearance) — a distinct
#     relationship, not an interface candidate.
#   * containment pairs excluded — a side declaring a field whose type IS the
#     other side is a wrapper/facade over composition (a controller mirroring
#     its wrapped model's published state, a struct with forwarding
#     accessors), not two parallel models of one concept. Field-tested on
#     wxyc-ios-64: catches AdaptiveQualityController(loop:
#     QualityOptimizationLoop) and PlaycutMetadata(streaming: StreamingLinks).
#     Forwarding-accessor facades WITHOUT a stored reference still slip
#     through — catching those needs a stored-vs-computed flag in
#     fields_structured (extractor extension, not yet emitted). Known
#     false-drop class in the other direction: a genuine parallel model that
#     merely holds a typed REFERENCE to its sibling (Album.featuredTrack:
#     Track) is indistinguishable from a wrapper here and is dropped;
#     collection references (tracks:[Track]) do not trigger the gate.
#
# Slot comparison is TYPE-AWARE where the flat `fields[]` strings allow:
# each "name:Type" entry splits at the first ':' (function-signature members
# like "fetch(id:String):Track" split inside the parens — same accepted
# convention as every other field-name query). Shared names with EQUAL type
# text become `shared_slots` (the protocol-requirement candidates); shared
# names with DIFFERENT type text become `conflicting_slots`. Conflicting
# slots are the machine-visible merge blockers — `id:UInt64` vs `id:String`
# is deterministic evidence that the pair cannot merge and the extracted
# protocol must not refine Identifiable. Restraint evidence, emitted per row.
#
# Demotion (issue #217 convention, extended): a pair whose two types already
# share a non-trivial protocol carries `demoted: true` and sorts to the tail —
# the abstraction exists, the query self-extinguishes after the refactor it
# recommends. Unlike exact-duplicates, the check reads conformance through
# `conformance_index`, so `extension Foo: P {}` retroactive conformances
# count. Limitation (shared with is_already_abstracted_cluster): the shared
# protocol's requirement set is not checked against THIS pair's intersection,
# so a pair sharing 10 fields but only a small 2-requirement protocol still
# demotes.
#
# Known limitation: the kind filter cannot distinguish SwiftUI View structs
# from data models, so view-chrome duplication (two Views sharing styling
# constants) surfaces here too. The evidence is real, but the right fix there
# is usually a shared view component or modifier, not a protocol — judgment
# stays with the reader.
#
# `--argjson min_intersection N` is REQUIRED for raw jq (compile-time error
# otherwise); the binary supplies the front-matter default (5).
#
# cluster_id format:  shared-interface-candidates:LocA+LocB
#                     (sorted location keys — package:file:line:name)
#
#! query: shared-interface-candidates
#! shape: pair
#! catalog: type-catalog
#! arg: min_intersection number 5
#! formats: text, jsonl
#! desc: Mutual-residue field intersection — extract-an-interface (not merge) candidates.

include "_canonical";

# Normalize a slot's type text for the containment check: drop an existential
# `any ` prefix and trailing optional/IUO markers, so `core:EngineCore?` and
# `engine:any EngineCore` both read as `EngineCore`.
def bare_type_name: sub("^\\s*"; "") | sub("^any\\s+"; "") | sub("[?!]+\\s*$"; "");

. as $catalog
| ($catalog | protocols_index) as $protocols_idx
| ($catalog | conformance_index) as $conf_idx
# Parse each candidate's flat fields ONCE here — "name:Type" → {n, t}; name
# drops a trailing '?' (TS optional marker), type keeps everything after the
# first ':' verbatim. The O(n²) pair loop below only reads the precomputed
# projections (slots, names, name→type map).
| [ entries[]
    | select((.generated // false) != true)
    | select(.kind == "type-alias-object" or .kind == "interface" or .kind == "zod-object")
    # Strictly MORE fields than the intersection floor: mutual residue needs
    # at least one leftover per side, so smaller rows can never qualify.
    | select(.fields != null and (.fields | length) > $min_intersection)
    | (.fields | map(split(":") | {n: (.[0] | sub("\\?$"; "")), t: (.[1:] | join(":"))}) | unique_by(.n)) as $slots
    | {rec: .,
       slots: $slots,
       names: ($slots | map(.n)),
       types: ($slots | map({key: .n, value: .t}) | from_entries)}
  ] as $bs
| [
    range(0; $bs | length) as $i
    | range($i + 1; $bs | length) as $j
    | $bs[$i] as $A | $bs[$j] as $B
    | $A.rec as $a | $B.rec as $b
    | select(($a.kind == "interface" and $b.kind == "interface") | not)
    | select($a.name != $b.name)
    | $A.names as $af
    | $B.names as $bf
    | ([$af[] | . as $x | select($B.types | has($x))]) as $shared_names
    | ($shared_names | length) as $ic
    | select($ic >= $min_intersection)
    # Mutual residue: BOTH sides must keep fields the other lacks.
    | select(($af | length) > $ic and ($bf | length) > $ic)
    # Names are unique per side, so |A ∪ B| = |A| + |B| − |A ∩ B|.
    | (($af | length) + ($bf | length) - $ic) as $u
    | ($ic / $u) as $jacc
    | select($jacc >= 0.25 and $jacc < 0.9)
    # Containment: either side holding a field typed as the other side marks
    # the pair as wrapper-over-composition, not parallel models.
    | select((any($A.slots[]; (.t | bare_type_name) == $b.name)
              or any($B.slots[]; (.t | bare_type_name) == $a.name)) | not)
    | [ $shared_names[] | {name: ., left_type: $A.types[.], right_type: $B.types[.]} ] as $matched
    | ([$matched[] | select(.left_type == .right_type)] | sort_by(.name)) as $agreeing
    # An all-conflicting intersection is an authored-override vs resolved-value
    # pair: no requirement candidates, so no protocol to extract.
    | select(($agreeing | length) > 0)
    | {
        cluster_id: cluster_id_sorted_pair("shared-interface-candidates"; loc_key($a); loc_key($b)),
        query: "shared-interface-candidates",
        shape: "pair",
        intersection: $ic,
        union: $u,
        jacc: $jacc,
        # with_conformance restores each side's own conforms_to over the
        # index lookup (interface inheritance — rationale in _canonical.jq).
        demoted: ([($a | with_conformance($conf_idx)), ($b | with_conformance($conf_idx))]
                  | is_already_abstracted_cluster($protocols_idx)),
        shared_slots: ($agreeing | map({name, type: .left_type})),
        conflicting_slots: ([$matched[] | select(.left_type != .right_type)] | sort_by(.name)),
        left_only:  ([$af[] | . as $x | select(($B.types | has($x)) | not)] | sort),
        right_only: ([$bf[] | . as $x | select(($A.types | has($x)) | not)] | sort),
        left: $a, right: $b,
        left_fields: ($af | sort), right_fields: ($bf | sort)
      }
  ]
# Un-demoted first; within each band, biggest shared surface first.
| sort_by(.demoted, -(.intersection), -(.jacc), .left.name, .right.name)
| .[]
| if output_format == "jsonl" then
    @json
  else
    "\(if .demoted then "[DEMOTED — already abstracted] " else "" end)"
    + "[∩=\(.intersection) ∪=\(.union) \((.jacc * 100) | floor)%] \(.left.package):\(.left.name)  <->  \(.right.package):\(.right.name) cid=\(.cluster_id)\n"
    + "    left:  \(.left.kind) — \(.left.file):\(.left.line)\n"
    + "    right: \(.right.kind) — \(.right.file):\(.right.line)\n"
    + "    shared slots:      \(.shared_slots | map("\(.name):\(.type)") | join(", "))\n"
    + "    conflicting slots: \(if (.conflicting_slots | length) == 0 then "(none)" else (.conflicting_slots | map("\(.name) (\(.left_type) vs \(.right_type))") | join(", ")) end)\n"
    + "    left only:         \(.left_only | join(", "))\n"
    + "    right only:        \(.right_only | join(", "))"
  end
