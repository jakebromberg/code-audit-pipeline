# subset-pairs.jq — find type pairs (A, B) where A's field-NAME set is a strict subset of B's.
#
# Run:  jq -L pipeline/queries -rf pipeline/queries/subset-pairs.jq catalog.json
#        (-r for raw text output)
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -rf pipeline/queries/subset-pairs.jq catalog.json
#
# Signals types that could be modeled as `Pick<B, …>`, `extends`, or as a base from which B
# specializes. Strictness means |A| < |B| AND every field name in A appears in B.
#
# Comparison is on field NAMES only (ignoring types, `?` optionality) — same convention as
# near-duplicates.jq. The output flags possible relationships, not guaranteed ones; types still
# need agentic judgment to decide whether the subset is incidental or an unrealized abstraction.
#
# Excludes 0- and 1-field types (too noisy: every type with one field is "subset" of every other
# type containing that field name).
#
# cluster_id format:  subset-pairs:LocSub__LocSup  (directed; sub then sup,
#                     '__' separator; location keys — package:file:line:name)
#
# Envelope: shape: "pair", direction is encoded as left=sub (smaller),
# right=sup (larger). The cluster_id keeps the sub__sup spelling so existing
# downstream tooling that joins on cluster_id is unaffected; only the row
# field names change.
#
#! shape: pair

include "_canonical";

[ entries[] | select(.fields != null and (.fields | length) >= 2 and (.generated // false) != true) ] as $bs
| [
    range(0; $bs | length) as $i
    | range(0; $bs | length) as $j
    | select($i != $j)
    | $bs[$i] as $a | $bs[$j] as $b
    | ($a.fields | map(split(":") | .[0]) | map(sub("\\?$"; "")) | unique) as $af
    | ($b.fields | map(split(":") | .[0]) | map(sub("\\?$"; "")) | unique) as $bf
    | select(($af | length) < ($bf | length))
    | ([$af[] | select(. as $f | $bf | index($f) != null)] | length) as $i_count
    | select($i_count == ($af | length))
    | { left: $a, right: $b, left_fields: $af, right_fields: $bf, overlap: $i_count }
  ]
# Dedupe by the (left.shape_sig + right.shape_sig) pair so identical clusters collapse.
| group_by((.left.shape_sig // .left.name) + "::" + (.right.shape_sig // .right.name))
| map(.[0])
| sort_by([(.left_fields | length), (.right_fields | length), .left.name])
| map(. + {
    cluster_id: cluster_id_directed_pair("subset-pairs"; loc_key(.left); loc_key(.right)),
    query: "subset-pairs",
    shape: "pair"
  })
| .[]
| . as $row
| if output_format == "jsonl" then
    @json
  else
    "\($row.left.name) [\($row.left_fields | length) fields] ⊂ \($row.right.name) [\($row.right_fields | length) fields] cid=\($row.cluster_id)\n"
    + "  sub:  \($row.left.package)/\($row.left.file):\($row.left.line)\n"
    + "  sup:  \($row.right.package)/\($row.right.file):\($row.right.line)\n"
    + "  shared fields: \($row.left_fields | join(", "))\n"
    + "  sup-only:      \([$row.right_fields[] | select(. as $x | $row.left_fields | index($x) == null)] | join(", "))\n"
  end
