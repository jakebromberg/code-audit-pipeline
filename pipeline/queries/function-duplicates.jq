# function-duplicates.jq — find duplicate / near-duplicate function bodies.
#
# Run:  jq -rf function-duplicates.jq --argjson threshold 0.7 function-catalog.json
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
# Default threshold is 0.7; lower for broader recall, higher to focus only on near-exact.

. as $all
| ([ $all[] | select((.generated // false) != true and (.body_line_count // 0) >= 3) ]) as $fns
| ($threshold // 0.7) as $thr

# --- Section 1: exact body-hash clusters ---
| ( $fns
    | group_by(.body_hash)
    | map(select(length > 1))
    | map({
        body_hash: .[0].body_hash,
        body_line_count: .[0].body_line_count,
        decls: map({name, kind, package, file, line, async, param_count})
      })
    | sort_by(-(.decls | length), -(.body_line_count))
  ) as $exact

# Names already covered by an exact cluster — exclude from near-dup section.
| ( [ $exact[].decls[] | "\(.package):\(.file):\(.line):\(.name)" ] | unique) as $exact_ids

# --- Section 2: near-duplicate pairs (Jaccard ≥ threshold on body_lines, < 1.0) ---
| ( [ range(0; $fns | length) as $i
      | range($i + 1; $fns | length) as $j
      | $fns[$i] as $a | $fns[$j] as $b
      | select($a.body_hash != $b.body_hash)
      | select(
          (("\($a.package):\($a.file):\($a.line):\($a.name)") as $aid
           | $exact_ids | index($aid) == null)
        )
      | select(
          (("\($b.package):\($b.file):\($b.line):\($b.name)") as $bid
           | $exact_ids | index($bid) == null)
        )
      | ($a.body_lines) as $al
      | ($b.body_lines) as $bl
      | ($al + $bl | unique | length) as $u
      | select($u > 0)
      | ([$al[] | select(. as $x | $bl | index($x) != null)] | length) as $ic
      | ($ic / $u) as $jacc
      | select($jacc >= $thr and $jacc < 1.0)
      | { jacc: $jacc, a: $a, b: $b, intersection: $ic, union: $u }
    ]
    | sort_by(-(.jacc))
  ) as $near

# --- Format ---
| (
    "=== exact body-hash clusters (\($exact | length)) ===\n"
    + ( $exact
        | map(
            "[\(.body_line_count) lines, \(.decls | length) decls]\n"
            + (.decls
               | map("    \(.name)\(if .async then " (async)" else "" end) [\(.kind), arity=\(.param_count)] — \(.package):\(.file):\(.line)")
               | join("\n"))
          )
        | join("\n\n")
      )
    + "\n\n=== near-duplicate pairs, Jaccard ≥ \($thr) (\($near | length)) ===\n"
    + ( $near
        | map(
            "[\((.jacc * 100) | floor)%  ∩=\(.intersection) ∪=\(.union)] \(.a.name)\(if .a.async then " (async)" else "" end) <-> \(.b.name)\(if .b.async then " (async)" else "" end)\n"
            + "    A: \(.a.package):\(.a.file):\(.a.line)  [\(.a.body_line_count) lines, arity=\(.a.param_count)]\n"
            + "    B: \(.b.package):\(.b.file):\(.b.line)  [\(.b.body_line_count) lines, arity=\(.b.param_count)]"
          )
        | join("\n\n")
      )
  )
