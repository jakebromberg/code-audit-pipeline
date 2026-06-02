# cross-package-shape-near-duplicates.jq — find shape-similar types across packages
# whose NAMES differ, so the existing cross-package-shadows query misses them.
#
# Run:  jq -L pipeline/queries -r --argjson threshold 0.7 -f pipeline/queries/cross-package-shape-near-duplicates.jq catalog.json
#        (-r for raw text output)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -r --argjson threshold 0.7 -f pipeline/queries/cross-package-shape-near-duplicates.jq catalog.json
#
# Signals: main-package types that should probably be importing from shared/, but
# have been re-declared with a different name. Catches the "re-typed contract" antipattern.
#
# The shared/ side may include generated/ codegen entries — they ARE the canonical
# contract we compare against. Main-side generated entries are filtered (codegen noise).
#
# Pairs with the same name are excluded (those belong to cross-package-shadows).
# Exact-shape-match pairs (Jaccard 1.0) ARE included — different name, same shape across
# packages is the highest-signal finding.
#
# `--argjson threshold 0.7` is REQUIRED — jq errors at compile time on an undefined variable.
#
# cluster_id format:  cross-package-shape-near-duplicates:LocA+LocB
#                     (sorted location keys — package:file:line:name)
#
# Envelope: shape: "pair". Asymmetric pair — left=main, right=shared. Text
# mode preserves the role labels (`main:` / `shared:`); JSONL uses
# `left` / `right` per the envelope contract.
#
#! query: cross-package-shape-near-duplicates
#! shape: pair
#! catalog: type-catalog
#! arg: threshold number required
#! formats: text, jsonl
#! desc: Re-typed contract: main vs shared shape-similar but name-different pairs.

include "_canonical";

entries as $all
| $threshold as $thr
| ([ $all[]
     | select(.fields != null and (.fields | length) >= 3)
     | select(.kind | startswith("type-alias") or . == "interface" or . == "zod-object")
   ]) as $candidates

| ([ $candidates[] | select(.package == "main" and (.generated // false) != true) ]) as $mains
| ([ $candidates[] | select(.package == "shared") ]) as $shareds

| [ range(0; $mains | length) as $i
    | range(0; $shareds | length) as $j
    | $mains[$i] as $a | $shareds[$j] as $b
    | select($a.name != $b.name)
    | ($a.fields | map(split(":") | .[0]) | map(sub("\\?$"; "")) | unique) as $af
    | ($b.fields | map(split(":") | .[0]) | map(sub("\\?$"; "")) | unique) as $bf
    | ($af + $bf | unique | length) as $u
    | select($u > 0)
    | ([$af[] | select(. as $x | $bf | index($x) != null)] | length) as $ic
    | ($ic / $u) as $jacc
    | select($jacc >= $thr and ($af | length) >= 3 and ($bf | length) >= 3)
    | { cluster_id: cluster_id_sorted_pair("cross-package-shape-near-duplicates"; loc_key($a); loc_key($b)),
        query: "cross-package-shape-near-duplicates",
        shape: "pair",
        jacc: $jacc, left: $a, right: $b, left_fields: $af, right_fields: $bf, intersection: $ic, union: $u,
        right_only: ([$bf[] | . as $x | select(($af | index($x)) == null)]),
        left_only:  ([$af[] | . as $x | select(($bf | index($x)) == null)])
      }
  ]
| sort_by(-(.jacc), .left.name, .right.name)
| .[]
| if output_format == "jsonl" then
    @json
  else
    "[\((.jacc * 100) | floor)%  ∩=\(.intersection) ∪=\(.union)] main:\(.left.name)  <->  shared:\(.right.name) cid=\(.cluster_id)\n"
    + "    main:    \(.left.kind) — \(.left.file):\(.left.line)\n"
    + "    shared:  \(.right.kind)\(if .right.generated then " (generated)" else "" end) — \(.right.file):\(.right.line)\n"
    + "    shared field names: \(.right_fields | join(", "))\n"
    + "    shared only:        \(.right_only | join(", "))\n"
    + "    main only:          \(.left_only | join(", "))"
  end
