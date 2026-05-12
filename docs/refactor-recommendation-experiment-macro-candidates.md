# Refactor-Recommendation Experiment — `macro-candidates.jq` Algorithmic Sketch

> Companion to [`refactor-recommendation-experiment-methodology.md`](refactor-recommendation-experiment-methodology.md). The methodology doc's [§6.7](refactor-recommendation-experiment-methodology.md#enrichment-population-clustering) sketches population clustering in prose; this doc gives the concrete jq pipeline and the (non-jq) preprocessing step. The full implementation lands in Phase B per the [methodology roadmap](refactor-recommendation-experiment-methodology.md#roadmap); the query itself will live at `pipeline/queries/macro-candidates.jq` once committed.

## 1. Two-stage pipeline

Population clustering needs to (a) generate a wildcard-generalized `template_sig` for each record, and (b) group by `template_sig`. (a) is awkward in jq because it involves rewriting each `name:Type` field with type-replacement; for clarity and testability the substrate emits `template_sig` as a *precomputed field* on each type-catalog record during extraction. The jq query then becomes a straightforward `group_by` + filter.

This is the same pattern V5 used for `shape_sig` and `field_set_hash` — precompute structural keys at extraction time, let jq queries cluster on them.

## 2. Extractor-side precomputation (Swift / TypeScript)

Pseudocode (extractor-side, Swift example in [`extractors/swift/Sources/swift-catalog/TypeCatalogVisitor.swift`](../extractors/swift/Sources/swift-catalog/TypeCatalogVisitor.swift)):

```
function computeTemplateSig(record):
  if record.fields is empty: return null
  if record.kind not in {"struct", "class", "enum", "protocol"}: return null

  sorted_fields = sort(record.fields) by name
  type_first_seen = {}  // Type name → wildcard index
  wildcard_counter = 0
  template_parts = []

  for field in sorted_fields:
    name, type = field.name, field.type
    if type not in type_first_seen:
      type_first_seen[type] = wildcard_counter
      wildcard_counter += 1
    wildcard = "_T" + type_first_seen[type]
    template_parts.append(name + ":" + wildcard)

  return join(template_parts, "|")
```

For a record with `fields: ["count:Int", "value:String"]`:
- sorted by name → `["count:Int", "value:String"]`
- `Int` first seen → `_T0`; `String` first seen → `_T1`
- template_sig: `"count:_T0|value:_T1"`

For 18 enum records each carrying `var displayName: String` (and varying case sets), the relevant population signal is on a *property-template* axis rather than on the field set: a parallel `computeMethodTemplateSig(record)` runs over `record.methods[]` and emits `method_template_sig` per record. The same jq query joins on whichever template_sig the cluster targets.

Records that pass the kind and field-population checks get `template_sig` (and `method_template_sig` where applicable) populated; others get `null`.

## 3. Query side (`macro-candidates.jq`)

```jq
# macro-candidates.jq
#
# Cluster records by precomputed template_sig, filter for population size and
# slot fanout. Each output row is a macro candidate: N records sharing a
# template, with at least 2 distinct concrete types filling the wildcard slots.
#
# Run: jq -r -f macro-candidates.jq catalog.json > queries/macro-candidates.txt
#
# Tunables: MIN_POP_SIZE (>= N records), MIN_SLOT_FANOUT (>= K distinct types
# at any wildcard position). Defaults to N=8, K=2 — calibrate per §6.7 of the
# methodology doc.

def min_pop_size: 8;
def min_slot_fanout: 2;

# Walk a template_sig like "count:_T0|value:_T1" and a fields array like
# ["count:Int", "value:String"] to produce per-slot type-sets.
def slot_types_for_record(record):
  record.fields
  | map(split(":") | .[1])      # ["Int", "String"]
  | to_entries                  # [{key: 0, value: "Int"}, {key: 1, value: "String"}]
  | map({slot: .key, type: .value});

[.types[]
 | select(.template_sig != null)
 | {template_sig, name, package, file, line, fields, kind, context_flags}
]
| group_by(.template_sig)
| map(select(length >= min_pop_size))
| map({
    template_sig: .[0].template_sig,
    population_size: length,
    members: map({name, package, file, line, kind, fields, context_flags}),
    slot_fanout: (
      [.[]
       | .fields
       | map(split(":") | .[1])
       | to_entries
       | map({slot: .key, type: .value})
      ]
      | add
      | group_by(.slot)
      | map({slot: .[0].slot, distinct_types: ([.[].type] | unique | length)})
    )
  })
| map(select(
    .slot_fanout
    | map(.distinct_types)
    | max >= min_slot_fanout
  ))
| sort_by(-.population_size)
| .[]
| "macro-candidate: template=\(.template_sig)  population=\(.population_size)  slot_fanout=\(.slot_fanout | map(.distinct_types) | join(","))\n  members: \(.members | map(.package + ":" + .name) | join(", "))\n"
```

Notes:

- The query reads `template_sig` directly from the catalog — extractor-side precomputation per §2 above. If `template_sig` is absent, the record was deemed ineligible (kind / field-count gate) and is skipped.
- `min_pop_size` and `min_slot_fanout` are the two tunables called out in [methodology §6.7](refactor-recommendation-experiment-methodology.md#enrichment-population-clustering). The §6.7 calibration step (run the prototype against unmodified wxyc-ios-64 and adjust until known macro candidates surface without flooding) lives here — change the defaults in this file once calibrated.
- The output is a multi-line raw string (note the `\n` interpolation and the `-r` invocation in the file header), matching the convention of other queries.
- Recall-of-population is the primary metric for this query: when 18 enums carry parallel `displayName` shapes (Plant 7.1, per [the plant manifest](refactor-recommendation-experiment-plant-manifest.md#plant-71--macro-synthesis-displayname)), the query should surface them as a single 18-member cluster, not as 18 pairwise rows. The §6.7 calibration step has to confirm this on real data; the [methodology MVP](refactor-recommendation-experiment-methodology.md#mvp) drops Cat. 7 specifically because the calibration loop is unscoped at this writing.

## 4. Method-template variant

For property/method populations (Plant 7.1's `displayName` shape), a parallel `macro-method-candidates.jq` runs the same algorithm against `method_template_sig` (precomputed similarly at extraction time over `record.methods[]`'s signatures rather than `record.fields`). The two queries can be unified later; keeping them separate during Phase B lets Plant 7.1 (method-template) be scored independently of struct-template macros if either signal is weaker than expected.

## See also

- [`refactor-recommendation-experiment-methodology.md`](refactor-recommendation-experiment-methodology.md) — methodology spec; §6.7 is the prose sketch this doc operationalizes.
- [`refactor-recommendation-experiment-plant-manifest.md`](refactor-recommendation-experiment-plant-manifest.md) — Plant 7.1 (the displayName macro plant) is the canonical recall target for this query.
- [`../pipeline/queries/`](../pipeline/queries) — V6 queries the macro-candidates query lives alongside once Phase B lands.
- [`pipeline-contract.md`](pipeline-contract.md) — substrate schema; `template_sig` and `method_template_sig` are V7 additions documented there when the precomputation lands.
