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

include "_canonical";

. as $all
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
        jacc: $jacc, main: $a, shared: $b, af: $af, bf: $bf, intersection: $ic, union: $u,
        shared_only: ([$bf[] | . as $x | select(($af | index($x)) == null)]),
        main_only:   ([$af[] | . as $x | select(($bf | index($x)) == null)])
      }
  ]
| sort_by(-(.jacc), .main.name, .shared.name)
| .[]
| if output_format == "jsonl" then
    @json
  else
    "[\((.jacc * 100) | floor)%  ∩=\(.intersection) ∪=\(.union)] main:\(.main.name)  <->  shared:\(.shared.name) cid=\(.cluster_id)\n"
    + "    main:    \(.main.kind) — \(.main.file):\(.main.line)\n"
    + "    shared:  \(.shared.kind)\(if .shared.generated then " (generated)" else "" end) — \(.shared.file):\(.shared.line)\n"
    + "    shared field names: \(.bf | join(", "))\n"
    + "    shared only:        \(.shared_only | join(", "))\n"
    + "    main only:          \(.main_only | join(", "))"
  end
