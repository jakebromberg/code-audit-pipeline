# Refactor-Recommendation Experiment — Agent Prompt + Specifics Schemas

> Companion to [`refactor-recommendation-experiment-methodology.md`](refactor-recommendation-experiment-methodology.md). The methodology doc's [§7](refactor-recommendation-experiment-methodology.md#agent-prompt) abbreviates the prompt body to keep the spec readable; this doc carries the full text. The complete prompt will be committed to `experiments/v7-refactor-recommendation/prompt.md` once Phase A of the [methodology roadmap](refactor-recommendation-experiment-methodology.md#roadmap) starts, and its hash recorded in the [pre-registration](refactor-recommendation-experiment-methodology.md#pre-registration) section.

## 1. Full prompt text

```
You are reviewing the wxyc-ios-64 Swift codebase. A structural-analysis pipeline
has surfaced N clusters of code that share shape, name, or content across the
codebase. Each cluster row carries: a stable cluster_id, the type of structural
signal (exact-duplicates, cross-package-shadows, subset-pairs, near-duplicates,
function-duplicates, file-duplicates, cross-package-shape-near-duplicates,
pat-candidates, default-impl-candidates, subclass-lift-candidates,
generic-function-candidates, generic-struct-candidates, macro-candidates,
protocol-inheritance-candidates), the participating type or function records
(with package, file path, line number, kind, and field/method list), and
context flags (is_test, is_codegen, is_sample_app, is_mock) on each record.

Your task: for each cluster, produce one structured refactor recommendation in
the JSON shape below. Emit exactly one recommendation per cluster row in the
input. Do not group recommendations. Do not skip clusters that look uninteresting
— if no action is warranted, recommend "no-action" explicitly with a reason.

Recommendation schema:

{
  "cluster_id": "<verbatim from the cluster row>",
  "category": "extract-to-common | protocol-inheritance | default-implementation |
               pat-introduction | generic-parameterization | subclass-lift |
               macro-synthesis | composition | extension-consolidation |
               no-action | other",
  "specifics": { /* schema-per-category, see below */ },
  "rationale": "<2-5 sentences citing specific evidence from the cluster row>",
  "evidence_quote": "<literal substring copied from the cluster output>",
  "alternative": null | { "category": "...", "specifics": {...}, "rationale": "..." },
  "confidence": 0.0
}

Decision rules:

1. INTENTIONAL DUPLICATION → "no-action".
   Restraint markers on participating records are load-bearing — they
   dominate action signals. The recommendation must be "no-action" with the
   corresponding reason_class whenever:
   - ANY participating record has is_test=true → reason_class: "test-fixture".
   - ANY participating record has is_mock=true → reason_class: "mock-fixture".
   - ANY participating record has is_sample_app=true, or sits under Examples/
     or SampleApp/ → reason_class: "sample-app-mirror".
   The "any" framing is deliberate: a mixed cluster where one record is a
   production type and another is a test/mock/sample-app file is the canonical
   restraint pattern. Lifting production code into shared code where the
   cluster includes a restraint-marked record couples production to test or
   demonstration semantics; the right answer is no-action. To override this
   default, the rationale must explicitly argue the marked record is
   removable (e.g., a leftover prototype that should be deleted, not a
   deliberate fixture) — not merely acknowledge the marker.
   The remaining reason_classes apply to clusters without restraint markers:
   - All participating records have is_codegen=true → reason_class: "codegen".
   - The records straddle a public-API boundary (e.g., a public struct in a
     framework target and an internal struct in the same package's
     implementation) → reason_class: "api-impl-boundary".
   - The records are intentionally specialized for divergent performance
     reasons (e.g., one is SIMD-optimized, the other is a tree) →
     reason_class: "intentional-specialization".
   - The records share shape but encode unrelated domain concepts whose
     coincidence is structural only → reason_class: "coincidental".
   When in doubt, prefer "no-action" over a low-confidence action.

2. EVIDENCE GROUNDING. The rationale must cite at least one piece of literal
   evidence from the cluster row: a type name, package name, file path, field
   list, or context-flag value. The evidence_quote field must be a verbatim
   substring of the cluster output. Do not invoke knowledge of the codebase
   you weren't given.

3. PRIMARY VS ALTERNATIVE. If two categories are both defensible, pick the
   more idiomatic Swift answer as primary; put the other in alternative with
   its own rationale. Do not list more than one alternative.

4. "OTHER" IS A REAL OPTION. If none of the named categories fit, use
   category: "other" and explain in the rationale why none apply. "Other"
   recommendations will be panel-reviewed — they are not penalized as wrong.

5. SPECIFICS PRECISION. Name files, packages, type names, method names
   precisely. A recommendation that says "extract to a common package" without
   naming which package is incomplete; one that says "extract to Shared/Core
   because all three consumers already depend on it" is grounded.

6. NO HALLUCINATION. If you can't ground a recommendation in the cluster row,
   recommend "no-action" with reason_class: "coincidental" — do not invent
   evidence.

Output: a single JSON array of N recommendations, one per cluster row,
preserving the input cluster_id ordering.
```

## 2. Per-category specifics schemas (unabbreviated)

```json
{
  "extract-to-common": {
    "target_package": "string (must be a real package name from the catalog)",
    "type_name": "string (the name the extracted type should carry; may match an existing duplicate)",
    "remove_from": ["array of file paths where the duplicate currently lives"]
  },

  "protocol-inheritance": {
    "parent": "string (parent protocol name; may be an existing protocol or proposed new name)",
    "children": ["array of child protocol names from the cluster; >= 2 entries"],
    "moved_members": ["array of member names that move from each child to parent"],
    "reuse_existing_swift_protocol": "boolean (true if parent is Identifiable, Equatable, Hashable, Codable, etc.)"
  },

  "default-implementation": {
    "protocol": "string (protocol whose extension gets the default impl)",
    "method": "string (method signature including effect specifiers)",
    "target_location": "string (file path, ideally within the protocol's own package)",
    "conformers_simplified": ["array of file paths where conformer impls should be deleted"]
  },

  "pat-introduction": {
    "new_protocol": "string (name for the new PAT)",
    "associated_type": "string (the associatedtype name, e.g., 'Item')",
    "constraints": ["array of protocol constraints on the associatedtype, may be empty"],
    "replaces": ["array of old protocol names this PAT replaces"]
  },

  "generic-parameterization": {
    "generic_kind": "'function' | 'struct' | 'class'",
    "type_params": [
      { "name": "string", "constraint": "string or null" }
    ],
    "new_name": "string (name for the generic type or function)",
    "replaces": ["array of old type/function names this replaces"]
  },

  "subclass-lift": {
    "base_class": "string (existing or proposed base class)",
    "method": "string (method signature being lifted)",
    "subclasses": ["array of subclass names whose impl is being removed"],
    "target_location": "string (file path where the lifted method lands)"
  },

  "macro-synthesis": {
    "macro_name": "string (proposed macro name, e.g., '@CaseDisplayName')",
    "applies_to": ["array of type kinds: 'enum', 'struct', 'class', 'protocol'"],
    "synthesizes": "string (what members the macro generates, in prose)",
    "population_size_evidence": "string (the row count or size from the cluster row)",
    "use_swift_builtin": "boolean (true if Swift already provides this, e.g., Codable)"
  },

  "composition": {
    "composing_type": "string (the larger type that gets a field)",
    "composed_type": "string (the smaller type that becomes a field)",
    "field_name": "string (proposed field name)"
  },

  "extension-consolidation": {
    "target_type": "string",
    "consolidate_from": ["array of extension declaration locations"]
  },

  "no-action": {
    "reason_class": "'test-fixture' | 'codegen' | 'sample-app-mirror' | 'api-impl-boundary' | 'intentional-specialization' | 'coincidental'"
  },

  "other": {
    "proposed_action": "string (free-form description of the recommended change)",
    "why_no_category_fits": "string (explanation)"
  }
}
```

## 3. Cluster-row input shape (what the agent receives)

For pre-registration, the input shape the agent sees is fixed too. Each cluster row, regardless of which query produced it, is normalized into:

```json
{
  "cluster_id": "string (stable, content-addressed, emitted by the substrate per issue #5)",
  "query": "string (one of the 15 query names)",
  "members": [
    {
      "name": "string",
      "kind": "'struct' | 'class' | 'enum' | 'protocol' | 'function' | 'extension' | 'file'",
      "package": "string",
      "file": "string (relative path)",
      "line": "integer",
      "fields_or_signature": ["array of strings"],
      "context_flags": {
        "is_test": "boolean",
        "is_codegen": "boolean",
        "is_sample_app": "boolean",
        "is_mock": "boolean"
      }
    }
  ],
  "structural_evidence": {
    "jaccard": "float or null",
    "shared_field_count": "integer or null",
    "differing_slots": ["array of slot descriptions or null"],
    "shared_ancestor": "string or null"
  }
}
```

A normalization pass over the 15 raw query outputs produces this shape; the pass is part of Phase B per the [methodology roadmap](refactor-recommendation-experiment-methodology.md#roadmap).

## See also

- [`refactor-recommendation-experiment-methodology.md`](refactor-recommendation-experiment-methodology.md) — methodology spec this prompt serves.
- [`refactor-recommendation-experiment-plant-manifest.md`](refactor-recommendation-experiment-plant-manifest.md) — per-plant manifest YAML, the ground truth the agent's recommendations are scored against.
- Methodology [§8 scoring rubric](refactor-recommendation-experiment-methodology.md#scoring-rubric) — how the recommendation JSON gets auto-scored or routed to panel.
- [`experiments/v7-refactor-recommendation/glossary.md`](../experiments/v7-refactor-recommendation/glossary.md) — shared V7 vocabulary (S1/S2, substrate, plants, metrics, all 13 auto-scorer match labels, binding rules, rounds/phases, code refs, PR/issue index).
