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
#
#! query: function-duplicates
#! shape: cluster, pair
#! catalog: function-catalog
#! arg: threshold number required
#! formats: text, jsonl
#! desc: Function-body duplicates — exact (cluster) and near (pair) sections.

include "_canonical";

entries as $all
| ([ $all[] | select((.generated // false) != true and (.body_line_count // 0) >= 3) ]) as $fns
| $threshold as $thr

# --- Section 1: exact body-hash clusters ---
| ( $fns
    | group_by(.body_hash)
    | map(select(length > 1))
    | map({
        cluster_id: cluster_id_sorted_names("function-duplicates-exact"; map(fn_location_key(.))),
        query: "function-duplicates-exact",
        shape: "cluster",
        body_hash: .[0].body_hash,
        body_line_count: .[0].body_line_count,
        members: map({name, kind, package, file, line, async, param_count})
      })
    | sort_by(-(.members | length), -(.body_line_count))
  ) as $exact

# Names already covered by an exact cluster — exclude from near-dup section.
# Hoisted to a row-level filter (issue #337 fix 2) rather than a per-pair
# `index` scan repeated twice per pair: a from_entries set + `has` turns an
# O(pairs * |exact_ids|) linear scan into an O(1) lookup, AND shrinks the
# candidate list itself before the pair loop even starts (removing rows beats
# making the per-row test cheaper, since pair count is quadratic in n).
#
# jq gotcha (see CLAUDE.md jq-gotchas): `$set | has(fn_location_key(.))`
# evaluates its argument against `$set`, not the outer record — `.` inside
# the `has(...)` argument is scoped to whatever `$set | ...` piped in, not
# to the decl being tested. It doesn't error; it silently passes every row.
# Binding the record to `$r` before entering the `$exact_set | has(...)` pipe
# avoids the trap.
| ( [ $exact[].members[] | fn_location_key(.) ] | map({key: ., value: true}) | from_entries ) as $exact_set
| ( [ $fns[]
      | . as $r
      | select($exact_set | has(fn_location_key($r)) | not)
      | { f: $r, u: (($r.body_lines // []) | unique) }
      | . + { n: (.u | length) }
    ]
  ) as $cand

# --- Section 2: near-duplicate pairs (Jaccard ≥ threshold on body_lines, < 1.0) ---
#
# Set-identity intersection (issue #337 fix 1): for deduplicated sets,
# |A ∩ B| = |A| + |B| − |A ∪ B|. Each function's deduplicated body-line set
# (`.u`/`.n` above) is computed once, outside the pair loop, rather than
# recomputing `unique` on both bodies for every pair. The union — one sort —
# replaces the O(L²) nested `index` scan the old intersection computation
# used. `unique` is applied here even though every extractor's contract
# already promises deduplicated `body_lines` (TS `[...new Set(normLines)]`,
# Python `sorted(set(rendered))`, Rust `sort` + `dedup`, Swift
# `Array(Set(...)).sorted()`) — trusting-but-verifying costs nothing at this
# scale and keeps the set-identity mathematically exact even if an extractor
# drifts from the contract.
#
# `select($a.body_hash != $b.body_hash)` from the original query is deleted
# as dead code: every survivor of the `$exact_set` filter above is, by
# construction, NOT a member of any body_hash group with length > 1 (if it
# were, group_by(.body_hash) would have put it in $exact along with every
# other member of that hash group). So no two rows in $cand can share a
# body_hash — the inequality can never be false here.
| ( [ range(0; $cand | length) as $i
      | range($i + 1; $cand | length) as $j
      | $cand[$i] as $A | $cand[$j] as $B
      | $A.f as $a | $B.f as $b
      | ($A.u) as $au | ($B.u) as $bu
      | ($A.n) as $na | ($B.n) as $nb
      | (($au + $bu) | unique | length) as $u
      | select($u > 0)
      | ($na + $nb - $u) as $ic
      | ($ic / $u) as $jacc
      | select($jacc >= $thr and $jacc < 1.0)
      | { cluster_id: cluster_id_sorted_pair("function-duplicates-near"; fn_location_key($a); fn_location_key($b)),
          query: "function-duplicates-near",
          shape: "pair",
          jacc: $jacc, left: $a, right: $b, intersection: $ic, union: $u }
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
            "[\(.body_line_count) lines, \(.members | length) decls] cid=\(.cluster_id)\n"
            + (.members
               | map("    \(.name)\(if .async then " (async)" else "" end) [\(.kind), arity=\(.param_count)] — \(.package):\(.file):\(.line)")
               | join("\n"))
          )
        | join("\n\n")
      )
    + "\n\n=== near-duplicate pairs, Jaccard ≥ \($thr) (\($near | length)) ===\n"
    + ( $near
        | map(
            "[\((.jacc * 100) | floor)%  ∩=\(.intersection) ∪=\(.union)] \(.left.name)\(if .left.async then " (async)" else "" end) <-> \(.right.name)\(if .right.async then " (async)" else "" end) cid=\(.cluster_id)\n"
            + "    left:  \(.left.package):\(.left.file):\(.left.line)  [\(.left.body_line_count) lines, arity=\(.left.param_count)]\n"
            + "    right: \(.right.package):\(.right.file):\(.right.line)  [\(.right.body_line_count) lines, arity=\(.right.param_count)]"
          )
        | join("\n\n")
      )
  end
