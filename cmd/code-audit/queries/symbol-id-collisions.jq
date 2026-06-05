# symbol-id-collisions.jq — audit a catalog for symbol_id formula collisions.
#
# symbol_id is sha1(package + "/" + file + "/" + name + "/" + kind), per
# docs/pipeline-contract.md "Identity and provenance". If two entries share
# the same tuple, they hash to the same symbol_id. This query groups by the
# input tuple itself (jq has no native sha1; tuple-equality is strictly
# stronger than sha1-equality because the formula is deterministic).
#
# When the tuple groups by more than one entry, the catalog has a symbol_id
# collision. In the 595-entry case-study corpus this happens zero times;
# extractor authors run this query against new catalogs as a regression guard.
#
# Run:    jq -L pipeline/queries -rf pipeline/queries/symbol-id-collisions.jq catalog.json
# JSONL:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -rf pipeline/queries/symbol-id-collisions.jq catalog.json
#
# cluster_id format:  symbol-id-collisions:Pkg/File/Name/Kind
#
#! query: symbol-id-collisions
#! shape: cluster
#! catalog: type-catalog
#! formats: text, jsonl
#! desc: Flag entries sharing the symbol_id tuple (package/file/name/kind) — sha1 collision regression guard.

include "_canonical";

[ entries[] | {
    key: "\(.package)/\(.file)/\(.name)/\(.kind)",
    decl: .
  } ]
| group_by(.key)
| map(select(length > 1))
| map({
    cluster_id: ("symbol-id-collisions:" + .[0].key),
    query: "symbol-id-collisions",
    shape: "cluster",
    tuple: .[0].key,
    members: map(.decl | {name, kind, package, file, line, symbol_id})
  })
| sort_by(-(.members | length))
| .[]
| if output_format == "jsonl" then
    @json
  else
    "[\(.members | length) entries collide on tuple] cid=\(.cluster_id)\n"
    + (.members
        | map("    \(.name) (\(.kind)) — \(.package):\(.file):\(.line)")
        | join("\n"))
  end
