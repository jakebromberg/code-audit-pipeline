# near-duplicates.jq — find type pairs with field-name Jaccard ≥ threshold.
#
# Run:  jq -L pipeline/queries -r --argjson threshold 0.7 -f pipeline/queries/near-duplicates.jq catalog.json
#        (-r for raw text output)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -r --argjson threshold 0.7 -f pipeline/queries/near-duplicates.jq catalog.json
#
# Output: pairs ordered by similarity (highest first). Each line shows the
# two type identities and the field sets being compared.
#
# Threshold is on field NAMES only (ignoring types). 0.7 typically catches
# legitimate "should be unified" pairs; lower for broader recall, higher to
# focus only on near-exact matches.
#
# Each row carries a `demoted` boolean (issue #217). When true, both endpoints
# already conform to the same non-trivial protocol — i.e., the abstraction the
# duplication "should" become already exists. Demoted pairs are still emitted
# (signal not lost) but sorted to the tail in text mode and carry
# `demoted: true` in JSONL mode so downstream consumers can filter. Pair
# queries pass the 2-element array `[left, right]` to the cluster predicate;
# the predicate's contract is "an array of decls."
#
# cluster_id format:  near-duplicates:LocA+LocB  (sorted location keys
#                                                 — package:file:line:name)
#
#! query: near-duplicates
#! shape: pair
#! catalog: type-catalog
#! arg: threshold number required
#! formats: text, jsonl
#! desc: Type pairs whose field-name sets have Jaccard >= threshold but != 1.

include "_canonical";

. as $catalog
| ($catalog | protocols_index) as $protocols_idx
| [ entries[] | select(.package == "main" and .fields and (.fields | length) >= 3) ] as $bs
| [
    range(0; $bs | length) as $i
    | range($i + 1; $bs | length) as $j
    | $bs[$i] as $a | $bs[$j] as $b
    | ($a.fields | map(split(":") | .[0]) | map(sub("\\?$"; ""))) as $af
    | ($b.fields | map(split(":") | .[0]) | map(sub("\\?$"; ""))) as $bf
    | ($af + $bf | unique | length) as $u
    | ([$af, $bf] | .[0] | map(select(. as $x | [$bf[]] | index($x))) | length) as $i_count
    | ($i_count / $u) as $jacc
    | select($jacc >= $threshold and $jacc < 1.0 and ($af | length) >= 3 and ($bf | length) >= 3)
    | { cluster_id: cluster_id_sorted_pair("near-duplicates"; loc_key($a); loc_key($b)),
        query: "near-duplicates",
        shape: "pair",
        jacc: $jacc,
        demoted: ([$a, $b] | is_already_abstracted_cluster($protocols_idx)),
        left: $a, right: $b, left_fields: $af, right_fields: $bf }
  ]
# Sort un-demoted pairs first (highest-Jaccard first), then demoted (also
# highest-Jaccard first within the demoted section).
| sort_by(.demoted, -(.jacc))
| .[]
| if output_format == "jsonl" then
    @json
  else
    "\(if .demoted then "[DEMOTED — already abstracted] " else "" end)[\((.jacc * 100) | floor)%] \(.left.name)@\(.left.file):\(.left.line)  <->  \(.right.name)@\(.right.file):\(.right.line) cid=\(.cluster_id)\n"
    + "    left fields:  \(.left_fields | join(", "))\n"
    + "    right fields: \(.right_fields | join(", "))"
  end
