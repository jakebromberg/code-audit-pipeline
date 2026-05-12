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

include "_canonical";

[ .[] | select(.fields != null and (.fields | length) >= 2 and (.generated // false) != true) ] as $bs
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
    | { sub: $a, sup: $b, sub_fields: $af, sup_fields: $bf, overlap: $i_count }
  ]
# Dedupe by the (sub.shape_sig + sup.shape_sig) pair so identical clusters collapse.
| group_by((.sub.shape_sig // .sub.name) + "::" + (.sup.shape_sig // .sup.name))
| map(.[0])
| sort_by([(.sub_fields | length), (.sup_fields | length), .sub.name])
| map(. + {
    cluster_id: cluster_id_directed_pair("subset-pairs"; loc_key(.sub); loc_key(.sup)),
    query: "subset-pairs"
  })
| .[]
| . as $row
| if output_format == "jsonl" then
    @json
  else
    "\($row.sub.name) [\($row.sub_fields | length) fields] ⊂ \($row.sup.name) [\($row.sup_fields | length) fields] cid=\($row.cluster_id)\n"
    + "  sub:  \($row.sub.package)/\($row.sub.file):\($row.sub.line)\n"
    + "  sup:  \($row.sup.package)/\($row.sup.file):\($row.sup.line)\n"
    + "  shared fields: \($row.sub_fields | join(", "))\n"
    + "  sup-only:      \([$row.sup_fields[] | select(. as $x | $row.sub_fields | index($x) == null)] | join(", "))\n"
  end
