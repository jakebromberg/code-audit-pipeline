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
# Purpose: a reviewer at PR time should not have to run four cluster queries
# and mentally union the asterisks to find which clusters their PR touches.
# This meta-query does the union — for each cluster type, it reports the
# fraction of clusters with at least one touched-in-window member, and lists
# those touched clusters with their source cluster_ids. The four individual
# queries become drill-downs when this meta-query flags a hit.
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
#                        near-duplicates.jq). Surface as env var to keep the
#                        invocation flag-free, matching OUTPUT_FORMAT.
#   ONLY_TOUCHED=true    suppress the detail block for cluster types with
#                        zero touched clusters. Header table still shows them.
#
# When no row in the catalog has `touched_in_window: true` (extractor ran
# without --touched), text mode prepends a banner explaining this; JSONL mode
# emits the same four rows with `touched: 0` (no banner — it's a text-mode
# affordance).
#
# cluster_id format:  touched-window-debt-summary:<cluster-type>
#   One row per cluster type per invocation. The cluster-type slug matches
#   the source query's cluster_id prefix, so the four meta-rows index neatly
#   alongside the source clusters they summarize.

include "_canonical";

# A cluster is touched if any of its decls has touched_in_window: true.
# All four cluster types are normalized to a {cluster_id, decls} shape so
# this predicate works uniformly.
def cluster_has_touched: any(.decls[]; .touched_in_window // false);

# Per-cluster text rendering. Inside a detail block, each touched cluster
# gets its source cluster_id on a header line and one indented line per decl
# with a "*" marker for touched ones (matching the source queries' text mode).
def render_cluster:
  "  [\(.decls | length) decl(s)] cid=\(.cluster_id)\n"
  + (.decls
      | map("    \(if .touched_in_window then "*" else " " end) \(.name) [\(.kind)] — \(.package):\(.file):\(.line)")
      | join("\n"));

($ENV.THRESHOLD     // "0.7" | tonumber) as $thr
| (($ENV.ONLY_TOUCHED // "") == "true")   as $only_touched
| . as $all

# 1. exact-duplicates — group by shape_sig, ≥2 decls, exclude generated/null.
| ([ $all[] | select(.shape_sig != null and .shape_sig != "" and (.generated // false) != true) ]
   | group_by(.shape_sig)
   | map(select(length > 1))
   | map({
       cluster_id: cluster_id_sorted_names("exact-duplicates"; map(.name)),
       decls: map({name, kind, package, file, line, touched_in_window})
     })) as $exact_dupes

# 2. name-collisions — group by name, ≥2 decls, in ≥2 distinct files.
| ([ $all[] | select((.generated // false) != true) ]
   | group_by(.name)
   | map(select(length > 1))
   | map(select((map(.file) | unique | length) > 1))
   | map({
       cluster_id: cluster_id_single_name("name-collisions"; .[0].name),
       decls: map({name, kind, package, file, line, touched_in_window})
     })) as $name_collisions

# 3. cross-package-shadows — main-package decl whose name exists in shared
# (interface or type-alias-object).
| ([ $all[] | select(.package == "shared" and (.kind == "interface" or .kind == "type-alias-object")) ]
   | map(.name) | unique) as $shared_names
| ([ $all[]
     | select(.package == "main")
     | select(.kind | startswith("type-alias") or . == "interface" or . == "zod-object")
     | select(.name as $n | $shared_names | index($n)) ]
   | group_by(.name)
   | map({
       cluster_id: cluster_id_single_name("cross-package-shadows"; .[0].name),
       decls: map({name, kind, package, file, line, touched_in_window})
     })) as $cross_shadows

# 4. near-duplicates — main-package pairs with field-name Jaccard ≥ THRESHOLD
# and < 1.0 (exact matches are exact-duplicates' job). Both sides need ≥3
# fields per the source query.
| ([ $all[] | select(.package == "main" and .fields and (.fields | length) >= 3) ]) as $nd_decls
| ([
    range(0; $nd_decls | length) as $i
    | range($i + 1; $nd_decls | length) as $j
    | $nd_decls[$i] as $a | $nd_decls[$j] as $b
    | ($a.fields | map(split(":") | .[0]) | map(sub("\\?$"; ""))) as $af
    | ($b.fields | map(split(":") | .[0]) | map(sub("\\?$"; ""))) as $bf
    | ($af + $bf | unique | length) as $u
    | ([$af, $bf] | .[0] | map(select(. as $x | [$bf[]] | index($x))) | length) as $ic
    | ($ic / $u) as $jacc
    | select($jacc >= $thr and $jacc < 1.0)
    | { cluster_id: cluster_id_sorted_pair("near-duplicates"; loc_key($a); loc_key($b)),
        decls: [
          {name: $a.name, kind: $a.kind, package: $a.package, file: $a.file, line: $a.line, touched_in_window: $a.touched_in_window},
          {name: $b.name, kind: $b.kind, package: $b.package, file: $b.file, line: $b.line, touched_in_window: $b.touched_in_window}
        ]
      }
  ]) as $near_dupes

# No-context banner predicate: true when not a single row carries the flag.
| (any($all[]; .touched_in_window // false) | not) as $no_touched_context

| [
    {cluster_type: "exact-duplicates",      clusters: $exact_dupes},
    {cluster_type: "name-collisions",       clusters: $name_collisions},
    {cluster_type: "cross-package-shadows", clusters: $cross_shadows},
    {cluster_type: "near-duplicates",       clusters: $near_dupes}
  ]
| map({
    cluster_id: cluster_id_single_name("touched-window-debt-summary"; .cluster_type),
    query: "touched-window-debt-summary",
    cluster_type: .cluster_type,
    touched: (.clusters | map(select(cluster_has_touched)) | length),
    total:   (.clusters | length),
    percent_touched: (if (.clusters | length) == 0 then 0
                      else ((.clusters | map(select(cluster_has_touched)) | length) * 100 / (.clusters | length) | floor)
                      end),
    touched_clusters: (.clusters | map(select(cluster_has_touched)))
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
