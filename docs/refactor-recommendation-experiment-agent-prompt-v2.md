# Refactor-Recommendation Experiment — Agent Prompt + Specifics Schemas (v2)

> Sibling to [`refactor-recommendation-experiment-agent-prompt.md`](refactor-recommendation-experiment-agent-prompt.md) (the v1 prompt). This v2 prompt is the experimental arm of the round-2 prompt-sensitivity sub-experiment ([#77](https://github.com/jakebromberg/code-audit-pipeline/issues/77) trigger #2 — `primary_match_specifics_outside_tolerance` dominates round-2's panel route). See [`plans/v7-round2-prompt-sensitivity-plan.md`](../plans/v7-round2-prompt-sensitivity-plan.md) for the design and pre-registration.
>
> v2 differs from v1 in two pre-registered ways: (a) §2's per-category specifics schemas carry tightened structural constraints (e.g., "the `protocol` field MUST name a type that exists in the cluster's source files"); (b) §2.1 adds one synthetic non-corpus worked example per of the five action categories (`extract-to-common`, `protocol-inheritance`, `default-implementation`, `pat-introduction`, `generic-parameterization`). §1 is byte-identical to v1. All other §2 schemas (`subclass-lift`, `macro-synthesis`, `composition`, `extension-consolidation`, `no-action`, `other`) are unchanged.
>
> Methodological constraint: v2's worked examples are checked against [`plant-manifest.yaml`](../experiments/v7-refactor-recommendation/plant-manifest.yaml) for substring-level identifier overlap by [`scripts/check_example_overlap.py`](../scripts/check_example_overlap.py) before commit. Any match must be resolved before v2 is admitted as the experimental arm — leaking corpus identifiers into the prompt would pollute the H1 vs H0a comparison.

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

The five action-category schemas below carry tightened structural constraints relative to v1. The boundary language ("MUST name a type that already exists in the cluster's source files", "MUST be upstream of all consumer packages", etc.) encodes structural expectations from the manifest's tolerance schema without exposing the manifest values themselves: the agent is told *where the answer must be grounded*, not *what the answer is*. Categories `subclass-lift`, `macro-synthesis`, `composition`, `extension-consolidation`, `no-action`, and `other` are byte-identical to v1.

```json
{
  "extract-to-common": {
    "target_package": "string (MUST name a package that already exists in the source tree, named by one of the cluster's participating records — do NOT propose a new package name. The chosen package MUST be upstream of every consumer package whose record participates in the cluster.)",
    "type_name": "string (the name the extracted type should carry; may match an existing duplicate or be a new name)",
    "remove_from": ["array of file paths where the duplicate currently lives; each entry MUST match a `file` field on a participating record"]
  },

  "protocol-inheritance": {
    "parent": "string (parent protocol name; MUST name a protocol that already exists in the cluster's source files OR a Swift-standard-library protocol — do NOT propose a new project-local parent protocol)",
    "children": ["array of child protocol names from the cluster; >= 2 entries; each entry MUST match a `name` field on a participating record"],
    "moved_members": ["array of member names that move from each child to parent; each entry MUST appear in the `fields_or_signature` list of every named child"],
    "reuse_existing_swift_protocol": "boolean (true if parent is Identifiable, Equatable, Hashable, Codable, etc.)"
  },

  "default-implementation": {
    "protocol": "string (protocol whose extension gets the default impl; MUST name a protocol that already exists in the cluster's source files — do NOT invent a new protocol name)",
    "method": "string (method signature including effect specifiers; MUST appear in the `fields_or_signature` list of every conformer in the cluster)",
    "target_location": "string (file path; MUST be inside the same SPM package as the `protocol` field's declaring package)",
    "conformers_simplified": ["array of file paths where conformer impls should be deleted; each entry MUST match a `file` field on a participating record"]
  },

  "pat-introduction": {
    "new_protocol": "string (name for the new PAT; may be a new name not present in the source)",
    "associated_type": "string (the associatedtype name, e.g., 'Item')",
    "constraints": ["array of protocol constraints on the associatedtype, may be empty"],
    "replaces": ["array of old protocol names this PAT replaces; each entry MUST name a protocol that already exists in the cluster's source files"]
  },

  "generic-parameterization": {
    "generic_kind": "'function' | 'struct' | 'class'",
    "type_params": [
      { "name": "string", "constraint": "string or null" }
    ],
    "new_name": "string (name for the generic type or function; may be a new name)",
    "replaces": ["array of old type/function names this replaces; each entry MUST name a type or function that already exists in the cluster's source files"]
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

## 2.1 Worked examples (synthetic, illustrative)

The following five examples illustrate well-formed recommendations for the five action categories above. The names, packages, and types are entirely synthetic: they do not appear anywhere in the wxyc-ios-64 codebase the agent is reviewing, and are not drawn from the V7 [plant manifest](../experiments/v7-refactor-recommendation/plant-manifest.yaml). They exist to disambiguate the constraint language in the schemas above — not to telegraph answer-key shape. Worked examples follow the same prose-paragraph register as the v1 schema descriptions; treat them as illustrations, not templates to copy.

**extract-to-common worked example.** A hypothetical pair of helper functions `encodePayload(_:)` and `decodePayload(_:)` duplicated across two consumer packages, `Telemetry/EventReporter.swift` and `Reporting/SessionRecorder.swift`. Both packages already depend on a shared foundation package, `BridgeFoundation`. The well-formed `extract-to-common` recommendation names `target_package: "BridgeFoundation"` (existing package, upstream of both consumers), `type_name: "PayloadCodec"` (a new helper name carrying the two functions), and `remove_from` listing both source files. Note: `BridgeFoundation` exists; the recommendation does not propose creating a new package.

**protocol-inheritance worked example.** A hypothetical pair of project-local protocols `ScalarReducer` and `VectorReducer`, both declaring a `combine(_:_:)` method and a `var identity: Element` property. Both extend a project-local `MathReducer` protocol that already exists in the same package. The well-formed `protocol-inheritance` recommendation names `parent: "MathReducer"` (existing protocol — not a newly invented parent), `children: ["ScalarReducer", "VectorReducer"]`, `moved_members: ["combine(_:_:)", "identity"]`, and `reuse_existing_swift_protocol: false` (the parent is project-local, not a Swift standard library protocol).

**default-implementation worked example.** A hypothetical project-local protocol `BridgeTransport` with three conformers `HttpsBridgeTransport`, `LocalBridgeTransport`, and `LoopbackBridgeTransport`, each redeclaring the same body for `func describeRoute() -> String`. The well-formed `default-implementation` recommendation names `protocol: "BridgeTransport"` (existing protocol in the cluster — not a newly invented protocol), `method: "describeRoute() -> String"`, `target_location: "BridgeTransport/BridgeTransport+Defaults.swift"` (the same SPM package as `BridgeTransport`'s declaring file), and `conformers_simplified` listing the three conformer source files.

**pat-introduction worked example.** A hypothetical trio of project-local protocols `BlobVault`, `LedgerVault`, and `RegistryVault`, each declaring its own associated typealias (`BlobToken`, `LedgerToken`, `RegistryToken`) along with parallel methods `persist(_:)` and `restore(_:)`. The well-formed `pat-introduction` recommendation names `new_protocol: "ScopedVault"` (a new name), `associated_type: "Token"`, `constraints: ["Hashable"]`, and `replaces: ["BlobVault", "LedgerVault", "RegistryVault"]` (all three protocols already exist in the cluster's source files).

**generic-parameterization worked example.** A hypothetical trio of free functions `mergeCounters(_:_:)`, `mergeHistograms(_:_:)`, and `mergeTimers(_:_:)` declared in three sibling files in the same metrics package, each implementing the same shape of pairwise merge over a different metric type. The well-formed `generic-parameterization` recommendation names `generic_kind: "function"`, `type_params: [{"name": "M", "constraint": "MergeableMetric"}]` (assuming a project-local `MergeableMetric` protocol already exists), `new_name: "mergeMetrics"`, and `replaces: ["mergeCounters", "mergeHistograms", "mergeTimers"]` (all three already exist in the cluster's source files).

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

- [`refactor-recommendation-experiment-agent-prompt.md`](refactor-recommendation-experiment-agent-prompt.md) — v1 prompt; the round-2 control arm of the prompt-sensitivity sub-experiment.
- [`refactor-recommendation-experiment-methodology.md`](refactor-recommendation-experiment-methodology.md) — methodology spec; §10 covers the rubric-modifications protocol that admits this v2 prompt.
- [`plans/v7-round2-prompt-sensitivity-plan.md`](../plans/v7-round2-prompt-sensitivity-plan.md) — the sub-experiment plan; describes how v1 and v2 are compared.
- [`refactor-recommendation-experiment-plant-manifest.md`](refactor-recommendation-experiment-plant-manifest.md) — per-plant manifest YAML, the ground truth the agent's recommendations are scored against.
- [`scripts/check_example_overlap.py`](../scripts/check_example_overlap.py) — overlap-detection script gating v2 commit.
- Methodology [§8 scoring rubric](refactor-recommendation-experiment-methodology.md#scoring-rubric) — how the recommendation JSON gets auto-scored or routed to panel.
- [`experiments/v7-refactor-recommendation/glossary.md`](../experiments/v7-refactor-recommendation/glossary.md) — shared V7 vocabulary (S1/S2, substrate, plants, metrics, all 13 auto-scorer match labels, binding rules, rounds/phases, code refs, PR/issue index).
