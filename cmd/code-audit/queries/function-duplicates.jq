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
# Performance (issue #337): the near-duplicate pair loop used to be a full
# O(n^2) scan with an O(L^2) per-pair intersection and two O(|exact_ids|)
# linear scans per pair. On WXYC/wxyc-ios-64 (7,200 function rows, 4,891
# after the body_line_count/generated filter) that took 18m27s to complete
# at threshold 0.7 and was still running after ~4 minutes (killed, never
# finished) at threshold 0.9 — see the issue for the full pair-count and
# wall-clock tables. Three changes fix it:
#   1. Set-identity intersection: |A ∩ B| = |A| + |B| − |A ∪ B| for
#      deduplicated sets, computed from each function's body-line set
#      precomputed once (not recomputed per pair).
#   2. The exact-cluster exclusion moves from a per-pair index() scan to a
#      row-level filter (from_entries set + has) applied before the pair
#      loop starts.
#   3. Length-band blocking: candidates are sorted ascending by
#      |unique(body_lines)|, and the inner loop exits as soon as the
#      size-ratio bound (Jaccard <= min(|A|,|B|)/max(|A|,|B|)) falls below
#      $threshold — see the comment ahead of the pair loop for why the band
#      is on |unique(body_lines)|, not body_line_count.
# Measured on a synthetic catalog (wxyc-like body-length distribution:
# median 7 lines, tail to ~900, ~18% planted exact/near duplicates) under
# gojq 0.12.19, the query's embedded engine (ADR-0005):
#   n=5,000, threshold 0.7: 9.4s   (was 1,107s / 18m27s per the issue)
#   n=5,000, threshold 0.9: 3.2s
#   n=7,200, threshold 0.9: 6.4s   (matches the issue's wxyc-ios-64 scenario,
#                                   which never completed before this fix)
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
# Sorted ascending by unique-body-line count (`.n`) — the length-band blocker
# below depends on this order. See the note ahead of the pair loop for why
# `.n` is deliberately |unique(body_lines)|, not `.f.body_line_count`.
| ( [ $fns[]
      | . as $r
      | select($exact_set | has(fn_location_key($r)) | not)
      | { f: $r, u: (($r.body_lines // []) | unique) }
      | . + { n: (.u | length) }
    ]
    | sort_by(.n)
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
#
# Length-band blocking (issue #337 fix 3): Jaccard is bounded by the ratio
# of set sizes, J(A,B) <= min(|A|,|B|) / max(|A|,|B|). Any pair whose ratio
# is below $thr cannot reach the threshold, so it never needs to be
# compared. With $cand sorted ascending by `.n`, the ratio $A.n / $B.n is
# monotonically non-increasing as $j grows for a fixed $i (both $A and every
# candidate at index >= i+1 have $B.n >= $A.n), so once the ratio drops below
# $thr it stays below for every larger $j — one `label`/`break` gives an
# exact early exit with no bucketing scaffold. This is also what protects
# the pathological tail (max body_line_count 822 vs a median of 7 on the
# wxyc-ios-64 reference catalog): a small function's scan breaks out within
# a handful of same-sized candidates instead of walking all the way to a
# huge outlier.
#
# Banding on `.n` (`|unique(body_lines)|`), NOT `.f.body_line_count`, is
# load-bearing. The bound above only holds for *set* cardinalities, and
# `body_line_count` is not always that: the TypeScript extractor emits the
# raw pre-dedup line count in `body_line_count` alongside a deduplicated
# `body_lines`, so `body_line_count > |body_lines|` on a TS catalog.
# Concrete false negative this avoids (from a two-function TS file):
# alpha has body_line_count=9, |body_lines|=6; beta has body_line_count=6,
# |body_lines|=5; true Jaccard = 5/6 = 0.833 (reportable at threshold 0.8),
# but the ratio computed from body_line_count is 6/9 = 0.667 — banding on
# that field would silently drop a true near-duplicate. Swift, Python, and
# Rust all emit the deduplicated count in body_line_count, so this only
# bites TS catalogs, but `.n` is correct for all four uniformly.
| ($cand | length) as $m
| ( [ range(0; $m) as $i
      | $cand[$i] as $A
      | label $band
      | ( range($i + 1; $m) as $j
          | $cand[$j] as $B
          | (if ($A.n >= $thr * $B.n) then . else break $band end)
          | $A.f as $a | $B.f as $b
          | ($A.u) as $au | ($B.u) as $bu
          | ($A.n) as $na | ($B.n) as $nb
          | (($au + $bu) | unique | length) as $u
          | select($u > 0)
          | ($na + $nb - $u) as $ic
          | ($ic / $u) as $jacc
          | select($jacc >= $thr and $jacc < 1.0)
          # Canonical left/right by loc_key (issue #337 determinism fix), not
          # by which side of the pair landed at $i vs $j — banding sorts
          # $cand by size, so "enumeration order" no longer tracks catalog
          # order and would otherwise flip left/right nondeterministically
          # relative to the pre-band query.
          | ( [$a, $b] | sort_by(fn_location_key(.)) ) as $lr
          | { cluster_id: cluster_id_sorted_pair("function-duplicates-near"; fn_location_key($lr[0]); fn_location_key($lr[1])),
              query: "function-duplicates-near",
              shape: "pair",
              jacc: $jacc, left: $lr[0], right: $lr[1], intersection: $ic, union: $u }
        )
    ]
    # Deterministic ordering (issue #337 determinism fix): highest Jaccard
    # first, `cluster_id` as the secondary key so ties resolve the same way
    # regardless of $cand's tie order or engine-specific sort stability
    # (test_gojq_parity.sh runs this query under both jq 1.7.1 and gojq).
    | sort_by(-(.jacc), .cluster_id)
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
