# wxyc-ios-64 Substrate Experiment — Results

## Question

Does the substrate that performed at full plant-recall on dj-site (V5 result, 100% across all five plant categories) transfer to the wxyc-ios-64 Swift codebase, given a fresh SwiftSyntax-based extractor and the N-package generalization of the cross-package queries?

## Setup

- **Codebase under audit:** wxyc-ios-64 at HEAD (350 first-party Swift files, 22 SwiftPM-style packages including 19 `Shared/` packages and 3 app targets).
- **Extractor:** [`extractors/swift/`](../extractors/swift) (swift-catalog), new in this experiment. SwiftSyntax 600.x. Two subcommands: `type` and `func`.
- **File-hashes:** [`extractors/file-hashes/file-hashes.mjs`](../extractors/file-hashes/file-hashes.mjs) extended with a Swift mode (activated by `--extensions swift`).
- **Queries:** the V5 set of 8 (`exact-duplicates`, `name-collisions`, `subset-pairs`, `function-duplicates`, `file-duplicates`, plus three new `-any` variants of the cross-package queries that drop the main↔shared hardcode for arbitrary N-package layouts).
- **Plant tree:** [`examples/swift-plants/`](../examples/swift-plants) — 25 files implementing the 20 plants from [`wxyc-ios-64-experiment-plant-manifest.md`](wxyc-ios-64-experiment-plant-manifest.md), walked via `--shared` so the unmodified wxyc-ios-64 source is not touched.
- **Single-trial measurement:** the substrate is deterministic, so this experiment reports the substrate-recall axis (does each plant surface in its expected query?) without 3-trial LLM agent variance. The 3-trial agent run reported in the V5 dj-site experiment showed that with a complete substrate, agent intra-trial Jaccard converges to 1.00 — measuring it again on Swift would test LLM determinism rather than substrate quality.

## Catalog sizes (planted)

| Catalog | Records | Source |
|---|---|---|
| `type-catalog.json` | 815 | 350 wxyc-ios-64 files + 25 plant files |
| `function-catalog.json` | 1154 | same |
| `file-hashes.json` | 375 | same |

Zero parse errors across all 375 Swift files.

## Per-plant recall

19/20 surfaced, 0 unexpected misses, 1 expected gap (plant 20).

| # | Category | Source type → planted as | Expected query | Surfaced? |
|---|---|---|---|---|
| 1 | exact-duplicates | `Core:RadioStation` → `Metadata:BroadcastSource` (6 fields) | `exact-duplicates.jq` | ✓ |
| 2 | exact-duplicates | `Playback:MP3StreamerConfiguration` → `Caching:StreamCacheSetup` (4 fields) | `exact-duplicates.jq` | ✓ |
| 3 | exact-duplicates | `Wallpaper:PassConfiguration` → `WXUI:ShaderPassDescriptor` (5 fields) | `exact-duplicates.jq` | ✓ |
| 4 | exact-duplicates | `AppServices:AppConfig` → `Analytics:AppContextSettings` (4 fields) | `exact-duplicates.jq` | ✓ |
| 5 | cross-package-shadows | `Core:RadioStation` shape-divergent shadow in `Metadata` | `cross-package-shadows-any.jq` | ✓ |
| 6 | cross-package-shadows | `Logger:Logger` shape-divergent shadow in `Caching` | `cross-package-shadows-any.jq` | ✓ |
| 7 | cross-package-shadows | `Wallpaper:LoadedTheme` shape-divergent shadow in `Metadata` | `cross-package-shadows-any.jq` | ✓ |
| 8 | cross-package-shadows | `Playback:TimeShiftablePlayer` (protocol) shape-divergent shadow in `Playlist` | `cross-package-shadows-any.jq` | ✓ |
| 9 | subset-pairs | `RadioStationLite` (3 fields) ⊂ `Core:RadioStation` (6 fields) | `subset-pairs.jq` | ✓ |
| 10 | subset-pairs | `ThemeReference` ⊂ `Wallpaper:LoadedTheme` | `subset-pairs.jq` | ✓ |
| 11 | subset-pairs | `BasicConversionInfo` ⊂ `Playback:ConversionContext` | `subset-pairs.jq` | ✓ |
| 12 | subset-pairs | `BasicTimeShifter` (protocol, 3 reqs) ⊂ `Playback:TimeShiftablePlayer` | `subset-pairs.jq` | ✓ |
| 13 | near-duplicates | `EnhancedStreamerConfiguration` (Jaccard 0.80 vs `MP3StreamerConfiguration`) | `near-duplicates-any.jq` | ✓ |
| 14 | near-duplicates | `GraphicsConfiguration` (0.80 vs `ComputeConfiguration`) | `near-duplicates-any.jq` | ✓ |
| 15 | near-duplicates | `AppContextRich` (0.80 vs `AppConfig`) | `near-duplicates-any.jq` | ✓ |
| 16 | near-duplicates | `RadioStationExtended` (0.86 vs `RadioStation`) | `near-duplicates-any.jq` | ✓ |
| 17 | substrate-gap (function-body) | `hashSlug` / `hashSlugLite` body-Jaccard 0.77 | `function-duplicates.jq` | ✓ |
| 18 | substrate-gap (file-content) | byte-identical `_Plant_StreamUtilities.swift` in Core and Playback | `file-duplicates.jq` | ✓ |
| 19 | substrate-gap (cross-package, different name) | `PassConfiguration` → `RenderPassSpec` (Jaccard 1.0 across `Wallpaper` and `Metadata`) | `cross-package-shape-near-duplicates-any.jq` | ✓ |
| 20 | substrate-gap (extension-fragmented type) | `FragmentedConfig {x}` + two extensions adding `y` and `z` ⊂ `UnifiedConfig {x, y, z}` | `subset-pairs.jq` (gated on extension-merging) | **expected-gap** |

## Per-category recall

| Category | Surfaced | Recall (excluding expected gaps) |
|---|---|---|
| exact-duplicates | 4/4 | 100% |
| cross-package-shadows | 4/4 | 100% |
| subset-pairs | 4/4 | 100% |
| near-duplicates | 4/4 | 100% |
| substrate-gap | 3/4 | 100% (with 1 known unclosed gap) |

Mirrors the V5 dj-site result line by line, with the single Swift-specific predicted gap as the only departure.

## The expected gap: extension-fragmented types

Plant 20 declares `struct FragmentedConfig { let x: Int }` in one file, then two sibling files declare `extension FragmentedConfig { var y: String { … } }` and `extension FragmentedConfig { var z: Bool { … } }`. A separate `struct UnifiedConfig { let x: Int; let y: String; let z: Bool }` is the sibling that should cluster.

With the current swift-catalog, the substrate emits three separate `FragmentedConfig` records — the base struct (1 field) and two extension records (1 field each). All three fall below `subset-pairs.jq`'s minimum-field-count threshold of 2 and disappear from the query input. `UnifiedConfig` survives but has nothing to pair with.

This is the Swift-specific analog to the dj-site V4 intersection-type gap (where `type X = A & B` carried no `fields[]` until V5 added a second-pass resolution step). Closing it requires a second-pass step in swift-catalog that walks the catalog, finds extension records whose `extending` matches a base type in the same scan root, and merges the extension's fields into the base record (with `resolved_from: "extension-merge"` mirroring V5's `resolved_from: "intersection"` convention).

Deferred to a follow-up. The gap is documented, predicted in the plant manifest, and surfaces in the analyzer output as `EXPECTED-GAP` — the experiment's claim is that the gap is *predictable and bounded*, not that it's closed.

## What stays as future work

- **Extension-merging second pass in swift-catalog.** Closes plant 20. Estimated 30–50 lines of Swift after the existing visitor architecture.
- **3-trial LLM agent run.** The substrate is deterministic and confirmed complete on 19/20 plants. Confirming the V5 result that intra-trial Jaccard converges to 1.00 with a complete substrate would replicate the dj-site finding on Swift but isn't a new claim. Worth doing if the trial run also captures severity-rubric agreement, which is the layer where variance legitimately lives.
- **Protocol-inheritance resolution.** Conceptually adjacent to extension-merging — `protocol P3: P1, P2 {}` would benefit from a similar second pass that unions inherited protocol requirements into the child protocol's record. Not exercised by the current plant set; would need its own plant to measure.
- **Macro-synthesized field capture.** `@Observable`, `@Codable`, custom AnalyticsMacros all synthesize members the source-level parser doesn't see. SwiftSyntax can't observe macro output without invoking the compiler. This is a known absolute limit of the source-level approach; documented in `extractors/swift/README.md` rather than treated as a closable gap.
- **SwiftUI scaffolding noise filter.** `body: some View` single-field-struct clusters create a 16-decl noise cluster in exact-duplicates.jq. Doesn't affect plant recall (the noise was already in the baseline), but worth a `--min-fields` parameter on exact-duplicates or a SwiftUI-aware filter in the extractor.

## Conclusion

The substrate transfers cleanly to Swift. The same five-query class structure that gave 100% plant-recall on dj-site gives the same on wxyc-ios-64 once the extractor is rewritten in SwiftSyntax, the file-hashes extractor learns about Swift package layouts, and the cross-package queries generalize from main↔shared to N packages. The one known gap (extension-fragmented types) is Swift-specific and predicted in the plant manifest; the substrate's architectural posture toward gap closure is the same as the V4 → V5 transition on dj-site.

The high-signal natural findings the substrate surfaces in the unmodified wxyc-ios-64 — `DebugMetricsProvider` duplicated byte-identical across two packages (6 methods), `PlayerState` vs `PlaybackState` enums at 83% Jaccard with a parallel pair of computed-property extensions at 85%, `StreamingService` vs `MusicServiceIdentifier` as 83%-similar enums across `Metadata` and `MusicShareKit` — are independent confirmation that the queries are doing real work on real code, not just on synthetic plants.

## Postscript: V6's scope, after V7 was specified

V6 validates the **input layer**: rhymes get from Swift source into cluster rows at 19/20 plant recall, matching the V5 dj-site result line-for-line on a 350-file codebase across 22 packages. That's what plant-recall measures, and that's what this doc reports.

V6 does **not** validate the output layer — whether those cluster rows turn into actionable refactor recommendations. The cluster outputs in the conclusion section above (`DebugMetricsProvider`, `PlayerState`/`PlaybackState`, `StreamingService`/`MusicServiceIdentifier`) are *findings*, not recommendations. A finding tells you "these two enums look parallel"; a recommendation tells you "introduce a parent protocol with these two members and these conformers, because the existing package-dependency graph allows it."

The [V7 refactor-recommendation experiment](refactor-recommendation-experiment-methodology.md) is the methodology for the output layer. V6's 19/20 plant recall is a *prerequisite* for V7 (cluster rows must exist to be turned into recommendations), not a *substitute* for it. The project's working definition of its deliverable — actionable refactor recommendations — rides on V6 ∧ V7, not on V6 alone.

If you read V6 in isolation and concluded "the pipeline works," that conclusion is correct for the input layer and premature for the output layer. The two-layer framing in the [README](../README.md) and the V7 methodology doc's [background section](refactor-recommendation-experiment-methodology.md#background) walk through the distinction in more detail.
