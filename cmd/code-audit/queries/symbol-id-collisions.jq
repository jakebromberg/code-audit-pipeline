# symbol-id-collisions.jq — audit a catalog for symbol_id formula collisions.
#
# symbol_id is sha1 over (package, file, name, kind) joined by NUL bytes,
# per docs/pipeline-contract.md "Identity and provenance". Two entries that
# share the same 4-tuple hash to the same symbol_id; this query groups by
# the 4-tuple itself (jq has no native sha1; tuple-equality is strictly
# stronger than sha1-equality because the formula is deterministic).
#
# The grouping key uses the same NUL-byte separator as the symbol_id
# formula, NOT slashes — package values legitimately contain `/`, so a
# slash-joined key falsely collides `(package="Shared/Generated", file="X.ts")`
# with `(package="Shared", file="Generated/X.ts")`. The cluster_id display
# string substitutes a printable separator (`||`) for readability.
#
# When the tuple groups by more than one entry, the catalog has a symbol_id
# collision. In the 595-entry case-study corpus this happens zero times;
# extractor authors run this query against new catalogs as a regression guard.
#
# Run:    jq -L pipeline/queries -rf pipeline/queries/symbol-id-collisions.jq catalog.json
# JSONL:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -rf pipeline/queries/symbol-id-collisions.jq catalog.json
#
# cluster_id format:  symbol-id-collisions:Pkg||File||Name||Kind
#
#! query: symbol-id-collisions
#! shape: cluster
#! catalog: type-catalog
#! formats: text, jsonl
#! desc: Flag entries sharing the symbol_id tuple (package, file, name, kind) — sha1 collision regression guard.

include "_canonical";

[ entries[] | {
    # NUL-separated grouping key: same separator as the symbol_id formula.
    # If two entries' 4-tuples are byte-identical, this string is identical.
    key_nul: ([.package, .file, .name, .kind] | join("\u0000")),
    # Human-readable cluster_id suffix; uses `||` so the printed cluster_id
    # remains readable even if package or file contains `/`.
    key_display: ([.package, .file, .name, .kind] | join("||")),
    decl: .
  } ]
| group_by(.key_nul)
| map(select(length > 1))
| map({
    cluster_id: ("symbol-id-collisions:" + .[0].key_display),
    query: "symbol-id-collisions",
    shape: "cluster",
    tuple: .[0].key_display,
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
