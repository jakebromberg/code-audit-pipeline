# field-copy-mapper-candidates.jq — surface hand-written field-by-field mappers
# between two catalogued types. The refactor smell where two structurally-similar
# types are kept in sync by a hand-maintained mapper (Model(x=src.x, …) or
# dst.x = src.x), which drifts silently when a field is added to one side and the
# mapper is forgotten. The recommendation is the fix the source PR (LML#610)
# chose: a field-agnostic `from_<source>` constructor plus a field-parity test.
#
# Run:  jq -L pipeline/queries -r --slurpfile types type-catalog.json \
#         --argjson min_copied 3 --argjson min_coverage 0.9 \
#         -f pipeline/queries/field-copy-mapper-candidates.jq function-catalog.json
#
# JSONL mode:  OUTPUT_FORMAT=jsonl jq -L pipeline/queries -r \
#         --slurpfile types type-catalog.json \
#         --argjson min_copied 3 --argjson min_coverage 0.9 \
#         -f pipeline/queries/field-copy-mapper-candidates.jq function-catalog.json
#
# `--slurpfile types <path>` is REQUIRED; the type catalog is consumed for
# resolution only — the primary input is the function catalog. `--argjson
# min_copied` / `--argjson min_coverage` are REQUIRED for raw jq (the binary
# supplies the front-matter defaults 3 / 0.9).
#
# The join: each mapper row carries a `field_copy_map` naming its source and dest
# types (single-identifier refs, resolved the SAME way as return_ref /
# params[].type_ref). Resolve both against the type-catalog name index (same-
# package, the public-api-leaks / dead-code convention), keep the pair only when
#   |copied_fields| ≥ $min_copied            (enough of a 1:1 run to be a drift risk)
#   AND dest_coverage ≥ $min_coverage        (the copies cover most of the dest —
#                                             a near-total mirror, not a partial
#                                             projection doing real adapter work)
# Both endpoints must resolve to shape-bearing, non-generated, non-test types.
#
# Demotion (issue #217 convention): a mapper already written field-agnostically
# (`form: "model_validate"` — `Dest.model_validate(src, from_attributes=True)`)
# is the AFTER, not the before. It carries `demoted: true`, bypasses the numeric
# gates (there are no enumerated copies to measure), and sorts to the tail — the
# query self-extinguishes on sites that already adopted the recommended shape.
#
# Known recall gaps (by design):
#   * Multi-statement transform bodies fall below the coverage floor — a mapper
#     that copies 5 fields and computes 3 more is a real adapter, not a drift
#     twin. Correct precision behavior; the residual copy-boilerplate is below
#     this detector's resolution.
#   * The drift EVENT ("someone added a field and forgot the mapper") is a
#     temporal fact this current-tree query cannot see. It surfaces the before-
#     shape (a hand-mapper between two near-mirrors) as the proxy from which the
#     reader installs the parity test that makes future drift fail CI.
#   * Same-package resolution only (public-api-leaks' v1 limitation): a mapper
#     whose source/dest live in a different package than the mapper unresolves.
#
# Shape: pair. left = source type, right = dest type; the mapper is the joining
# evidence, carried in the `mapper` field.
#
# cluster_id format:  field-copy-mapper-candidates:LocSrc__LocDst  (directed;
#                     source then dest, '__' separator; location keys —
#                     package:file:line:name)
#
#! query: field-copy-mapper-candidates
#! shape: pair
#! catalog: function-catalog, type-catalog
#! arg: min_copied number 3
#! arg: min_coverage number 0.9
#! formats: text, jsonl
#! desc: Hand-written field-by-field mappers between two catalogued types — from_X constructor + parity-test candidates.

include "_canonical";

# Field-NAME set for a decl — "name:Type" → name, trailing '?' dropped. Same
# convention as subset-pairs / shared-interface-candidates.
def field_names: (.fields // []) | map(split(":") | .[0]) | map(sub("\\?$"; "")) | unique;

# Resolve a single-identifier type-ref against the same-package name index to the
# first shape-bearing, non-generated, non-test declaration (or null).
def resolve_type($idx; $pkg; $name):
  ($idx[([$pkg, $name] | tojson)] // [])
  | map(select((.generated // false) != true
               and (.is_test // false) != true
               and .fields != null))
  | .[0];

# Build the same-package type index (JSON-encoded [package, name] → [decls]),
# the encoding public-api-leaks / dead-code share.
( reduce ($types[0] | entries[]) as $t ({};
    .[([$t.package, $t.name] | tojson)] += [$t])
) as $type_idx
| [ entries[]
    | select(.field_copy_map != null)
    | . as $fn
    | .field_copy_map as $fcm
    | resolve_type($type_idx; $fn.package; $fcm.source_type_ref) as $src
    | resolve_type($type_idx; $fn.package; $fcm.dest_type_ref) as $dst
    | select($src != null and $dst != null)
    | ($fcm.copied_fields // []) as $copied
    | ($src | field_names) as $src_names
    | ($dst | field_names) as $dst_names
    | ($dst_names | length) as $dst_n
    | ([$copied[] | select(. as $c | $dst_names | index($c) != null)] | length) as $covered
    | (if $dst_n > 0 then ($covered / $dst_n) else 0 end) as $coverage
    | ($fcm.form == "model_validate") as $is_mv
    # model_validate is the already-fixed form: emit demoted, skip the numeric
    # gates (nothing enumerated to measure). Everything else must clear both.
    | select($is_mv or (($copied | length) >= $min_copied and $coverage >= $min_coverage))
    # Residue: fields the source keeps that the projection intentionally drops
    # (e.g. the DB primary key `id`). This is what the parity test excepts.
    | ([$src_names[] | select(. as $s | $copied | index($s) == null)] | sort) as $residue
    | {
        cluster_id: cluster_id_directed_pair("field-copy-mapper-candidates"; loc_key($src); loc_key($dst)),
        query: "field-copy-mapper-candidates",
        shape: "pair",
        demoted: $is_mv,
        form: $fcm.form,
        copied_fields: ($copied | sort),
        dest_coverage: $coverage,
        residue: $residue,
        mapper: {
          name: $fn.name,
          package: $fn.package,
          file: $fn.file,
          line: $fn.line,
          touched_in_window: ($fn.touched_in_window // false)
        },
        recommendation: ("replace the hand-mapper with a `from_\($src.name)` constructor over "
          + "`model_validate(..., from_attributes=True)` (Pydantic) or an equivalent field-agnostic "
          + "projection, and add a field-parity test asserting the two field sets stay aligned "
          + "(modulo the residue: \(if ($residue | length) == 0 then "none" else ($residue | join(", ")) end))"),
        left: $src,
        right: $dst
      }
  ]
# Dedupe on the directed source→dest pair so a type pair with more than one live
# mapper emits once (keeps cluster_id unique — the pair is the finding).
| group_by(.cluster_id)
| map(.[0])
# Un-demoted first (false sorts before true), then by source/dest name.
| sort_by(.demoted, .left.name, .right.name)
| .[]
| if output_format == "jsonl" then
    @json
  else
    "\(if .demoted then "[DEMOTED — already field-agnostic] " else "" end)"
    + "[\(.copied_fields | length) copied, cov \((.dest_coverage * 100) | floor)%] "
    + "\(.left.name) → \(.right.name) cid=\(.cluster_id)\n"
    + "    mapper:  \(.mapper.name) (\(.form)) — \(.mapper.package):\(.mapper.file):\(.mapper.line)\n"
    + "    source:  \(.left.kind) — \(.left.package):\(.left.file):\(.left.line)\n"
    + "    dest:    \(.right.kind) — \(.right.package):\(.right.file):\(.right.line)\n"
    + "    copied:  \(.copied_fields | join(", "))\n"
    + "    residue: \(if (.residue | length) == 0 then "(none)" else (.residue | join(", ")) end)\n"
    + "    fix:     \(.recommendation)"
  end
