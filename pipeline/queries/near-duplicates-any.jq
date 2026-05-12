# near-duplicates-any.jq — find type pairs with field-name Jaccard ≥ threshold
# across ALL packages (not just one).
#
# Run:  jq -L pipeline/queries -r --argjson threshold 0.7 -f pipeline/queries/near-duplicates-any.jq catalog.json
#        (-r for raw text output)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -r --argjson threshold 0.7 -f pipeline/queries/near-duplicates-any.jq catalog.json
#
# Unlike near-duplicates.jq (which filters to package == "main" for the dj-site /
# main↔shared layout), this query compares every shape-bearing type against every
# other regardless of package. Intended for codebases with N internal packages
# where no single one is the canonical types module.
#
# Threshold is on field NAMES only (ignoring types). 0.7 typically catches
# legitimate "should be unified" pairs; lower for broader recall, higher to
# focus only on near-exact matches.
#
# `--argjson threshold N` is REQUIRED — jq errors at compile time on an undefined variable.
#
# cluster_id format:  near-duplicates-any:LocA+LocB  (sorted location keys
#                                                     — package:file:line:name)

include "_canonical";

[ .[] | select(.fields and (.fields | length) >= 3 and (.generated // false) != true) ] as $bs
| [
    range(0; $bs | length) as $i
    | range($i + 1; $bs | length) as $j
    | $bs[$i] as $a | $bs[$j] as $b
    | ($a.fields | map(split(":") | .[0]) | map(sub("\\?$"; "")) | unique) as $af
    | ($b.fields | map(split(":") | .[0]) | map(sub("\\?$"; "")) | unique) as $bf
    | ($af + $bf | unique | length) as $u
    | select($u > 0)
    | ([$af[] | select(. as $x | $bf | index($x) != null)] | length) as $ic
    | ($ic / $u) as $jacc
    | select($jacc >= $threshold and $jacc < 1.0 and ($af | length) >= 3 and ($bf | length) >= 3)
    | { cluster_id: cluster_id_sorted_pair("near-duplicates-any"; loc_key($a); loc_key($b)),
        query: "near-duplicates-any",
        jacc: $jacc, a: $a, b: $b, af: $af, bf: $bf, intersection: $ic, union: $u }
  ]
| sort_by(-(.jacc))
| .[]
| if output_format == "jsonl" then
    @json
  else
    "[\((.jacc * 100) | floor)%  ∩=\(.intersection) ∪=\(.union)] \(.a.package):\(.a.name)  <->  \(.b.package):\(.b.name) cid=\(.cluster_id)\n"
    + "    A: \(.a.kind) — \(.a.file):\(.a.line)\n"
    + "    B: \(.b.kind) — \(.b.file):\(.b.line)\n"
    + "    A fields: \(.af | join(", "))\n"
    + "    B fields: \(.bf | join(", "))"
  end
