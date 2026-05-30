# dead-code.jq -- surface exported, non-generated declarations with zero
# resolved incoming references. The classic "exported-but-nothing-uses-it"
# cleanup signal. Joins the catalog against the sibling references.json
# artifact emitted by --emit-references-graph.
#
# Run:  jq -L pipeline/queries -r --slurpfile refs references.json \
#         -f pipeline/queries/dead-code.jq catalog.json
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -r \
#         --slurpfile refs references.json \
#         -f pipeline/queries/dead-code.jq catalog.json
#
# `--slurpfile refs <path>` is REQUIRED -- jq errors at compile time on
# `$refs` undefined. The references.json shape is documented in
# docs/pipeline-contract.md under the "Sibling references.json artifact"
# section.
#
# Counting rule: only `resolved: true` edges anchor a declaration. Edges with
# `resolved: false` point to out-of-catalog names (DOM, npm, TS built-ins) and
# don't keep anything alive. The same filter excludes self-references --
# `type Tree = { children: Tree[] }` emits a `Tree -> Tree` edge that the
# recursive-type author didn't intend as an external consumer.
#
# Known v1 false-positive class: types kept alive only through barrel
# re-exports (`export { Foo } from './x'`). The extractor's reference walker
# doesn't currently emit a synthetic edge for re-exports. Carried as a
# follow-up; documented in docs/pipeline-contract.md.
#
# Envelope: shape: "cluster", members of length 1. Per-decl findings wrap
# into the cluster envelope so the renderer stays shape-aware; each row is
# one dead decl in members[0].
#
#! query: dead-code
#! shape: cluster
#! catalog: type-catalog, references-graph
#! formats: text, jsonl
#! desc: Exported, non-generated decls with zero resolved incoming references.

include "_canonical";

# Single-pass build of the incoming-edge count. tojson on a 2-tuple gives an
# unambiguous map key regardless of what glyphs appear in the package/type.
( reduce ($refs[0].edges // [])[] as $e ({};
    if $e.resolved == true
       and ($e.from.package != $e.to.package or $e.from.name != $e.to.name)
    then .[([$e.to.package, $e.to.name] | tojson)] += 1
    else . end)
) as $incoming
| [ entries[]
    | select((.synthetic // false) != true)
    | select(.exported == true)
    | select((.generated // false) != true)
    | select(($incoming[([.package, .name] | tojson)] // 0) == 0)
    | {
        cluster_id: cluster_id_single_name("dead-code"; loc_key(.)),
        query: "dead-code",
        shape: "cluster",
        members: [{
          name: .name,
          kind: .kind,
          package: .package,
          file: .file,
          line: .line,
          touched_in_window: (.touched_in_window // false)
        }]
      }
  ]
| sort_by(.members[0].package, .members[0].file, .members[0].line, .members[0].name)
| .[]
| if output_format == "jsonl" then
    @json
  else
    (.members[0]) as $m
    | "  \(if $m.touched_in_window then "*" else " " end) \($m.name) [\($m.kind)] -- \($m.package):\($m.file):\($m.line) cid=\(.cluster_id)"
  end
