# Refactor-Recommendation Experiment — Plant Manifest (Schema + Canonical Entries)

> Companion to [`refactor-recommendation-experiment-methodology.md`](refactor-recommendation-experiment-methodology.md). This doc is the per-plant manifest schema used by the V7 experiment, with one canonical entry per category plus one restraint twin. The full 40-plant manifest will land at `experiments/v7-refactor-recommendation/plant-manifest.yaml` once Phase A of the [methodology roadmap](refactor-recommendation-experiment-methodology.md#roadmap) starts; the entries here are the per-category schemas an implementer expands from.

## Conventions

- `plant_id` matches the [§5 numbering in the methodology doc](refactor-recommendation-experiment-methodology.md#plant-design).
- `source_type` names the real wxyc-ios-64 declaration the plant derives from (drawn from the isolated-source set per the [V6 procedure](wxyc-ios-64-experiment-plant-manifest.md#isolated-source-set)).
- `expected_substrate_signals` is the set of query names the plant should surface in.
- `primary_answer`, `alternative_answers`, `wrong_answers` follow the [§8 rubric schema](refactor-recommendation-experiment-methodology.md#scoring-rubric).
- `specifics_tolerance` defines what counts as "within tolerance" for the auto-scorer; missing fields are treated as required.

## Plant 1.1 — extract-to-common, canonical

```yaml
plant_id: 1.1
category: extract-to-common
source_type: "AppServices:AppConfig"     # 4 fields
plant_locations:
  - "Shared/Caching/Sources/Caching/_Plant_CacheClientConfig.swift"
  - "Shared/Metadata/Sources/Metadata/_Plant_MetadataFetcherConfig.swift"
  - "Shared/Analytics/Sources/Analytics/_Plant_AnalyticsClientConfig.swift"
expected_substrate_signals:
  - exact-duplicates                     # 3 identical shapes
  - cross-package-shape-near-duplicates-any
primary_answer:
  category: extract-to-common
  specifics:
    target_package: "<any package upstream of all three, e.g., Shared/Core or a new Shared/Config>"
    type_name: "ClientConfig"    # agent may also propose "Config"; accepted via tolerance below
    remove_from:
      - "Shared/Caching/Sources/Caching/_Plant_CacheClientConfig.swift"
      - "Shared/Metadata/Sources/Metadata/_Plant_MetadataFetcherConfig.swift"
      - "Shared/Analytics/Sources/Analytics/_Plant_AnalyticsClientConfig.swift"
  rationale_must_cite: ["CacheClientConfig", "MetadataFetcherConfig", "AnalyticsClientConfig", "same shape"]
specifics_tolerance:
  target_package_must_be_upstream_of_all_consumers: true
alternative_answers:
  - category: extract-to-common
    weight: 0.7
    note: "Naming an existing Shared/* package as target when a new Shared/Config would have been more idiomatic. Defensible if the named package is already a common upstream."
wrong_answers:
  - category: no-action
    note: "Three identical configs across three Shared packages with no test/codegen markers is a clear extract candidate; no-action is a false negative."
  - category: subclass-lift
    note: "Structs don't subclass in Swift; would be a language-level error."
restraint: false
```

## Plant 2.4 — protocol inheritance, sibling-with-missing-parent

```yaml
plant_id: 2.4
category: protocol-inheritance
source_type: "synthesized: Cacheable + Persistable parallel pair"
plant_locations:
  - "Shared/Caching/Sources/Caching/_Plant_Cacheable.swift"
  - "Shared/Caching/Sources/Caching/_Plant_Persistable.swift"
expected_substrate_signals:
  - subset-pairs                         # after protocol-inheritance resolution
  - protocol-inheritance-candidates      # new V7 query
primary_answer:
  category: protocol-inheritance
  specifics:
    parent: "Identifiable"                    # agent may also propose KeyedItem or a new shared name; accepted via tolerance
    children: ["Cacheable", "Persistable"]
    moved_members: ["id", "displayName"]
    reuse_existing_swift_protocol: true       # parent is Swift's Identifiable
  rationale_must_cite: ["Cacheable", "Persistable", "id", "displayName"]
specifics_tolerance:
  parent_must_include_both_shared_members: true
  reusing_swift_Identifiable_allowed: true    # tolerated for scoring; reuse_existing_swift_protocol may be false with a new shared-name parent
alternative_answers:
  - category: extract-to-common
    weight: 0.5
    note: "Extracting the shared two-member surface as a struct misses the protocol-shaped abstraction but isn't actively wrong if the agent rationalizes it as a value type."
wrong_answers:
  - category: no-action
    note: "Two protocols sharing a load-bearing two-member core in the same package is a recognizable missing-parent pattern."
  - category: subclass-lift
    note: "Protocols don't subclass."
restraint: false
```

## Plant 3.1 — default implementation, canonical

```yaml
plant_id: 3.1
category: default-implementation
source_type: "synthesized: Loggable protocol + 3 conformers"
plant_locations:
  - "Shared/Logger/Sources/Logger/_Plant_Loggable.swift"           # protocol decl
  - "Shared/Caching/Sources/Caching/_Plant_CacheLoggable.swift"    # conformer 1
  - "Shared/Metadata/Sources/Metadata/_Plant_MetadataLoggable.swift" # conformer 2
  - "Shared/Analytics/Sources/Analytics/_Plant_AnalyticsLoggable.swift" # conformer 3
expected_substrate_signals:
  - function-duplicates                  # 3 identical method bodies
  - default-impl-candidates              # new V7 query
primary_answer:
  category: default-implementation
  specifics:
    protocol: "Loggable"
    method: "logDebugInfo()"
    target_location: "extension Loggable { ... } in Shared/Logger"
    conformers_simplified:
      - "Shared/Caching/Sources/Caching/_Plant_CacheLoggable.swift"
      - "Shared/Metadata/Sources/Metadata/_Plant_MetadataLoggable.swift"
      - "Shared/Analytics/Sources/Analytics/_Plant_AnalyticsLoggable.swift"
  rationale_must_cite: ["Loggable", "logDebugInfo", "identical"]
specifics_tolerance:
  default_impl_must_be_in_protocols_own_package: true
alternative_answers:
  - category: extract-to-common
    weight: 0.4
    note: "Extracting the function to a free helper misses the protocol-default-impl idiom."
wrong_answers:
  - category: no-action
    note: "Three identical method bodies on three types conforming to the same protocol is the textbook default-impl signal."
  - category: subclass-lift
    note: "The conformers are structs/protocols, not a class hierarchy."
restraint: false
```

## Plant 4.1 — PAT introduction, canonical

The full YAML for this plant is in [§8 of the methodology doc](refactor-recommendation-experiment-methodology.md#scoring-rubric) as the rubric example. Cross-referenced here for completeness.

## Plant 5.1 — generic struct, canonical

```yaml
plant_id: 5.1
category: generic-parameterization
source_type: "synthesized: IntCache + StringCache pair"
plant_locations:
  - "Shared/Caching/Sources/Caching/_Plant_IntCache.swift"
  - "Shared/Caching/Sources/Caching/_Plant_StringCache.swift"
expected_substrate_signals:
  - near-duplicates-any                  # shapes differ at Key type only
  - generic-struct-candidates            # new V7 query
primary_answer:
  category: generic-parameterization
  specifics:
    generic_kind: "struct"
    type_params:
      - name: "Key"
        constraint: "Hashable"
    new_name: "Cache"
    replaces: ["IntCache", "StringCache"]
  rationale_must_cite: ["IntCache", "StringCache", "Int", "String", "differ at Key"]
specifics_tolerance:
  type_param_must_be_constrained_to_Hashable: true
  unconstrained_T_acceptable_with_note: false
alternative_answers:
  - category: extract-to-common
    weight: 0.4
    note: "Extracting CacheEntry alone leaves the outer Cache types parallel; partial credit only."
wrong_answers:
  - category: no-action
    note: "Two caches differing only at the key type are a clear generic-struct opportunity."
  - category: pat-introduction
    note: "PAT is for protocols; these are structs. Wrong language-level construct."
restraint: false
```

## Plant 6.1 — subclass lift, canonical

```yaml
plant_id: 6.1
category: subclass-lift
source_type: "synthesized: BaseViewModel + 3 subclass siblings"
plant_locations:
  - "WXYC/iOS/_Plant_IOSViewModel.swift"
  - "WXYC/WatchXYC/_Plant_WatchViewModel.swift"
  - "WXYC/WXYC TV/_Plant_TVViewModel.swift"
  - "Shared/Core/Sources/Core/_Plant_BaseViewModel.swift"  # shared base
expected_substrate_signals:
  - function-duplicates                  # 3 identical handleError(_:) bodies
  - subclass-lift-candidates             # new V7 query
primary_answer:
  category: subclass-lift
  specifics:
    base_class: "BaseViewModel"
    method: "handleError(_:)"
    subclasses: ["IOSViewModel", "WatchViewModel", "TVViewModel"]
    target_location: "BaseViewModel in Shared/Core"
  rationale_must_cite: ["BaseViewModel", "handleError", "identical", "subclass"]
specifics_tolerance:
  target_must_be_nearest_common_ancestor: true
alternative_answers:
  - category: default-implementation
    weight: 0.7
    note: "Lifting to a protocol-default-impl is Swift-idiomatic; for an existing class hierarchy, lift to base is more direct but protocol is defensible."
wrong_answers:
  - category: no-action
    note: "Three identical methods on three subclasses of the same base is the canonical lift signal."
restraint: false
```

## Plant 7.1 — macro synthesis, displayName

```yaml
plant_id: 7.1
category: macro-synthesis
source_type: "synthesized: 18 enums with parallel displayName computed property"
plant_locations:
  - "Shared/Metadata/Sources/Metadata/_Plant_DisplayName_*.swift"   # 18 files
expected_substrate_signals:
  - macro-candidates                     # new V7 query, population-clustered
primary_answer:
  category: macro-synthesis
  specifics:
    macro_name: "@CaseDisplayName"           # agent may also propose @DisplayName; accepted via tolerance
    applies_to: ["enum"]
    synthesizes: "var displayName: String { get } switching over self.cases returning hardcoded labels"
    population_size_evidence: ">= 8 enums"
    use_swift_builtin: false                   # Swift has no built-in case-display-name; macro is the right tool
  rationale_must_cite: ["18", "displayName", "switch", "case"]
specifics_tolerance:
  population_size_in_rationale_must_be_within_2_of_actual: true
alternative_answers:
  - category: default-implementation
    weight: 0.6
    note: "Protocol with default impl backed by CaseIterable + reflection is a defensible alternative — slower than macro, but no macro-build-time cost."
wrong_answers:
  - category: no-action
    note: "18 parallel computed properties is the canonical macro signal."
  - category: extract-to-common
    note: "There's nothing to extract — each enum's cases are unique; the parallel is the *shape* of the property, not its body."
restraint: false
```

## Plant 8.1 — composition, class subset

```yaml
plant_id: 8.1
category: composition
source_type: "synthesized: BasicProfile + FullProfile class pair"
plant_locations:
  - "Shared/Core/Sources/Core/_Plant_BasicProfile.swift"
  - "Shared/Core/Sources/Core/_Plant_FullProfile.swift"
expected_substrate_signals:
  - subset-pairs                         # FullProfile is a superset of BasicProfile
primary_answer:
  category: composition
  specifics:
    composing_type: "FullProfile"
    composed_type: "BasicProfile"
    field_name: "basic | core"
  rationale_must_cite: ["FullProfile", "BasicProfile", "subset", "class"]
specifics_tolerance:
  composition_via_stored_property_required: true
alternative_answers:
  - category: subclass-lift
    weight: 0.5
    note: "FullProfile: BasicProfile via class inheritance is technically valid Swift but couples the two — composition is preferred for value-like models."
  - category: protocol-inheritance
    weight: 0.6
    note: "Extract a BasicProfile-shaped protocol, both classes conform — defensible if callers want polymorphism over the shared surface."
wrong_answers:
  - category: no-action
    note: "Two classes where one's fields are a strict superset of the other's, in the same package, is a clear composition/protocol signal."
restraint: false
```

## Plant 1R — restraint twin, test-vs-production

```yaml
plant_id: 1R
category: extract-to-common   # SHARES Cat. 1's substrate signal; restraint is the correct answer
restraint_pair: 1.1
source_type: "Mirrors Plant 1.1's planted ClientConfig shape"
plant_locations:
  - "Shared/Caching/Sources/Caching/_Plant_CacheClientConfig.swift"        # already from 1.1
  - "Shared/Caching/Tests/CachingTests/_Plant_CacheClientConfigMock.swift" # test-only mirror
expected_substrate_signals:
  - exact-duplicates                     # surfaces in same cluster as 1.1
expected_context_flags:
  - "_Plant_CacheClientConfigMock.swift: is_test=true"
primary_answer:
  category: no-action
  specifics:
    reason_class: "test-fixture"
  rationale_must_cite: ["test", "Tests/", "mock", "is_test"]
specifics_tolerance:
  reason_class_must_be_test_fixture: true
wrong_answers:
  - category: extract-to-common
    note: "Lifting the mock into shared production code breaks test isolation; this is the canonical restraint failure mode."
  - category: protocol-inheritance
    note: "Any *action* recommendation here is a false positive — the duplication is intentional."
restraint: true
```

The remaining 31 plants follow the same shape, parameterized by category and source type. The full manifest will land in Phase A per the [methodology roadmap](refactor-recommendation-experiment-methodology.md#roadmap).

## See also

- [`refactor-recommendation-experiment-methodology.md`](refactor-recommendation-experiment-methodology.md) — methodology spec this manifest serves.
- [`refactor-recommendation-experiment-agent-prompt.md`](refactor-recommendation-experiment-agent-prompt.md) — full agent prompt and per-category specifics schemas the recommendations follow.
- [`dj-site-divergence-experiment-v3-plant-manifest.md`](dj-site-divergence-experiment-v3-plant-manifest.md) — V3 manifest precedent.
- [`wxyc-ios-64-experiment-plant-manifest.md`](wxyc-ios-64-experiment-plant-manifest.md) — V6 manifest, latest substrate-fidelity precedent.
