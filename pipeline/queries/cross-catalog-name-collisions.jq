# cross-catalog-name-collisions.jq — find type names that appear in BOTH a
# left-catalog and a right-catalog.
#
# This is the first cross-catalog query in the pipeline. Existing queries
# cluster within a single catalog (one repo, one language). This one joins
# two catalogs and reports type names that appear in both — useful for:
#
#   - cross-language audits: e.g., TS DTOs in wxyc-shared vs Swift types in
#     wxyc-ios-64. If the OpenAPI codegen contract is intact, names that
#     describe the same DTO should appear in both catalogs with matching
#     field-name sets. Divergence is a drift signal that the compiler can't
#     catch.
#   - cross-repo within one language: e.g., Backend-Service vs dj-site, both
#     TypeScript. Names appearing on both sides may be intentional shared
#     vocabulary or accidental fork.
#
# Run:
#   jq -n -L pipeline/queries \
#     --slurpfile left  /tmp/left-catalog.json \
#     --slurpfile right /tmp/right-catalog.json \
#     -rf pipeline/queries/cross-catalog-name-collisions.jq
#
# Labels (used in output, default "left"/"right"):
#   LEFT_LABEL=typescript RIGHT_LABEL=swift jq -n ... -rf ...
#
# JSONL mode:
#   OUTPUT_FORMAT=jsonl LEFT_LABEL=typescript RIGHT_LABEL=swift jq -n ... -rf ...
#
# Verdict categories (sorted DIVERGE → MATCH → UNAVAILABLE in text output):
#
#   FIELD_NAMES_DIVERGE     Both records carry fields, but their field-name
#                           sets differ across catalogs. Strongest drift
#                           signal — a DTO has been edited on one side
#                           without the other.
#   FIELD_NAMES_MATCH       Both records carry fields and the field-name
#                           sets are identical. Field *types* may still
#                           differ — Swift `Int` vs TS `number`, Swift
#                           `String` vs TS `string` — and the query does
#                           not normalize those because no canonical
#                           cross-language type mapping has been earned by
#                           evidence yet (per docs/swift-extractor-design-
#                           notes.md's "do not formalize the schema
#                           extension yet" position).
#   COMPARISON_UNAVAILABLE  At least one record lacks a fields array — for
#                           example, a `type-alias-other` (Swift typealias
#                           to a non-object type) or a TS `type-alias-other`
#                           (utility-type alias). Listed last because no
#                           field comparison is possible.
#
# Filters applied:
#
#   - Restricts to shape-bearing kinds: `interface`, `type-alias-object`,
#     `type-alias-union`. Extensions, infer-model, zod-object, drizzle-table
#     are language- or DSL-specific and unlikely to collide cross-catalog
#     meaningfully.
#   - Includes records with `.generated == true`. Cross-catalog comparison
#     is exactly the case where codegen IS the contract being verified —
#     unlike single-catalog queries, where generated records produce
#     uninteresting in-codebase clusters with themselves.
#   - Group requires >= 2 catalogs represented in the cluster. If both
#     records come from the same catalog, that's a within-catalog name
#     collision (handled by name-collisions.jq) and excluded here.
#
# cluster_id format: cross-catalog-name-collisions:Name
#
# Known limitations:
#
#   - Name comparison is case-sensitive and exact. OpenAPI codegen produces
#     identical PascalCase names across TS and Swift, so this works for the
#     wxyc-shared codegen-mirror case. Manually-defined types whose names
#     differ by casing (e.g., `Artist` vs `artist`) or punctuation will not
#     collide here. Add a case-insensitive variant if evidence demands.
#   - Field-name comparison is case-sensitive and exact. This means
#     idiomatic snake_case (TS) vs camelCase (Swift) field names — e.g.,
#     TS `album_id` vs Swift `albumId` — surface as DIVERGE even when they
#     refer to the same logical field. Inspect the per_catalog_field_names
#     side-by-side to distinguish "rename" from "case-style only" drift.
#     A case-style-normalizing variant of this query can be added once
#     evidence justifies it (see docs/swift-extractor-design-notes.md's
#     "do not formalize the schema extension yet" position).
#   - Two distinct DTOs that happen to share a name (e.g., two `Result`
#     types in different domains) will appear here as a false positive.
#     Inspect the file paths in the output before treating any cluster as
#     authoritative.

include "_canonical";

# Strip "field:type" → "field". null-safe so the verdict branch handles
# missing fields cleanly.
def field_names:
  if . == null then null
  else map(split(":")[0]) end;

# Shape-bearing kinds across the catalog schema (see docs/pipeline-contract.md).
# Excludes extension, type-alias-other, type-alias-infer-model, zod-object,
# drizzle-table — those are language- or DSL-specific.
def is_shape_bearing:
  .kind == "interface" or .kind == "type-alias-object" or .kind == "type-alias-union";

($ENV.LEFT_LABEL // "left") as $L
| ($ENV.RIGHT_LABEL // "right") as $R
|
(
  ($left[0]  | map(. + {catalog: $L}))
  + ($right[0] | map(. + {catalog: $R}))
)
| map(select(is_shape_bearing))
| group_by(.name)
| map(select(([.[].catalog] | unique | length) >= 2))
| map(
    . as $cluster
    | ([.[].catalog] | unique | sort) as $cats
    | (.[0].name) as $name
    # Per-catalog union of field names. A catalog with multiple records of the
    # same name (e.g., a generated index re-export plus a model file) contributes
    # the union of their field-name sets — this catches the codegen case where
    # one record has the fields and another is a thin re-export.
    | (
        [.[] | select(.fields != null)]
        | group_by(.catalog)
        | map({
            catalog: .[0].catalog,
            field_names: ([.[].fields[] | split(":")[0]] | unique | sort)
          })
      ) as $per_catalog_fnames
    | (
        if ($per_catalog_fnames | length) < 2 then "COMPARISON_UNAVAILABLE"
        elif ($per_catalog_fnames | map(.field_names) | unique | length) == 1 then "FIELD_NAMES_MATCH"
        else "FIELD_NAMES_DIVERGE"
        end
      ) as $verdict
    | {
        cluster_id: cluster_id_single_name("cross-catalog-name-collisions"; $name),
        query: "cross-catalog-name-collisions",
        name: $name,
        catalogs: $cats,
        verdict: $verdict,
        per_catalog_field_names: $per_catalog_fnames,
        decls: map({catalog, kind, package, file, line, generated, shape_sig, fields})
      }
  )
| sort_by(
    if .verdict == "FIELD_NAMES_DIVERGE" then 0
    elif .verdict == "FIELD_NAMES_MATCH" then 1
    else 2 end,
    .name
  )
| .[]
| if output_format == "jsonl" then
    @json
  else
    "\(.name) [\(.verdict)] (\(.catalogs | join(" + "))) cid=\(.cluster_id)\n"
    + (.decls
        | map("  [\(.catalog) \(.kind)\(if .generated then " generated" else "" end)] \(.package):\(.file):\(.line)")
        | join("\n"))
    + (if .verdict == "FIELD_NAMES_DIVERGE" then
        "\n  per-catalog field names:\n"
        + (.per_catalog_field_names
            | map("    \(.catalog): \(.field_names | tostring | .[0:200])")
            | join("\n"))
       else "" end)
  end
