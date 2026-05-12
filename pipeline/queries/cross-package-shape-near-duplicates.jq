# cross-package-shape-near-duplicates.jq — find shape-similar types across packages
# whose NAMES differ, so the existing cross-package-shadows query misses them.
#
# Run:  jq -rf cross-package-shape-near-duplicates.jq --argjson threshold 0.7 catalog.json
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

. as $all
| ($threshold // 0.7) as $thr
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
    | { jacc: $jacc, main: $a, shared: $b, af: $af, bf: $bf, intersection: $ic, union: $u,
        shared_only: ([$bf[] | . as $x | select(($af | index($x)) == null)]),
        main_only:   ([$af[] | . as $x | select(($bf | index($x)) == null)]),
        intersection_fields: ([$af[] | . as $x | select(($bf | index($x)) != null)] | sort)
      }
  ]
| sort_by(-(.jacc), .main.name, .shared.name)
| .[]
| "[\((.jacc * 100) | floor)%  ∩=\(.intersection) ∪=\(.union)] main:\(.main.name)  <->  shared:\(.shared.name)\n"
  + "    main:    \(.main.kind) — \(.main.file):\(.main.line)\n"
  + "    shared:  \(.shared.kind)\(if .shared.generated then " (generated)" else "" end) — \(.shared.file):\(.shared.line)\n"
  + "    shared field names: \(.bf | join(", "))\n"
  + "    shared only:        \(.shared_only | join(", "))\n"
  + "    main only:          \(.main_only | join(", "))"
