# wxyc-ios-64 Substrate Experiment — Plant Manifest

> Synthetic-ground-truth design for measuring substrate coverage on the wxyc-ios-64 Swift codebase. Parallels the dj-site V3 manifest in structure: 20 plants across 5 categories, with category-by-category recall as the primary measurement.
>
> **Status**: DRAFT.

## Why de-abstraction works for the iOS repo

Same logic as the [dj-site V3 manifest](dj-site-divergence-experiment-v3-plant-manifest.md). Plant shapes inherit decisions made by real WXYC iOS contributors (camelCase property names, optional-vs-required nullability, Swift convention for protocol naming). The plant is the *placement* of a duplicate, not the *invention* of one.

For this iOS run, "package" is much richer than dj-site's main↔shared two-valued split — 22 SwiftPM packages + 3 app targets are visible to the extractor, so cross-package plants can span any pair.

## Isolated source set

All sources verified absent from every cluster output (exact-duplicates, name-collisions, near-duplicates-any, cross-package-shadows-any, cross-package-shape-near-duplicates-any, subset-pairs) in the baseline run against the unmodified wxyc-ios-64 repo.

| Source type | Fields | Location |
|---|---|---|
| `Core:RadioStation` | 6 | `Shared/Core/Sources/Core/Models and Services/RadioStation.swift:13` |
| `Logger:Logger` | 5 | `Shared/Logger/Sources/Logger/Logger.swift:107` |
| `AppServices:AppConfig` | 4 | `Shared/AppServices/Sources/AppServices/AppConfiguration.swift:17` |
| `Playback:MP3StreamerConfiguration` | 4 | `Shared/Playback/Sources/MP3Streamer/Configuration/MP3StreamerConfiguration.swift:14` |
| `Playback:ConversionContext` | 7 | `Shared/Playback/Sources/MP3Streamer/Decoding/MP3StreamDecoder.swift:493` |
| `Playback:HLSAVPlayerProtocol` | 6 | `Shared/Playback/Sources/HLSPlayer/Protocol/HLSAVPlayerProtocol.swift:20` |
| `Playback:TimeShiftablePlayer` | 6 | `Shared/Playback/Sources/PlaybackCore/Protocols/TimeShiftablePlayer.swift:20` |
| `Wallpaper:PassConfiguration` | 5 | `Shared/Wallpaper/Sources/Wallpaper/Core/ThemeManifest.swift:111` |
| `Wallpaper:ComputeConfiguration` | 4 | `Shared/Wallpaper/Sources/Wallpaper/Core/ThemeManifest.swift:153` |
| `Wallpaper:LoadedTheme` | 5 | `Shared/Wallpaper/Sources/Wallpaper/Core/ThemeRegistry.swift:26` |

## Plant set

20 plants, 4 per category. Plants 1–16 de-abstract real source types; plants 17–20 are synthetic substrate-gap probes. Plant locations are NEW Swift files; existing wxyc-ios-64 source is not modified.

| # | Category | Source type | Plant location | Plant name | Cluster_id |
|---|---|---|---|---|---|
| 1 | exact-duplicates | `Core:RadioStation` (6 fields) | `Shared/Metadata/Sources/Metadata/_Plant_BroadcastSource.swift` | `BroadcastSource` | `exact-duplicates:BroadcastSource+RadioStation` |
| 2 | exact-duplicates | `Playback:MP3StreamerConfiguration` (4 fields) | `Shared/Caching/Sources/Caching/_Plant_StreamCacheSetup.swift` | `StreamCacheSetup` | `exact-duplicates:MP3StreamerConfiguration+StreamCacheSetup` |
| 3 | exact-duplicates | `Wallpaper:PassConfiguration` (5 fields) | `Shared/WXUI/Sources/WXUI/_Plant_ShaderPassDescriptor.swift` | `ShaderPassDescriptor` | `exact-duplicates:PassConfiguration+ShaderPassDescriptor` |
| 4 | exact-duplicates | `AppServices:AppConfig` (4 fields) | `Shared/Analytics/Sources/Analytics/_Plant_AppContextSettings.swift` | `AppContextSettings` | `exact-duplicates:AppConfig+AppContextSettings` |
| 5 | cross-package-shadows | `Core:RadioStation` (shape will diverge) | `Shared/Metadata/Sources/Metadata/_Plant_RadioStationShadow.swift` | `RadioStation` (different fields) | `cross-package-shadows-any:RadioStation` |
| 6 | cross-package-shadows | `Logger:Logger` (5 fields, shape diverges) | `Shared/Caching/Sources/Caching/_Plant_LoggerShadow.swift` | `Logger` (4 fields different) | `cross-package-shadows-any:Logger` |
| 7 | cross-package-shadows | `Wallpaper:LoadedTheme` | `Shared/Metadata/Sources/Metadata/_Plant_LoadedThemeShadow.swift` | `LoadedTheme` (shape diverges) | `cross-package-shadows-any:LoadedTheme` |
| 8 | cross-package-shadows | `Playback:TimeShiftablePlayer` (protocol) | `Shared/Playlist/Sources/Playlist/_Plant_TimeShiftablePlayerShadow.swift` | `TimeShiftablePlayer` (different protocol shape) | `cross-package-shadows-any:TimeShiftablePlayer` |
| 9 | subset-pairs | `Core:RadioStation` (6 fields → 3-field subset) | `Shared/Metadata/Sources/Metadata/_Plant_RadioStationLite.swift` | `RadioStationLite` | `subset-pairs:RadioStationLite__RadioStation` |
| 10 | subset-pairs | `Wallpaper:LoadedTheme` (5 → 3) | `Shared/Caching/Sources/Caching/_Plant_ThemeReference.swift` | `ThemeReference` | `subset-pairs:ThemeReference__LoadedTheme` |
| 11 | subset-pairs | `Playback:ConversionContext` (7 → 3) | `Shared/Caching/Sources/Caching/_Plant_BasicConversionInfo.swift` | `BasicConversionInfo` | `subset-pairs:BasicConversionInfo__ConversionContext` |
| 12 | subset-pairs | `Playback:TimeShiftablePlayer` (6 → 3) | `Shared/Playback/Sources/PlaybackCore/_Plant_BasicTimeShifter.swift` | `BasicTimeShifter` | `subset-pairs:BasicTimeShifter__TimeShiftablePlayer` |
| 13 | near-duplicates | `Playback:MP3StreamerConfiguration` (4 fields + 1 new = 5; Jaccard 0.8) | `Shared/Caching/Sources/Caching/_Plant_EnhancedStreamerConfiguration.swift` | `EnhancedStreamerConfiguration` | `near-duplicates-any:EnhancedStreamerConfiguration+MP3StreamerConfiguration` |
| 14 | near-duplicates | `Wallpaper:ComputeConfiguration` (4 + 1; 0.8) | `Shared/WXUI/Sources/WXUI/_Plant_GraphicsConfiguration.swift` | `GraphicsConfiguration` | `near-duplicates-any:ComputeConfiguration+GraphicsConfiguration` |
| 15 | near-duplicates | `AppServices:AppConfig` (4 + 1; 0.8) | `Shared/Analytics/Sources/Analytics/_Plant_AppContextRich.swift` | `AppContextRich` | `near-duplicates-any:AppConfig+AppContextRich` |
| 16 | near-duplicates | `Core:RadioStation` (6 + 1; 0.86) | `Shared/Playlist/Sources/Playlist/_Plant_RadioStationExtended.swift` | `RadioStationExtended` | `near-duplicates-any:RadioStation+RadioStationExtended` |
| 17 | **substrate-gap** (function-body Jaccard) | New 6-line utility function in `Core:_Plant_StringHashing.swift` | second copy with 1-line variance: `Shared/Caching/Sources/Caching/_Plant_StringHashingLite.swift` | `hashSlug` / `hashSlugLite` | `function-duplicates:hashSlug+hashSlugLite` (exact or ≥0.8 Jaccard) |
| 18 | **substrate-gap** (file-content hash) | Synthetic 30-line file `Shared/Core/Sources/Core/_Plant_StreamUtilities.swift` | byte-identical copy `Shared/Playback/Sources/PlaybackCore/_Plant_StreamUtilities.swift` | n/a (file-level) | `file-duplicates:Shared/Core/Sources/Core/_Plant_StreamUtilities.swift+Shared/Playback/Sources/PlaybackCore/_Plant_StreamUtilities.swift` |
| 19 | **substrate-gap** (cross-package shape, different name) | Source: `Wallpaper:PassConfiguration` (5 fields). Plant: `Metadata:RenderPassSpec` with the same 5 fields. | `Shared/Metadata/Sources/Metadata/_Plant_RenderPassSpec.swift` | `RenderPassSpec` | `cross-package-shape-near-duplicates-any:PassConfiguration+RenderPassSpec` (Jaccard 1.0) |
| 20 | **substrate-gap** (extension-fragmented type) | Define `struct FragmentedConfig { x }` and add 2 extensions across files (`+y`, `+z`); define sibling `UnifiedConfig {x, y, z}`. | `Shared/Core/Sources/Core/_Plant_Fragmented*.swift` (4 files) | `FragmentedConfig` + `UnifiedConfig` | `subset-pairs:FragmentedConfig__UnifiedConfig` (only fires if extensions merge into base) |

Plant filename prefix `_Plant_` makes plants visible at a glance and easy to grep / rm after the experiment.

## Substrate-gap plants

These probe Swift-specific extractor gaps:

- **Plant 17** tests `function-duplicates.jq` for body-Jaccard on Swift function bodies. The substrate has the query (added in V5 substrate work), so it should surface.
- **Plant 18** tests `file-duplicates.jq` on byte-identical Swift files. Same — query exists, should surface.
- **Plant 19** tests `cross-package-shape-near-duplicates-any.jq` (new in this experiment). Should surface.
- **Plant 20** tests whether extension-fragmented types surface in `subset-pairs.jq`. With the current extractor, `FragmentedConfig`'s fields are spread across 3 records (one struct + two extensions), so each individually has 1 field — below the subset-pairs threshold. `UnifiedConfig` has 3 fields. Without extension-merging in the extractor, **plant 20 will NOT surface**.

Plant 20 is the V6 Swift-specific substrate gap analog to dj-site V4's intersection-type gap. Closing it requires a second-pass extension-merging step in `swift-catalog`.

## Predictions

| Prediction | Expected | What it tests |
|---|---|---|
| All 4 exact-duplicates plants surface | YES | `exact-duplicates.jq` fires on de-abstracted Swift shapes |
| All 4 cross-package-shadows plants surface | YES | `cross-package-shadows-any.jq` (new N-package query) handles 22-package iOS layout |
| All 4 subset-pairs plants surface | YES | `subset-pairs.jq` is package-agnostic |
| All 4 near-duplicates plants surface | YES | `near-duplicates-any.jq` (new N-package query) at threshold 0.7 |
| Substrate-gap plants 17, 18, 19 surface | YES | function-duplicates, file-duplicates, cross-package-shape-near-duplicates-any cover the gaps closed in V5 |
| Substrate-gap plant 20 surfaces | NO (baseline), YES (with extension-merging) | Tests Swift-specific extension-fragmented-type gap |
| C3 (pipeline) plant-only intra-trial Jaccard ≥ 0.95 across 3 trials | YES | V5 dj-site showed 1.00 on equivalent C3 |
| Per-plant recall matches V5 dj-site closure (100% with extension-merging closed) | YES if Swift substrate is at parity with TS V5 | The main comparison the experiment is designed to make |

## After the experiment

- Remove all `_Plant_*.swift` files from the worktree before merging or pushing.
- The `experiment/swift-plants` branch in the wxyc-ios-64 repo is throwaway; delete it after results are recorded.
