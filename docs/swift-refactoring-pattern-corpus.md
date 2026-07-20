# Swift refactoring-pattern corpus

A provenance map from community-documented Swift refactoring patterns to deterministic detector specs. Each entry names the blog posts that established the pattern, the detectable "before" state, the cluster-query sketch that would surface it, and exactly which catalog fields the detector needs — split into what the substrate carries today versus what would require an extractor extension.

The corpus serves both layers of the deliverable ([README, "The deliverable, in two layers"](../README.md#the-deliverable-in-two-layers)):

- **Input layer:** each Tier 1/Tier 2 entry is a spec for a future `pipeline/queries/*.jq` detector. A query PR that implements one should cite its corpus entry in the file header, so the pattern's provenance travels with the code.
- **Output layer:** the "after" side of each source post is grounded-rationale material for the agent recommendation step ([V7 methodology §7](refactor-recommendation-experiment-methodology.md#agent-prompt)). The restraint notes map onto V7's false-positive measurement ([§9](refactor-recommendation-experiment-methodology.md#restraint)).

## Inclusion criteria

An entry earns a place in the corpus only if all three hold:

1. **Detectable before-state.** The pattern's precondition must pass the lit test: it can be found by clustering structured catalog rows. "This code is hard to read" does not qualify; "this type has four optional stored properties" does.
2. **In-lane.** The detector must be cross-cutting — whole-codebase clustering, not per-site rules. Anything SwiftLint could express as an intra-file rule is out of scope per the [non-goals](../CLAUDE.md#non-goals), unless the *aggregate* (the cluster across files) is the signal.
3. **Source quality.** Posts are independent blogs with worked code examples that have been stable for years, preferred over paywalled or listicle-tier sources. Where the definitive treatment is subscription-gated (Point-Free), a free community writeup is listed alongside.

**Link-rot policy:** when a corpus entry graduates to an implemented query, capture an archive.org snapshot of each source post and add the archive URL beside the live one.

## Feasibility tiers

| Tier | Meaning |
|---|---|
| **1** | Implementable now as a jq query over catalogs the Swift extractor already emits. |
| **2** | Needs an extractor extension (new field, additive per the [pipeline contract](pipeline-contract.md)). The required fields are consolidated in [Proposed extractor extensions](#proposed-extractor-extensions) below. |
| **3** | No detector — rationale corpus for the output layer only. |

Substrate facts the tiers rest on (verified against `extractors/swift/Sources/swift-catalog/`): the Swift **type catalog** emits `fields_structured` with `is_optional` / `is_static` and verbatim `type` text (V7 §6.1), plus the `extends` / `conforms_to` heritage split (#217). The Swift **function catalog** is body-level only — `name`, `kind`, `async`, `param_count`, `param_names`, `body_*` — with **no typed params and no return type**. Signature-level parity with the TypeScript/Rust function catalogs is the single biggest unlock in this corpus.

---

## Pattern 1 — Mutually exclusive optionals → enum with associated values

**Tier 1.** The strongest family: canonical sources, a crisp structural precondition, and a natural restraint twin.

| Source | Role |
|---|---|
| [Modelling state in Swift — Swift by Sundell](https://www.swiftbysundell.com/articles/modelling-state-in-swift/) | Canonical treatment. Before: a `Video` type with `downloadTask?`, `file?`, `isPlaying` that can desync. After: one state enum with associated values, single source of truth. |
| [Making illegal states unrepresentable — Ole Begemann](https://oleb.net/blog/2018/03/making-illegal-states-unrepresentable/) | Uses `URLSession`'s `(Data?, URLResponse?, Error?)` completion tuple as the negative example. |
| [Making illegal states unrepresentable — Alex Ozun, Swiftology](https://swiftology.io/articles/making-illegal-states-unrepresentable/) | Most rigorous: algebraic-data-type grounding (product vs sum types), and — critically for restraint — explicit treatment of the serialization boundary where permissive shapes are legitimate. |
| [Using associated enum values to avoid state-specific optionals — Swift by Sundell](https://www.swiftbysundell.com/tips/using-associated-enum-values-to-avoid-state-specific-optionals/) | Short single-pattern version; good agent-prompt citation. |
| [State Driven Development — Conrad Stoll](http://conradstoll.com/blog/state-driven-development) | Design-level companion. |

**Before-signal:** a shape-bearing type where several stored properties are optional because each is only meaningful in one of the type's implicit states, often alongside one or more `Bool` flags that encode which state is live.

**Detector spec** (`optional-field-density.jq`, type catalog, shape `cluster`): over `fields_structured`, compute per-type `optional_count` (members with `is_optional`, excluding `is_static`) and `bool_flag_count` (members whose `type` is `Bool` and whose `name` matches `^(is|has|should|was|did)`). Flag types where `optional_count >= $threshold` (default 3), or `optional_count >= 2 && bool_flag_count >= 1`. Emit the optional members and co-flags so the agent sees the candidate state axes.

**Catalog needs:** `fields_structured.is_optional`, `.type`, `.name`, `.is_static` — all emitted today.

**Restraint:** DTOs mirroring server JSON legitimately carry many optionals — the Swiftology post covers exactly this boundary. Downrank `generated`, `is_test`, and names matching `(DTO|Response|Request|Payload)$`; surface `conforms_to` containing `Codable`/`Decodable` as context rather than suppressing (plenty of domain types are Codable too). This is a ready-made restraint-twin design for a future plant round.

**V7 hook:** not one of the eight plant categories — see [Relationship to the V7 taxonomy](#relationship-to-the-v7-taxonomy).

---

## Pattern 2 — Boolean blindness → two-case enums

**Type-side Tier 1; function-side Tier 2.**

| Source | Role |
|---|---|
| [Using two-cased enums in place of a Boolean — Hacking with Swift](https://www.hackingwithswift.com/articles/172/using-two-cased-enums-in-place-of-a-boolean) | The Swift-specific case: exhaustiveness, call-site readability, room to grow past two states. |
| [Booleans and Enums — thoughtbot](https://thoughtbot.com/blog/booleans-and-enums) | Concise argument for union types over primitives. |
| [What is wrong with boolean parameters? — Understand Legacy Code](https://understandlegacycode.com/blog/what-is-wrong-with-boolean-parameters/) | Language-agnostic flag-argument smell; call-site opacity framing. |

**Before-signal, type side:** a type carrying several `Bool` stored properties with state-flag names — usually a latent state machine (2^n representable states, few legal). This overlaps pattern 1 and the two detectors should share helper code.

**Before-signal, function side:** functions taking bare `Bool` parameters (the flag-argument smell: `book(marcel, false)`).

**Detector spec, type side** (folds into `optional-field-density.jq` or a sibling `bool-flag-density.jq`): types where `bool_flag_count >= 2`. Emit the flag names; the agent judges whether they co-vary.

**Detector spec, function side:** blocked on typed params. `param_names` alone is too weak (a `Bool` param named `animated` is invisible by name). Needs `params[].type_text` on the Swift function catalog — note the TS contract's `type_ref` nulls out primitives, so verbatim type text is the field to add, not `type_ref`.

**Restraint:** independent booleans are fine; the smell is *co-varying* flags, and co-variance is not visible in a static catalog. Keep the output advisory (candidate axes, not directives) and let the agent's rationale carry the co-variance judgment.

---

## Pattern 3 — Stringly-typed identifiers → type-safe IDs / phantom types

**Tier 1** for the cross-type cluster; the killer per-function signal (two same-raw-typed ID params in one signature) is Tier 2.

| Source | Role |
|---|---|
| [Type-safe identifiers in Swift — Swift by Sundell](https://www.swiftbysundell.com/articles/type-safe-identifiers-in-swift/) | The "after" playbook: `Identifier` types with `ExpressibleByStringLiteral` ergonomics. |
| [Strongly typed identifiers in Swift — Tom Lokhorst](https://tom.lokhorst.eu/2017/07/strongly-typed-identifiers-in-swift) | Popularized generic `Identifier<T>` with a phantom parameter; names the swap-the-arguments hazard. |
| [Phantom types in Swift — Swift by Sundell](https://www.swiftbysundell.com/articles/phantom-types-in-swift/) | General phantom-type technique beyond IDs. |
| [Three use cases of phantom types — kean.blog](https://kean.blog/post/phantom-types) | Restriction-as-documentation framing; good restraint language (verbosity cost). |
| [Phantom types in Swift — Swift with Majid](https://swiftwithmajid.com/2021/02/18/phantom-types-in-swift/) | HealthKit unit-safety worked example. |

**Before-signal:** many entity types each declaring an `id`-ish member with a raw type (`String`, `Int`, `UUID`), so IDs of different entities are mutually assignable.

**Detector spec** (`raw-id-fields.jq`, type catalog, shape `cluster`): select `fields_structured` members where `name` is `id` or matches `(Id|ID)$`, and `type` (modulo optional sugar) is in the raw set `{String, Int, Int64, UUID}`. Group by raw type; emit one cluster per raw type listing every (type, member, file). The cluster size *is* the hazard measure — seventeen entities sharing raw-`String` IDs is the finding, which is what makes this in-lane where a per-site lint would not be.

**Catalog needs:** `fields_structured` only — emitted today. **Tier 2 enhancement:** with function-catalog typed params, add the sharpest signal — functions whose signature takes ≥2 parameters of the same raw ID type (the literal swap hazard).

**Restraint:** a codebase with a single entity, or IDs that never cross a function boundary together, gains little; `UUID` already prevents cross-assignment with `String`. The kean.blog post's verbosity-cost discussion is the restraint citation.

---

## Pattern 4 — Completion handlers → async/await (migration tracking)

**Tier 1 as a heuristic; Tier 2 for the robust version.** This is a *migration-progress* detector, structurally akin to [`versioned-type-pairs.jq`](../pipeline/queries/versioned-type-pairs.jq) and [`migration-progress.jq`](../pipeline/queries/migration-progress.jq).

| Source | Role |
|---|---|
| [How to migrate your code to Swift's async/await, Part I — SustainableCode](https://www.sustainablecode.io/blog/how-to-migrate-your-code-to-swifts-asyncawait-part-i) | Methodical per-function migration mechanics (`withCheckedContinuation` bridging). |
| [A strategy for moving to Swift 6 and async/await — Crunchy Bagel](https://crunchybagel.com/a-strategy-for-moving-to-swift-6-and-async-await/) | Codebase-scale sequencing — exactly the migration-progress framing this pipeline models. |

**Before-signal:** (a) functions still taking a completion closure with no async twin; (b) name-pairs where both a completion-based and an `async` variant exist — migration in flight, with stragglers enumerable.

**Detector spec, Tier 1** (`async-twin-pairs.jq`, function catalog, shape `cluster` + `metric`): group rows by `(package, name)` (strip the `ClassName.` qualifier or group within it); pairs with one `async: true` row and one `async: false` row whose `param_names` include a completion-ish name (`completion`, `completionHandler`, `callback`, `handler`) are in-flight migrations. Standalone `async: false` rows with a completion-ish `param_name` are not-yet-started. Emit percent-migrated plus `touched_in_window` stragglers, mirroring `migration-progress.jq`'s envelope.

**Detector spec, Tier 2:** replace the `param_names` heuristic with structure — `params[].is_closure` (or verbatim `type_text` matching `-> Void` closure syntax) plus `is_escaping`. The heuristic's known miss: completion params with unconventional names; known false positive: non-closure params that happen to be named `handler`.

**Restraint:** completion variants intentionally retained for back-compat during a deprecation window, and `@objc` members that *cannot* become async. The Crunchy Bagel post's sequencing discussion is the citation for "in-flight is not a defect."

---

## Pattern 5 — Single-conformance protocols → concrete types or witnesses

**Tier 1.** The de-abstraction direction — inverse of V7's Cat. 2 (protocol inheritance).

| Source | Role |
|---|---|
| [Protocol Witnesses, Part 1 — Point-Free](https://www.pointfree.co/episodes/ep33-protocol-witnesses-part-1) (and eps [34](https://www.pointfree.co/episodes/ep34-protocol-witnesses-part-2), [35](https://www.pointfree.co/episodes/ep35-advanced-protocol-witnesses-part-1)) | Definitive de-protocolization argument; subscription, transcripts available. |
| [Swift protocol witnesses in 6 examples — Phlippie Bosman](https://phlippieb.bearblog.dev/swift-protocol-witnesses/) | Free worked writeup. |
| [Using "protocol" witnesses — June Bash](https://www.junebash.com/posts/protocol-witnesses/) | Free; practical trade-off discussion. |
| [Protocols & Class Hierarchies — objc.io Swift Talk S01E29](https://talk.objc.io/episodes/S01E29-protocols-class-hierarchies) | The inheritance→protocol direction, for contrast. |

**Before-signal:** a protocol with exactly one conforming type in production code — ceremony without polymorphism.

**Detector spec** (`single-conformance-protocols.jq`, type catalog, shape `cluster`): protocols are `kind: "interface"` rows. Invert `conforms_to` edges across the catalog, joining by target `kind` to resolve the [default-both ambiguity](pipeline-contract.md#heritage-split-convention) (identifiers outside the curated sets land in both `extends` and `conforms_to`; a `kind: "interface"` target confirms protocol-conformance). Count conformers per protocol, **split by `is_test`**. Flag protocols with exactly one production conformer. Attribute extension-based conformances (`extension Foo: P`) to `Foo` via the extension row's `extends`.

**Catalog needs:** `kind`, `conforms_to`, `extends`, `is_test` — all emitted today.

**Restraint:** one production conformer **plus one test-file conformer is the intentional testability seam** — the reason many single-conformance protocols exist. The `is_test` split makes this restraint case deterministic, which is rare and worth preserving in the output shape: emit `prod_conformers` and `test_conformers` as separate counts and only flag when `test_conformers == 0` (flag the seam case in a demoted section, like `is_already_abstracted_cluster` does).

---

## Pattern 6 — Recurring anonymous tuples → named structs

**Tier 2.** `shape_sig` clustering applied to anonymous shapes — philosophically the most on-brand entry in the corpus, blocked only on return-type capture.

| Source | Role |
|---|---|
| [Swift: Tuple (a.k.a. Struct Lite™) — Andyy Hope](https://medium.com/swift-programming/swift-tuple-328aecff50e7) | When a tuple stops being a sketch and should become a contract. |
| [Cleaner classes with structs and tuples — AppVenture](https://appventure.me/posts/2019-02-24-anonymous-tuple-structs.html) | Tuple/struct interplay; refactoring mechanics. |
| [What's the difference between a struct and a tuple? — Hacking with Swift](https://www.hackingwithswift.com/quick-start/understanding-swift/whats-the-difference-between-a-struct-and-a-tuple) | Beginner-accessible criterion; agent-prompt citation. |

**Before-signal:** the same tuple shape (element labels + types) appearing as the return type of two or more functions — an unnamed type the codebase keeps re-deriving.

**Detector spec** (`tuple-return-shapes.jq`, function catalog, shape `cluster`): requires `return_type_text` on function rows. Normalize tuple returns into a sorted `label:type` list — a tuple `shape_sig` — and cluster identical signatures across functions. Flag clusters with ≥2 distinct functions (≥3 for unlabeled tuples, which collide more casually).

**Catalog needs:** `return_type_text` (new; part of signature-level parity). Labeled-element parsing can live in the query if the text is verbatim.

**Restraint:** trivial pairs like `(Bool, Int)` recur coincidentally; labels are the intent signal. Weight labeled-tuple clusters far above unlabeled ones.

---

## Pattern 7 — Scattered switches over one enum → protocol polymorphism

**Tier 2.** The classic Fowler smell, made deterministic by a case-name join rather than type resolution.

| Source | Role |
|---|---|
| [Switch Statements — Refactoring Guru](https://refactoring.guru/smells/switch-statements) | The canonical smell statement: scattered switch code, shotgun-surgery on case addition. |
| [Refactoring: Replace Enum with Polymorphism — Jason Larsen](https://medium.com/swift-fox/refactoring-replace-enum-with-polymorphism-c4803baeba07) | Swift framing. Conceptual rather than code-heavy — cite as rationale, not spec. |

**Before-signal:** one enum switched over in many files; adding a case forces edits at every site.

**Detector spec** (`scattered-enum-switches.jq`, function + type catalog): full subject-type resolution is out of reach without sema, but a deterministic approximation exists. Extractor side: for each function, emit `switch_case_sets` — for each `switch` statement, the set of leading-dot case-pattern names (`case .loading`, `case .failed(let e)` → `{loading, failed}`). Query side: join each set against enum rows' case lists (`kind: "type-alias-union"`, cases enumerated in `fields_structured` per the [contract's enum-case convention](pipeline-contract.md#v7-61-fields_structured)); a set that is a subset of exactly one enum's case set (require ≥2 members for discrimination) attributes that switch to that enum. Cluster by enum; flag enums switched in ≥k distinct files (default 3), excluding the enum's own file and extensions of it.

**Catalog needs:** `switch_case_sets` per function row (new). The enum-case side is already emitted.

**Restraint:** exhaustive switching is often the *point* — the compiler-enforced totality is what the enum buys, and the refactor trades it for extensibility (Larsen is explicit about this). Two or three rendering-layer switches over a state enum are healthy pattern-1 output, not a smell. The detector's value concentrates at high site-counts on enums that gain cases frequently — surface `touched_in_window` on the enum row as that signal.

---

## Pattern 8 — Pyramid of doom → guard (recorded, likely rejected)

**Tier 2 mechanically; likely out-of-lane.** Kept in the corpus so the rejection is recorded with reasons, not rediscovered.

| Source | Role |
|---|---|
| [Using guards in Swift to avoid the pyramid of doom — Matteo Manferdini](https://matteomanferdini.com/swift-guard/) | The guard-refactor mechanics. |
| [Tearing down Swift's optional pyramid of doom — Scott Logic](https://blog.scottlogic.com/2014/12/08/swift-optional-pyramids-of-doom.html) | Historical; functional alternatives. |

**Why likely rejected:** nesting depth is an intra-file, per-site property — SwiftLint's `cyclomatic_complexity` / `nesting` rules already own it statefully, which fails inclusion criterion 2. The only in-lane framing is an aggregate hotspot view (package-level deep-nesting density as a refactor-priority signal, in the spirit of [`mark-section-density.jq`](../pipeline/queries/mark-section-density.jq)), and that framing should only be built if a real audit asks for it. Do not implement a per-function depth flag.

---

## Pattern 9 — Near-duplicate unification via generics (output layer only)

**Tier 3.** No detector — the before-state is already surfaced by existing queries; this entry supplies the judgment playbook for what to do with their output.

| Source | Role |
|---|---|
| [Generalizing Swift code — Swift by Sundell](https://swiftbysundell.com/articles/generalizing-swift-code/) | When to unify near-duplicates with generics — and, critically, when duplication is the better engineering call. |

**Attaches to:** [`near-duplicates.jq`](../pipeline/queries/near-duplicates.jq), [`generic-struct-candidates.jq`](../pipeline/queries/generic-struct-candidates.jq), [`generic-function-candidates.jq`](../pipeline/queries/generic-function-candidates.jq), [`pat-candidates.jq`](../pipeline/queries/pat-candidates.jq) — as citation material in the agent prompt for V7 Cat. 5 (generic parameterization) recommendations, and as restraint language ("making things too generic leads to code that's hard to understand and maintain") for the restraint-twin scoring in [V7 §9](refactor-recommendation-experiment-methodology.md#restraint).

---

## Summary matrix

| # | Pattern | Tier | Catalog(s) | Blocking fields | Proposed query | Related existing queries |
|---|---|---|---|---|---|---|
| 1 | Optionals → state enum | 1 | type | — | `optional-field-density.jq` | — |
| 2 | Boolean blindness | 1 (types) / 2 (params) | type, function | `params[].type_text` | `bool-flag-density.jq` | — |
| 3 | Raw IDs → type-safe IDs | 1 | type | (`params[].type_text` for the param-pair upgrade) | `raw-id-fields.jq` | — |
| 4 | Completion → async | 1 (heuristic) / 2 (robust) | function | `params[].type_text`, `is_escaping` | `async-twin-pairs.jq` | `migration-progress.jq`, `versioned-type-pairs.jq` |
| 5 | Single-conformance protocols | 1 | type | — | `single-conformance-protocols.jq` | `protocol-inheritance-candidates.jq` (inverse), `dead-code.jq` |
| 6 | Recurring tuples → structs | 2 | function | `return_type_text` | `tuple-return-shapes.jq` | `shape-sig-frequency.jq` (namesake) |
| 7 | Scattered enum switches | 2 | function + type | `switch_case_sets` | `scattered-enum-switches.jq` | — |
| 8 | Pyramid of doom | rejected | — | — | — | `mark-section-density.jq` (aggregate framing only) |
| 9 | Generalize via generics | 3 | — | — | — | `near-duplicates.jq`, `generic-*-candidates.jq`, `pat-candidates.jq` |

## Proposed extractor extensions

Two additive extensions to the Swift function catalog unlock every Tier 2 detector above; both must go through the [pipeline contract](pipeline-contract.md) first per the schema-first rule.

1. **Signature-level parity** (unlocks 2, 3-upgrade, 4-robust, 6): `params[]` with `name` and verbatim `type_text` (plus `is_closure` / `is_escaping` structural flags — same rationale as `is_optional`: verbatim text for display, structural flags for matching), and `return_type_text`. The TypeScript and Rust function catalogs already carry signature-level fields; this closes a known parity gap rather than inventing schema.
2. **`switch_case_sets`** (unlocks 7): per-function array of leading-dot case-name sets, one per `switch` statement. Cheap to emit from SwiftSyntax; the enum join stays in the query where it belongs.

## Relationship to the V7 taxonomy

V7's eight plant categories are *structure-consolidation* refactors — merging things that rhyme (extract-to-common, protocol inheritance, default impl, PAT, generic parameterization, subclass lift, macro synthesis, composition). Corpus patterns 1–4 form a second axis: *type-strengthening* refactors, where nothing is duplicated — a representation is too permissive and a language feature tightens it. Pattern 5 is a third direction: *de-abstraction*.

[V7 §5's taxonomy note](refactor-recommendation-experiment-methodology.md#plant-design) already establishes that the plant set is a subset of the recommendation taxonomy, not a partition — `extension-consolidation` is a recommendation category with no plants. New categories from this corpus (`state-enum-consolidation`, `type-safe-id-introduction`, `async-migration`, `protocol-removal`) extend the agent prompt's enumeration the same additive way. Whether they get plant rounds of their own is a V8+ scoping question; the detector work stands on its own either way.

## Adding a corpus entry

1. Verify the source posts exist and contain worked code (fetch them, don't trust aggregator summaries).
2. State the before-signal as a predicate over catalog rows. If you can't, it fails the lit test — either find the structural precondition or file it as Tier 3.
3. Check the [contract](pipeline-contract.md) for whether the needed fields exist. Prefer specs that consume existing fields; propose additive fields only when a pattern genuinely needs them, and consolidate with extensions already proposed here.
4. Write the restraint note first — every detector needs an answer to "when is this before-state intentional?" before it earns a query. This is the [V7 restraint metric](refactor-recommendation-experiment-methodology.md#restraint) applied at design time.
