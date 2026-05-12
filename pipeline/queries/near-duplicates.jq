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
# cluster_id format:  near-duplicates:LocA+LocB  (sorted location keys
#                                                 — package:file:line:name)

include "_canonical";

[ .[] | select(.package == "main" and .fields and (.fields | length) >= 3) ] as $bs
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
        jacc: $jacc, a: $a, b: $b, af: $af, bf: $bf }
  ]
| sort_by(-(.jacc))
| .[]
| if output_format == "jsonl" then
    @json
  else
    "[\((.jacc * 100) | floor)%] \(.a.name)@\(.a.file):\(.a.line)  <->  \(.b.name)@\(.b.file):\(.b.line) cid=\(.cluster_id)\n"
    + "    A fields: \(.af | join(", "))\n"
    + "    B fields: \(.bf | join(", "))"
  end
