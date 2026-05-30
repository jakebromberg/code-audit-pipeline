# public-api-leaks.jq -- surface exported functions whose param or return
# types reference a non-exported same-package declaration. The classic refactor
# smell where a routine rename privatizes a type but a consumer-facing
# signature still names it -- a silent ABI break for downstream importers.
#
# Run:  jq -L pipeline/queries -r --slurpfile types type-catalog.json \
#         -f pipeline/queries/public-api-leaks.jq function-catalog.json
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -r \
#         --slurpfile types type-catalog.json \
#         -f pipeline/queries/public-api-leaks.jq function-catalog.json
#
# `--slurpfile types <path>` is REQUIRED. The type catalog is consumed for
# resolution only -- the query's primary input is the function catalog.
#
# Resolution semantics: same-package match only. If `main` has an exported
# function whose param type_ref doesn't appear in `main`'s type catalog, the
# ref unresolves silently (could be an npm import, a TS built-in, a DOM type,
# or just an out-of-catalog name). Cross-package leaks (`main` function
# referencing `shared` un-exported type) are NOT v1 -- they require deciding
# which package's exported-ness is the load-bearing constraint.
#
# V1 query skips `kind == "method"` rows. Methods inherit export status from
# the enclosing class, and the v1 substrate doesn't yet model class-kind, so
# method-leak semantics are undefined. Re-enables when class-kind work lands.
#
# Known v1 false-positive class -- types kept alive only through barrel
# re-exports (`export { Foo } from './x'`). The extractor's reference walker
# doesn't emit a synthetic edge for re-exports, so a type re-exported from a
# barrel but `exported: false` on its original declaration site looks
# privatized to this query. Same FP class as dead-code.jq (#132).
#
# Output: per-function row with one or more `leaks` entries. Sorted by
# (.package, .file, .line, .name) for stable diffs.
#
# cluster_id format:  public-api-leaks:<package>:<file>:<line>:<name>
#
# Envelope: shape: "cluster", members of length 1. Per-function findings wrap
# into the cluster envelope so the renderer stays shape-aware; the per-row
# `leaks` array lives alongside members[].
#
#! query: public-api-leaks
#! shape: cluster
#! catalog: function-catalog, type-catalog
#! formats: text, jsonl
#! desc: Exported functions whose param/return types reference a non-exported same-package type.

include "_canonical";

# Build same-package type index from the slurped type-catalog. Keys are
# JSON-encoded [package, name] 2-tuples (matches the encoding dead-code uses
# in #132). Values are arrays of matching decls (handles name-collisions
# within a package -- two `Foo`s in the same pkg both contribute).
( reduce ($types[0] | entries[]) as $t ({};
    .[([$t.package, $t.name] | tojson)] += [$t])
) as $type_idx
| [ entries[]
    | select((.synthetic // false) != true)
    | select(.exported == true)
    | select((.generated // false) != true)
    | select((.kind // "") != "method")
    | . as $fn
    | ([
        ((.params // []) | map(select(.type_ref != null) | {kind: "param", param_name: .name, ref: .type_ref})),
        (if .return_ref != null then [{kind: "return", param_name: null, ref: .return_ref}] else [] end)
      ] | flatten
      | map(. + {decls: ($type_idx[([$fn.package, .ref] | tojson)] // [])})
      | map(. + {leaking_decls: (.decls | map(select(.exported == false and (.generated // false) != true)))})
      | map(select((.leaking_decls | length) > 0))
      | map({
          kind: .kind,
          param_name: .param_name,
          ref_name: .ref,
          decl_package: .leaking_decls[0].package,
          decl_file:    .leaking_decls[0].file,
          decl_line:    .leaking_decls[0].line
        })
      ) as $leaks
    | select(($leaks | length) > 0)
    | {
        cluster_id: cluster_id_single_name("public-api-leaks"; loc_key(.)),
        query: "public-api-leaks",
        shape: "cluster",
        members: [{
          name: .name,
          package: .package,
          file: .file,
          line: .line,
          touched_in_window: (.touched_in_window // false)
        }],
        leaks: $leaks
      }
  ]
| sort_by(.members[0].package, .members[0].file, .members[0].line, .members[0].name)
| .[]
| if output_format == "jsonl" then
    @json
  else
    (.members[0]) as $m
    | "LEAK \($m.name) (\($m.package):\($m.file):\($m.line)) -- exported"
    + (.leaks | map(
        "\n  \(if .kind == "return" then "return" else "param `\(.param_name)`" end): \(.ref_name)"
        + " -- declared at \(.decl_package):\(.decl_file):\(.decl_line) (not exported)"
      ) | join(""))
    + "\n  cid=\(.cluster_id)"
  end
