# touched-window-debt-summary.jq — PR-time meta-query: one row per cluster
# type, summarizing how many of that type's clusters intersect the audit
# window's touched declarations.
#
# Run:  jq -L pipeline/queries -rf pipeline/queries/touched-window-debt-summary.jq catalog.json
#        (-r for raw multi-line text output)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -rf pipeline/queries/touched-window-debt-summary.jq catalog.json
#              (4 rows, one per cluster type, deterministic order)
#
# Cluster types indexed (the original four; extending to more is a 5-7 line
# append to the cluster_types array below):
#   - exact-duplicates       (source: exact-duplicates.jq)
#   - name-collisions        (source: name-collisions.jq)
#   - cross-package-shadows  (source: cross-package-shadows.jq)
#   - near-duplicates        (source: near-duplicates.jq)
#
# Each grouping rule is re-derived inline so the meta-query reads catalog.json
# directly (no orchestration). When a source query's grouping rule changes,
# the corresponding fragment here must be updated to match.
#
# Optional knobs:
#   THRESHOLD=0.7        near-duplicates Jaccard floor (default 0.7, matches
#                        near-duplicates.jq). Env var (not --argjson) so the
#                        invocation stays flag-free, matching OUTPUT_FORMAT.
#   ONLY_TOUCHED=true    suppress the detail block for cluster types with
#                        zero touched clusters. Header table still shows them.
#
# When no row in the catalog carries `touched_in_window: true`, text mode
# prepends a banner pointing at the extractor's --touched flag. JSONL mode
# just emits four rows with `touched: 0` — no banner.
#
# cluster_id format:  touched-window-debt-summary:<cluster-type>
#   One row per cluster type per invocation. The cluster-type slug matches
#   the source query's cluster_id prefix, so the four meta-rows index neatly
#   alongside the source clusters they summarize.
#
#! shape: metric

include "_canonical";

# All four cluster types are normalized to a {cluster_id, members} shape so
# this predicate works uniformly across them. The inner clusters mirror the
# source queries' cluster envelope (post-PR-1: members[] in place of decls[]).
def cluster_has_touched: any(.members[]; .touched_in_window // false);

def render_cluster:
  "  [\(.members | length) decl(s)] cid=\(.cluster_id)\n"
  + (.members
      | map("    \(if .touched_in_window then "*" else " " end) \(.name) [\(.kind)] — \(.package):\(.file):\(.line)")
      | join("\n"));

($ENV.THRESHOLD     // "0.7" | tonumber) as $thr
| (($ENV.ONLY_TOUCHED // "") == "true")   as $only_touched
| entries as $all

# 1. exact-duplicates — group by shape_sig, ≥2 decls, exclude generated/null.
# Sort by -size to match exact-duplicates.jq's `sort_by(-(.members | length))`
# so the detail-block order tracks the source query.
| ([ $all[] | select(.shape_sig != null and .shape_sig != "" and (.generated // false) != true) ]
   | group_by(.shape_sig)
   | map(select(length > 1))
   | map({
       cluster_id: cluster_id_sorted_names("exact-duplicates"; map(.name)),
       members: map({name, kind, package, file, line, touched_in_window})
     })
   | sort_by(-(.members | length))) as $exact_dupes

# 2. name-collisions — group by name, ≥2 decls, in ≥2 distinct files.
# Sort by (-size, name) to match name-collisions.jq's
# `sort_by(-(.members | length), .name)`.
| ([ $all[] | select((.generated // false) != true) ]
   | group_by(.name)
   | map(select(length > 1))
   | map(select((map(.file) | unique | length) > 1))
   | map({
       cluster_id: cluster_id_single_name("name-collisions"; .[0].name),
       members: map({name, kind, package, file, line, touched_in_window})
     })
   | sort_by(-(.members | length), .members[0].name)) as $name_collisions

# 3. cross-package-shadows — main-package decl whose name exists in shared
# (interface or type-alias-object). Sort by name to match
# cross-package-shadows.jq's `sort_by(.name)`.
| ([ $all[] | select(.package == "shared" and (.kind == "interface" or .kind == "type-alias-object")) ]
   | map(.name) | unique) as $shared_names
| ([ $all[]
     | select(.package == "main")
     | select(.kind | startswith("type-alias") or . == "interface" or . == "zod-object")
     | select(.name as $n | $shared_names | index($n)) ]
   | group_by(.name)
   | map({
       cluster_id: cluster_id_single_name("cross-package-shadows"; .[0].name),
       members: map({name, kind, package, file, line, touched_in_window})
     })
   | sort_by(.members[0].name)) as $cross_shadows

# 4. near-duplicates — main-package pairs with field-name Jaccard ≥ THRESHOLD
# and < 1.0 (exact matches are exact-duplicates' job). Both sides need ≥3
# fields per the source query.
#
# `_fset` is precomputed once per candidate so the O(N²) pair loop doesn't
# re-parse each decl's fields on every pairing.
#
# `jacc` is carried through the intermediate object so the list can be sorted
# by Jaccard descending (matching near-duplicates.jq's `sort_by(-(.jacc))`);
# it is stripped from the final cluster shape so the meta-query's output
# schema stays {cluster_id, members}.
| ([ $all[]
     | select(.package == "main" and .fields and (.fields | length) >= 3)
     | . + { _fset: (.fields | map(split(":") | .[0]) | map(sub("\\?$"; ""))) } ]) as $nd_decls
| ([
    range(0; $nd_decls | length) as $i
    | range($i + 1; $nd_decls | length) as $j
    | $nd_decls[$i] as $a | $nd_decls[$j] as $b
    | ($a._fset) as $af
    | ($b._fset) as $bf
    | ($af + $bf | unique | length) as $u
    | ($af | map(select(. as $x | $bf | index($x))) | length) as $ic
    | ($ic / $u) as $jacc
    | select($jacc >= $thr and $jacc < 1.0)
    | { _jacc: $jacc,
        cluster_id: cluster_id_sorted_pair("near-duplicates"; loc_key($a); loc_key($b)),
        # near-duplicates is a pair-shape source query; the meta-query
        # flattens its left/right endpoints into the cluster-envelope
        # members[] so cluster_has_touched / render_cluster stay uniform
        # across all four cluster types here. The inner cluster_id still
        # uses the near-duplicates prefix so it joins to the source row.
        members: [
          {name: $a.name, kind: $a.kind, package: $a.package, file: $a.file, line: $a.line, touched_in_window: $a.touched_in_window},
          {name: $b.name, kind: $b.kind, package: $b.package, file: $b.file, line: $b.line, touched_in_window: $b.touched_in_window}
        ]
      }
  ]
   | sort_by(-(._jacc))
   | map(del(._jacc))) as $near_dupes

| (any($all[]; .touched_in_window // false) | not) as $no_touched_context

| [
    {cluster_type: "exact-duplicates",      clusters: $exact_dupes},
    {cluster_type: "name-collisions",       clusters: $name_collisions},
    {cluster_type: "cross-package-shadows", clusters: $cross_shadows},
    {cluster_type: "near-duplicates",       clusters: $near_dupes}
  ]
| map(
    (.clusters | map(select(cluster_has_touched))) as $touched_list
    | (.clusters | length) as $n_total
    | ($touched_list | length) as $n_touched
    | {
        cluster_id: cluster_id_single_name("touched-window-debt-summary"; .cluster_type),
        query: "touched-window-debt-summary",
        shape: "metric",
        cluster_type: .cluster_type,
        touched: $n_touched,
        total:   $n_total,
        percent_touched: (if $n_total == 0 then 0 else ($n_touched * 100 / $n_total | floor) end),
        touched_clusters: $touched_list
      })
| if output_format == "jsonl" then
    .[] | @json
  else
    (if $no_touched_context then
       "note: no touched_in_window flags set — run extractor with --touched <pr.json> for PR-time mode\n\n"
     else
       ""
     end) +
    "TOUCHED-WINDOW DEBT SUMMARY (threshold=\($thr))\n\n" +
    (map("\(.cluster_type): \(.touched) touched / \(.total) total (\(.percent_touched)%) cid=\(.cluster_id)")
      | join("\n")) +
    "\n\n" +
    (map(select((.touched > 0) or ($only_touched != true)))
      | map(
          "\(.cluster_type) detail (\(.touched) of \(.total)):\n" +
          (if .touched == 0 then "  (no touched clusters)"
           else (.touched_clusters | map(render_cluster) | join("\n"))
           end)
        )
      | join("\n\n"))
  end
