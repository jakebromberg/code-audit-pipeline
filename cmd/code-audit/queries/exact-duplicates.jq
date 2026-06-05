# exact-duplicates.jq — find type clusters with the same shape_sig
#
# Run:  jq -L pipeline/queries -rf pipeline/queries/exact-duplicates.jq catalog.json
#        (-r for raw multi-line text output)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -rf pipeline/queries/exact-duplicates.jq catalog.json
#              (-r required: @json produces a JSON-encoded string; -r emits it raw, one cluster per line)
#
# Output: one cluster per group, ordered by cluster size (largest first).
# An asterisk (*) marks declarations touched during the audit window.
#
# Each row carries a `demoted` boolean (issue #217). When true, the cluster's
# members already share a non-trivial protocol — i.e., the abstraction the
# duplication "should" become already exists. Demoted clusters are still
# emitted (signal not lost) but sorted to the tail in text mode and carry
# `demoted: true` in JSONL mode so downstream consumers can filter.
#
# cluster_id format:  exact-duplicates:NameA+NameB+...  (sorted, '+' separator)
#
#! query: exact-duplicates
#! shape: cluster
#! catalog: type-catalog
#! formats: text, jsonl
#! desc: Cluster types whose shape_sig is identical (byte-equal field+type set).

include "_canonical";

# V2 substrate: filter `generated: true` to suppress OpenAPI-codegen-internal duplication noise
# (codegen output declares every type both in its own file and again in a consolidated `.d.ts`,
# producing 50+ "duplicate" clusters that an agent already understands as codegen, not drift).
# Cross-package-shadows still surfaces main↔shared/generated collisions, which is the real signal.
. as $catalog
| ($catalog | protocols_index) as $protocols_idx
| [ entries[] | select(.shape_sig != null and .shape_sig != "" and (.generated // false) != true) ]
| group_by(.shape_sig)
| map(select(length > 1))
| map(. as $cluster
      | {
          cluster_id: cluster_id_sorted_names("exact-duplicates"; map(.name)),
          query: "exact-duplicates",
          shape: "cluster",
          shape_sig: .[0].shape_sig,
          field_count: (.[0].fields | length),
          demoted: ($cluster | is_already_abstracted_cluster($protocols_idx)),
          members: map({name, kind, package, file, line, touched_in_window})
        })
# Sort un-demoted clusters first (largest-first), then demoted (also largest-first).
| sort_by(.demoted, -(.members | length))
| .[]
| if output_format == "jsonl" then
    @json
  else
    "\(if .demoted then "[DEMOTED — already abstracted] " else "" end)[\(.field_count) fields, \(.members | length) decls] cid=\(.cluster_id)\n"
    + (.members
        | map("  \(if .touched_in_window then "*" else " " end) \(.name) (\(.kind)) — \(.package):\(.file):\(.line)")
        | join("\n"))
  end
