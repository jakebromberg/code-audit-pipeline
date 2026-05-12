# cross-package-shape-near-duplicates-any.jq — find shape-similar types across
# different packages whose NAMES also differ. Catches the "re-typed contract"
# antipattern when there's no main↔shared hierarchy.
#
# Run:  jq -L pipeline/queries -r --argjson threshold 0.7 -f pipeline/queries/cross-package-shape-near-duplicates-any.jq catalog.json
#        (-r for raw text output)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -r --argjson threshold 0.7 -f pipeline/queries/cross-package-shape-near-duplicates-any.jq catalog.json
#
# Unlike cross-package-shape-near-duplicates.jq (asymmetric main↔shared), this
# query is symmetric and N-package: any pair (A, B) where A.package != B.package,
# A.name != B.name, and field-name Jaccard ≥ threshold.
#
# Pairs with the same name are excluded — those belong to cross-package-shadows-any.
# Exact-shape-match pairs (Jaccard 1.0) ARE included.
#
# `--argjson threshold N` is REQUIRED — jq errors at compile time on an undefined variable.
#
# cluster_id format:  cross-package-shape-near-duplicates-any:NameA+NameB  (sorted)

include "_canonical";

. as $all
| $threshold as $thr
| ([ $all[]
     | select(.fields != null and (.fields | length) >= 3)
     | select(.kind | startswith("type-alias") or . == "interface" or . == "zod-object")
     | select((.generated // false) != true)
   ]) as $candidates
| [ range(0; $candidates | length) as $i
    | range($i + 1; $candidates | length) as $j
    | $candidates[$i] as $a | $candidates[$j] as $b
    | select($a.package != $b.package and $a.name != $b.name)
    | ($a.fields | map(split(":") | .[0]) | map(sub("\\?$"; "")) | unique) as $af
    | ($b.fields | map(split(":") | .[0]) | map(sub("\\?$"; "")) | unique) as $bf
    | ($af + $bf | unique | length) as $u
    | select($u > 0)
    | ([$af[] | select(. as $x | $bf | index($x) != null)] | length) as $ic
    | ($ic / $u) as $jacc
    | select($jacc >= $thr and ($af | length) >= 3 and ($bf | length) >= 3)
    | { cluster_id: cluster_id_sorted_pair("cross-package-shape-near-duplicates-any"; $a.name; $b.name),
        query: "cross-package-shape-near-duplicates-any",
        jacc: $jacc, a: $a, b: $b, af: $af, bf: $bf, intersection: $ic, union: $u,
        a_only: ([$af[] | . as $x | select(($bf | index($x)) == null)]),
        b_only: ([$bf[] | . as $x | select(($af | index($x)) == null)])
      }
  ]
| sort_by(-(.jacc), .a.name, .b.name)
| .[]
| if output_format == "jsonl" then
    @json
  else
    "[\((.jacc * 100) | floor)%  ∩=\(.intersection) ∪=\(.union)] \(.a.package):\(.a.name)  <->  \(.b.package):\(.b.name) cid=\(.cluster_id)\n"
    + "    A: \(.a.kind) — \(.a.file):\(.a.line)\n"
    + "    B: \(.b.kind) — \(.b.file):\(.b.line)\n"
    + "    A fields: \(.af | join(", "))\n"
    + "    A only:   \(.a_only | join(", "))\n"
    + "    B only:   \(.b_only | join(", "))"
  end
