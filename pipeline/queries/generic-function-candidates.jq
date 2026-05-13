# generic-function-candidates.jq — find function pairs whose bodies differ only by
# a small set of identifier substitutions.
#
# Run:  jq -L pipeline/queries -r --argjson threshold 0.7 --argjson max_subs 2 -f pipeline/queries/generic-function-candidates.jq function-catalog.json
#        (-r for raw multi-line text output)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -r --argjson threshold 0.7 --argjson max_subs 2 -f pipeline/queries/generic-function-candidates.jq function-catalog.json
#
# Surfaces V7 refactor-recommendation Category 5 function-shaped candidates
# (plants 5.1, 5.2, 5R): function pairs where the bodies are byte-near-duplicate
# AND the non-shared lines pair up such that each A-line maps to a B-line by
# substituting a small fixed set of identifier tokens.
#
# Detector:
#
#   1. Function pairs (i, j) with body_lines Jaccard ≥ threshold but < 1.0
#      (same baseline as `function-duplicates.jq` near section).
#   2. Same `body_line_count` (true type substitution preserves line shape).
#   3. `|A_only| == |B_only|` (the unique lines balance).
#   4. Each line in A_only has a "buddy" in B_only whose identifier-token set
#      differs by ≤ max_subs tokens (one swapped identifier per buddy is the
#      `UIColor` ↔ `NSColor` case; ≤2 tolerates additional naming drift).
#   5. The aggregated swap-token set has cardinality ≥ 1 (would-be no-op
#      otherwise) AND ≤ max_subs * 2 (per buddy * sides) — keeps the substitution
#      *small* relative to the body, which is what makes the pair a clean
#      generic-function candidate vs. a forked-then-edited helper.
#
# Identifier tokens are extracted by splitting each body line on non-identifier
# characters `[^A-Za-z0-9_]+` and keeping non-empty parts.
#
# `--argjson threshold 0.7` and `--argjson max_subs 2` are REQUIRED. jq errors
# at compile time on undefined variables.
#
# Output: one row per pair, ordered by Jaccard desc.
#
# cluster_id format:  generic-function-candidates:LocA+LocB
#                     (sorted location keys — package:file:line:name)

include "_canonical";

# Tokenize a line into identifier-shaped tokens.
def tokens_of:
  split("[^A-Za-z0-9_]+"; "") | map(select(length > 0));

# For a line `a` and a list of candidate lines `bs`, find the best buddy in bs
# whose token-set differs by the smallest sym-diff count. Returns null if no
# candidate qualifies under max_subs.
def best_buddy(a; bs; max_subs):
  (a | tokens_of | unique) as $at
  | [ bs[]
      | . as $b
      | ($b | tokens_of | unique) as $bt
      | (($at - $bt) + ($bt - $at) | unique) as $sym
      | { line: $b, swap_a: ($at - $bt), swap_b: ($bt - $at), sym_count: ($sym | length) }
      | select(.sym_count <= max_subs * 2)
    ]
  | sort_by(.sym_count)
  | if length > 0 then .[0] else null end;

. as $all
| ([ $all[] | select((.generated // false) != true and (.body_line_count // 0) >= 3) ]) as $fns
| $threshold as $thr
| [
    range(0; $fns | length) as $i
    | range($i + 1; $fns | length) as $j
    | $fns[$i] as $a | $fns[$j] as $b
    | select($a.body_hash != $b.body_hash)
    | select($a.body_line_count == $b.body_line_count)
    | ($a.body_lines) as $al
    | ($b.body_lines) as $bl
    | ($al + $bl | unique | length) as $u
    | select($u > 0)
    | ([$al[] | select(. as $x | $bl | index($x) != null)] | length) as $ic
    | ($ic / $u) as $jacc
    | select($jacc >= $thr and $jacc < 1.0)
    | ([$al[] | select(. as $x | $bl | index($x) == null)]) as $a_only
    | ([$bl[] | select(. as $x | $al | index($x) == null)]) as $b_only
    | select(($a_only | length) == ($b_only | length))
    | select(($a_only | length) >= 1)
    # For each A_only line, find its best buddy in B_only.
    | [ $a_only[] | best_buddy(.; $b_only; $max_subs) ] as $buddies
    | select(($buddies | map(select(. != null)) | length) == ($a_only | length))
    # Aggregate swap tokens across all buddies.
    | ($buddies | map(.swap_a) | add | unique) as $swap_a_all
    | ($buddies | map(.swap_b) | add | unique) as $swap_b_all
    | ($swap_a_all + $swap_b_all | unique | length) as $swap_card
    | select($swap_card >= 1 and $swap_card <= $max_subs * 2)
    | { cluster_id: cluster_id_sorted_pair("generic-function-candidates"; loc_key($a); loc_key($b)),
        query: "generic-function-candidates",
        jacc: $jacc,
        intersection: $ic,
        union: $u,
        body_line_count: $a.body_line_count,
        a_only_count: ($a_only | length),
        swap_tokens_a: $swap_a_all,
        swap_tokens_b: $swap_b_all,
        a: $a, b: $b }
  ]
| sort_by(-(.jacc))
| .[]
| if output_format == "jsonl" then
    @json
  else
    "[\((.jacc * 100) | floor)%  ∩=\(.intersection) ∪=\(.union), \(.body_line_count) lines, \(.a_only_count) diff line(s)] \(.a.name) <-> \(.b.name) cid=\(.cluster_id)\n"
    + "    A: \(.a.package):\(.a.file):\(.a.line)\n"
    + "    B: \(.b.package):\(.b.file):\(.b.line)\n"
    + "    A swap-tokens: \(.swap_tokens_a | join(", "))\n"
    + "    B swap-tokens: \(.swap_tokens_b | join(", "))"
  end
