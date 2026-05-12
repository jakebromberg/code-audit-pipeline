# function-duplicates.jq — find duplicate / near-duplicate function bodies.
#
# Run:  jq -L pipeline/queries -r --argjson threshold 0.7 -f pipeline/queries/function-duplicates.jq function-catalog.json
#        (-r for raw text output)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -r --argjson threshold 0.7 -f pipeline/queries/function-duplicates.jq function-catalog.json
#
# Two-section output:
#   [exact body-hash clusters]   functions with byte-identical normalized bodies (clusters)
#   [near-duplicate pairs]       pairwise Jaccard ≥ threshold on body_lines, < 1.0,
#                                excluding pairs already in an exact cluster
#
# Both sections together cover the spectrum: pure exact copies (refactoring opportunities,
# accidental retypes) and near-misses (forked-then-edited helpers, sync/async siblings,
# "Lite" variants stripped of one branch).
#
# `--argjson threshold 0.7` is REQUIRED — jq errors at compile time on an undefined variable.
# Lower the threshold for broader recall, higher to focus only on near-exact.
#
# cluster_id formats:
#   function-duplicates-exact:Loc+Loc+...   (sorted by package:file:line:name)
#   function-duplicates-near:Loc+Loc        (sorted)

include "_canonical";

. as $all
| ([ $all[] | select((.generated // false) != true and (.body_line_count // 0) >= 3) ]) as $fns
| $threshold as $thr

# --- Section 1: exact body-hash clusters ---
| ( $fns
    | group_by(.body_hash)
    | map(select(length > 1))
    | map({
        cluster_id: cluster_id_sorted_names("function-duplicates-exact"; map(fn_location_key(.))),
        query: "function-duplicates-exact",
        body_hash: .[0].body_hash,
        body_line_count: .[0].body_line_count,
        decls: map({name, kind, package, file, line, async, param_count})
      })
    | sort_by(-(.decls | length), -(.body_line_count))
  ) as $exact

# Names already covered by an exact cluster — exclude from near-dup section.
| ( [ $exact[].decls[] | fn_location_key(.) ] | unique) as $exact_ids

# --- Section 2: near-duplicate pairs (Jaccard ≥ threshold on body_lines, < 1.0) ---
| ( [ range(0; $fns | length) as $i
      | range($i + 1; $fns | length) as $j
      | $fns[$i] as $a | $fns[$j] as $b
      | select($a.body_hash != $b.body_hash)
      | select($exact_ids | index(fn_location_key($a)) == null)
      | select($exact_ids | index(fn_location_key($b)) == null)
      | ($a.body_lines) as $al
      | ($b.body_lines) as $bl
      | ($al + $bl | unique | length) as $u
      | select($u > 0)
      | ([$al[] | select(. as $x | $bl | index($x) != null)] | length) as $ic
      | ($ic / $u) as $jacc
      | select($jacc >= $thr and $jacc < 1.0)
      | { cluster_id: cluster_id_sorted_pair("function-duplicates-near"; fn_location_key($a); fn_location_key($b)),
          query: "function-duplicates-near",
          jacc: $jacc, a: $a, b: $b, intersection: $ic, union: $u }
    ]
    | sort_by(-(.jacc))
  ) as $near

# --- Format ---
| if output_format == "jsonl" then
    # JSONL: emit each exact cluster, then each near pair, as one JSON line each.
    (($exact[], $near[]) | @json)
  else
    "=== exact body-hash clusters (\($exact | length)) ===\n"
    + ( $exact
        | map(
            "[\(.body_line_count) lines, \(.decls | length) decls] cid=\(.cluster_id)\n"
            + (.decls
               | map("    \(.name)\(if .async then " (async)" else "" end) [\(.kind), arity=\(.param_count)] — \(.package):\(.file):\(.line)")
               | join("\n"))
          )
        | join("\n\n")
      )
    + "\n\n=== near-duplicate pairs, Jaccard ≥ \($thr) (\($near | length)) ===\n"
    + ( $near
        | map(
            "[\((.jacc * 100) | floor)%  ∩=\(.intersection) ∪=\(.union)] \(.a.name)\(if .a.async then " (async)" else "" end) <-> \(.b.name)\(if .b.async then " (async)" else "" end) cid=\(.cluster_id)\n"
            + "    A: \(.a.package):\(.a.file):\(.a.line)  [\(.a.body_line_count) lines, arity=\(.a.param_count)]\n"
            + "    B: \(.b.package):\(.b.file):\(.b.line)  [\(.b.body_line_count) lines, arity=\(.b.param_count)]"
          )
        | join("\n\n")
      )
  end
